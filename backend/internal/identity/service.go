// Package identity owns accounts, sessions, station identities and security audit.
package identity

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	_ "modernc.org/sqlite"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

var ErrLogin = errors.New("用户名、密码或验证码错误")
var ErrDenied = authorization.ErrDenied

type User struct {
	CustomRoleIDs []string              `json:"custom_role_ids"`
	DirectGrants  *authorization.Grants `json:"direct_grants,omitempty"`
	ID            string                `json:"id"`
	Username      string                `json:"username"`
	Disabled      bool                  `json:"disabled"`
	Version       int64                 `json:"version"`
	Grants        authorization.Grants  `json:"grants"`
}
type Change struct {
	CustomRoleIDs []string             `json:"custom_role_ids"`
	Username      string               `json:"username"`
	Password      string               `json:"password,omitempty"`
	Disabled      bool                 `json:"disabled"`
	Version       int64                `json:"version"`
	Grants        authorization.Grants `json:"grants"`
}
type Session struct {
	// Empty is the legacy/local channel. Public channels are bound at login.
	Channel     string      `json:"channel,omitempty"`
	LinkedValid func() bool `json:"-"`
	MFA         bool        `json:"mfa"`
	ID          string      `json:"id"`
	UserID      string      `json:"user_id"`
	Version     int64       `json:"-"`
	CSRF        string      `json:"-"`
	Bearer      bool        `json:"-"`
	Started     time.Time   `json:"started"`
	Last        time.Time   `json:"last"`
	Expires     time.Time   `json:"expires_at"`
}
type Station struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type Audit struct {
	Seq    int64  `json:"seq"`
	At     string `json:"at"`
	Actor  string `json:"actor"`
	Action string `json:"action"`
	Target string `json:"target"`
	Result string `json:"result"`
}
type attempt struct {
	At    time.Time
	Count int
}
type Service struct {
	publicIPMu     sync.RWMutex
	publicIPPolicy *PublicIPPolicy
	publicIPRaw    string
	localPasswords bool
	mfaKey         []byte
	mu             sync.Mutex
	db             *persistence.DB
	sessions       map[[32]byte]Session
	attempts       map[string]attempt
	slots          chan struct{}
	dummy          string
	now            func() time.Time
}

func randomID() string {
	b := make([]byte, 24)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func Open(dir string) (*Service, error) { return OpenDatabase(dir, "") }

type Options struct {
	// LocalPasswords is only for a server restricted to loopback connections.
	LocalPasswords bool
}

func OpenDatabase(dir, dsn string, options ...Options) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	if err := protectStore(dir); err != nil {
		return nil, err
	}
	db, err := persistence.Open(filepath.Join(dir, "identity.db"), dsn)
	if err != nil {
		return nil, err
	}
	if err = db.Schema([]string{
		"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=3000",
		"CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,username TEXT NOT NULL UNIQUE,password TEXT NOT NULL,disabled INTEGER NOT NULL,version INTEGER NOT NULL,grants TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS security_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS custom_roles(id TEXT PRIMARY KEY,name TEXT NOT NULL,version INTEGER NOT NULL,grants TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS user_role_policy(user_id TEXT PRIMARY KEY,direct_grants TEXT NOT NULL,role_ids TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS stations(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE)",
		"CREATE TABLE IF NOT EXISTS audit(seq INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT NOT NULL,actor TEXT NOT NULL,action TEXT NOT NULL,target TEXT NOT NULL,result TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS mfa(user_id TEXT PRIMARY KEY,secret BLOB NOT NULL,enabled INTEGER NOT NULL,last_counter INTEGER NOT NULL,expires INTEGER NOT NULL)",
		"CREATE TABLE IF NOT EXISTS recovery(user_id TEXT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(user_id,digest))",
	}); err != nil {
		db.Close()
		return nil, err
	}
	key, err := loadMFAKey(dir)
	if err != nil {
		db.Close()
		return nil, err
	}
	dummy, err := passwordHash(randomID())
	if err != nil {
		db.Close()
		return nil, err
	}
	localPasswords := len(options) > 0 && options[0].LocalPasswords
	return &Service{localPasswords: localPasswords, db: db, mfaKey: key, sessions: map[[32]byte]Session{}, attempts: map[string]attempt{}, slots: make(chan struct{}, 2), dummy: dummy, now: time.Now}, nil
}
func (s *Service) Close() error { return s.db.Close() }
func (s *Service) NeedsSetup() bool {
	var n int
	return s.db.QueryRow("SELECT count(*) FROM users").Scan(&n) == nil && n == 0
}
func usernameValid(name string) bool {
	return len(name) > 0 && len(name) <= 128 && strings.TrimSpace(name) == name && strings.IndexFunc(name, unicode.IsControl) < 0
}
func auditTx(tx *persistence.Tx, actor, action, target, result string) error {
	_, err := tx.Exec("INSERT INTO audit(at,actor,action,target,result) VALUES(?,?,?,?,?)", time.Now().UTC().Format(time.RFC3339Nano), actor, action, target, result)
	return err
}

// Bootstrap is only reachable through an explicitly enabled loopback setup flow.
func (s *Service) Bootstrap(username, password string) (User, error) {
	if !usernameValid(username) {
		return User{}, fmt.Errorf("无效用户名")
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return User{}, ErrDenied
	}
	hash, err := s.passwordHash(password)
	if err != nil {
		return User{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback()
	var n int
	if err = tx.QueryRow("SELECT count(*) FROM users").Scan(&n); err != nil || n != 0 {
		return User{}, ErrDenied
	}
	u := User{ID: randomID(), Username: username, Version: 1, Grants: authorization.Grants{Roles: []string{"admin", "engineer", "auditor"}, AllStations: true, Export: true, GrantControl: true}}
	// Device control is deliberately absent even from the initial owner.
	b, _ := json.Marshal(u.Grants)
	if _, err = tx.Exec("INSERT INTO users VALUES(?,?,?,?,?,?)", u.ID, u.Username, hash, false, u.Version, string(b)); err != nil {
		return User{}, err
	}
	if err = auditTx(tx, u.ID, "bootstrap", u.ID, "created"); err != nil {
		return User{}, err
	}
	return u, tx.Commit()
}
func scanUser(row interface{ Scan(...any) error }) (User, string, error) {
	var u User
	var hash, g string
	err := row.Scan(&u.ID, &u.Username, &hash, &u.Disabled, &u.Version, &g)
	if err == nil {
		err = json.Unmarshal([]byte(g), &u.Grants)
	}
	return u, hash, err
}
func (s *Service) User(id string) (User, error) {
	u, _, err := scanUser(s.db.QueryRow("SELECT * FROM users WHERE id=?", id))
	return u, err
}
func (s *Service) Current(id string, version int64) bool {
	u, err := s.User(id)
	return err == nil && !u.Disabled && u.Version == version
}
func (s *Service) Actor(u User) authorization.Actor {
	ids := map[string]string{}
	names := []string{}
	rows, err := s.db.Query("SELECT id,name FROM stations")
	if err == nil {
		for rows.Next() {
			var id, name string
			if rows.Scan(&id, &name) == nil {
				ids[name] = id
				if u.Grants.Station(id) {
					names = append(names, name)
				}
			}
		}
		rows.Close()
	}
	valid := func() bool { return s.Current(u.ID, u.Version) }
	return authorization.Actor{ID: u.ID, Version: u.Version, Grants: u.Grants, StationNames: names, Valid: valid, IdentityValid: valid, Audit: func(action, target, result string) error { return s.Record(u.ID, action, target, result) }, StationID: func(name string) string { return ids[name] }}
}
func (s *Service) Change(actor authorization.Actor, id string, in Change) (User, error) {
	if !actor.Active() || !actor.Grants.Manage() || !usernameValid(in.Username) {
		return User{}, ErrDenied
	}
	if id == actor.ID {
		return User{}, fmt.Errorf("不能修改自己的角色或启停状态；请由另一位授权管理员操作")
	}
	hash := ""
	var err error
	if in.Password != "" {
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
		default:
			return User{}, ErrDenied
		}
		hash, err = s.passwordHash(in.Password)
		if err != nil {
			return User{}, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(actor.ID, actor.Version) {
		return User{}, ErrDenied
	}
	tx, err := s.db.Begin()
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback()
	policy := rolePolicy{Direct: in.Grants, IDs: in.CustomRoleIDs}
	effective, err := effectiveTx(tx, policy)
	if err != nil {
		return User{}, err
	}
	if !actor.Grants.MayGrant(effective) {
		return User{}, ErrDenied
	}
	u := User{ID: id, Username: in.Username, Disabled: in.Disabled, Version: 1, Grants: effective, CustomRoleIDs: policy.IDs, DirectGrants: &policy.Direct}
	if id == "" {
		if hash == "" {
			return User{}, fmt.Errorf("新账号须设置密码")
		}
		u.ID = randomID()
	} else {
		old, oldHash, e := scanUser(tx.QueryRow("SELECT * FROM users WHERE id=?", id))
		if e != nil {
			return User{}, ErrDenied
		}
		if old.Version != in.Version {
			return User{}, fmt.Errorf("账号版本已变化，请刷新")
		}
		if !actor.Grants.MayGrant(old.Grants) {
			return User{}, ErrDenied
		}
		if old.Grants.Manage() && !old.Disabled && (u.Disabled || !u.Grants.Manage()) {
			rows, e := tx.Query("SELECT * FROM users WHERE disabled=0")
			if e != nil {
				return User{}, e
			}
			admins := 0
			for rows.Next() {
				v, _, e := scanUser(rows)
				if e != nil {
					rows.Close()
					return User{}, e
				}
				if v.Grants.Manage() {
					admins++
				}
			}
			e = rows.Err()
			rows.Close()
			if e != nil {
				return User{}, e
			}
			if admins <= 1 {
				return User{}, fmt.Errorf("不能停用最后一个管理员")
			}
		}
		u.Version = old.Version + 1
		if hash == "" {
			hash = oldHash
		}
	}
	for _, station := range in.Grants.StationIDs {
		var n int
		if e := tx.QueryRow("SELECT count(*) FROM stations WHERE id=?", station).Scan(&n); e != nil || n != 1 {
			return User{}, fmt.Errorf("未知站点身份")
		}
	}
	b, _ := json.Marshal(u.Grants)
	_, err = tx.Exec("INSERT INTO users VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET username=excluded.username,password=excluded.password,disabled=excluded.disabled,version=excluded.version,grants=excluded.grants", u.ID, u.Username, hash, u.Disabled, u.Version, string(b))
	if err != nil {
		return User{}, err
	}
	if err = savePolicy(tx, u.ID, policy); err != nil {
		return User{}, err
	}
	if err = auditTx(tx, actor.ID, "user.change", u.ID, "saved; sessions revoked"); err != nil {
		return User{}, err
	}
	if err = tx.Commit(); err != nil {
		return User{}, err
	}
	for k, v := range s.sessions {
		if v.UserID == u.ID {
			delete(s.sessions, k)
		}
	}
	return u, nil
}
func (s *Service) Users(actor authorization.Actor) ([]User, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return nil, ErrDenied
	}
	rows, e := s.db.Query("SELECT * FROM users ORDER BY username")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []User{}
	for rows.Next() {
		u, _, e := scanUser(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, u)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return nil, e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	for i := range out {
		p, err := policyTx(tx, out[i])
		if err != nil {
			return nil, err
		}
		out[i].CustomRoleIDs = p.IDs
		out[i].DirectGrants = &p.Direct
	}
	return out, nil
}

func (s *Service) allowAttempt(key string, extra ...string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, a := range s.attempts {
		if now.Sub(a.At) >= time.Minute {
			delete(s.attempts, k)
		}
	}
	if len(s.attempts) > 2048 {
		return false
	}
	keys := append([]string{"global", key}, extra...)
	for _, k := range keys {
		a := s.attempts[k]
		limit := 10
		if k == "global" {
			limit = 60
		}
		if a.Count >= limit {
			return false
		}
	}
	for _, k := range keys {
		a := s.attempts[k]
		if a.Count == 0 {
			a.At = now
		}
		a.Count++
		s.attempts[k] = a
	}
	return true
}
func (s *Service) Login(username, password, client string, bearer bool, codes ...string) (User, Session, string, error) {
	return s.LoginChannel(username, password, client, bearer, "", codes...)
}

// Only the local and public Web channels exist. Device-bound channels require
// a separately verified device identity contract and are deliberately rejected.
func sessionChannel(channel string) (string, bool) {
	switch channel {
	case "":
		return "", true
	case "public:web":
		return channel, true
	default:
		return "", false
	}
}

func (s *Service) LoginChannel(username, password, client string, bearer bool, channel string, codes ...string) (User, Session, string, error) {
	channel, validChannel := sessionChannel(channel)
	if !validChannel {
		return User{}, Session{}, "", ErrLogin
	}

	digest := sha256.Sum256([]byte(username))
	if !s.allowAttempt("login-ip:"+client, "login-user:"+hex.EncodeToString(digest[:])) {
		return User{}, Session{}, "", ErrLogin
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return User{}, Session{}, "", ErrLogin
	}
	u, hash, err := scanUser(s.db.QueryRow("SELECT * FROM users WHERE username=?", username))
	if err != nil {
		hash = s.dummy
	}
	valid := passwordMatches(hash, password)
	if !valid || err != nil || u.Disabled {
		_ = s.Record("anonymous", "login", "", "denied")
		return User{}, Session{}, "", ErrLogin
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(u.ID, u.Version) {
		return User{}, Session{}, "", ErrLogin
	}
	code := ""
	if len(codes) > 0 {
		code = codes[0]
	}
	mfa, err := s.verifyMFALocked(u.ID, code)
	if err != nil {
		_ = s.Record(u.ID, "login", "", "denied")
		return User{}, Session{}, "", ErrLogin
	}
	now := s.now()
	for k, v := range s.sessions {
		if now.After(v.Expires) || now.Sub(v.Last) > 30*time.Minute {
			delete(s.sessions, k)
		}
	}
	if len(s.sessions) >= 256 {
		return User{}, Session{}, "", ErrLogin
	}
	token := randomID()
	sess := Session{Channel: channel, MFA: mfa, ID: randomID(), UserID: u.ID, Version: u.Version, CSRF: randomID(), Bearer: bearer, Started: now, Last: now, Expires: now.Add(8 * time.Hour)}
	if err = s.Record(u.ID, "login", sess.ID, "authenticated"); err != nil {
		return User{}, Session{}, "", err
	}
	s.sessions[sha256.Sum256([]byte(token))] = sess
	return u, sess, token, nil
}
func (s *Service) Resolve(token string, touch bool) (User, Session, error) {
	return s.ResolveChannel(token, touch, "")
}

// ResolveChannel checks the transport binding before exposing identity or
// updating activity. A wrong-channel copy cannot revoke the legitimate session.
func (s *Service) ResolveChannel(token string, touch bool, channel string) (User, Session, error) {
	channel, validChannel := sessionChannel(channel)
	if !validChannel {
		return User{}, Session{}, ErrLogin
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	key := sha256.Sum256([]byte(token))
	v, ok := s.sessions[key]
	bound, validBinding := sessionChannel(v.Channel)
	if !ok || !validBinding || bound != channel {
		return User{}, Session{}, ErrLogin
	}
	now := s.now()
	if !ok || now.After(v.Expires) || now.Sub(v.Last) > 30*time.Minute || (v.LinkedValid != nil && !v.LinkedValid()) {
		delete(s.sessions, key)
		return User{}, Session{}, ErrLogin
	}
	u, err := s.User(v.UserID)
	if err != nil || u.Disabled || u.Version != v.Version {
		delete(s.sessions, key)
		return User{}, Session{}, ErrLogin
	}
	if touch {
		v.Last = now
		s.sessions[key] = v
	}
	return u, v, nil
}
func (s *Service) Revoke(actor authorization.Actor, userID, sessionID string) error {
	if !actor.Active() || (actor.ID != userID && !actor.Grants.Manage()) {
		return ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.Record(actor.ID, "session.revoke", userID, "revoked"); err != nil {
		return err
	}
	for k, v := range s.sessions {
		if v.UserID == userID && (sessionID == "" || v.ID == sessionID) {
			delete(s.sessions, k)
		}
	}
	return nil
}
func (s *Service) Sessions(actor authorization.Actor) ([]Session, error) {
	if !actor.Active() {
		return nil, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Session{}
	now := s.now()
	for _, v := range s.sessions {
		if (v.UserID == actor.ID || actor.Grants.Manage()) && now.Before(v.Expires) && now.Sub(v.Last) <= 30*time.Minute {
			out = append(out, v)
		}
	}
	return out, nil
}
func (s *Service) Record(actor, action, target, result string) error {
	_, err := s.db.Exec("INSERT INTO audit(at,actor,action,target,result) VALUES(?,?,?,?,?)", s.now().UTC().Format(time.RFC3339Nano), actor, action, target, result)
	return err
}
func (s *Service) Audits(actor authorization.Actor) ([]Audit, error) {
	if !actor.Active() || !actor.Grants.Has("auditor") || !actor.Grants.AllStations {
		return nil, ErrDenied
	}
	rows, err := s.db.Query("SELECT * FROM audit ORDER BY seq DESC LIMIT 500")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Audit{}
	for rows.Next() {
		var a Audit
		if err = rows.Scan(&a.Seq, &a.At, &a.Actor, &a.Action, &a.Target, &a.Result); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// RegisterStations adds opaque stable IDs without changing legacy config or
// historical station snapshots. New names never inherit a deleted name's grants.
// Renames are not supported: callers must keep these legacy keys immutable.
func (s *Service) RegisterStations(names []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, name := range names {
		sum := sha256.Sum256([]byte(randomID()))
		if _, err = tx.Exec("INSERT INTO stations VALUES(?,?) ON CONFLICT(name) DO NOTHING", "st_"+hex.EncodeToString(sum[:12]), name); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s *Service) StationID(name string) string {
	var id string
	_ = s.db.QueryRow("SELECT id FROM stations WHERE name=?", name).Scan(&id)
	return id
}
func (s *Service) Stations(actor authorization.Actor) ([]Station, error) {
	if !actor.Active() {
		return nil, ErrDenied
	}
	rows, err := s.db.Query("SELECT id,name FROM stations ORDER BY name")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Station{}
	for rows.Next() {
		var st Station
		if err = rows.Scan(&st.ID, &st.Name); err != nil {
			return nil, err
		}
		if actor.Grants.Station(st.ID) {
			out = append(out, st)
		}
	}
	return out, rows.Err()
}

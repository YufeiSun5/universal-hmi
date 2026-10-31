package identity

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// RFC 6238, 30 second step, 6 digits, +/- one step. Successful counters are
// persisted so a code cannot be replayed across requests or server restarts.
func totp(secret []byte, counter int64, digits int) string {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(counter))
	mac := hmac.New(sha1.New, secret)
	mac.Write(b[:])
	digest := mac.Sum(nil)
	offset := digest[len(digest)-1] & 15
	n := binary.BigEndian.Uint32(digest[offset:offset+4]) & 0x7fffffff
	mod := uint32(1000000)
	if digits == 8 {
		mod = 100000000
	}
	return fmt.Sprintf("%0*d", digits, n%mod)
}
func loadMFAKey(dir string) ([]byte, error) {
	path := filepath.Join(dir, "mfa.key")
	b, err := os.ReadFile(path)
	if err == nil {
		if len(b) != 32 {
			return nil, fmt.Errorf("invalid MFA encryption key")
		}
		return b, nil
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	b = make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	_, err = f.Write(b)
	if err == nil {
		err = f.Sync()
	}
	ce := f.Close()
	if err == nil {
		err = ce
	}
	return b, err
}
func (s *Service) cryptMFA(userID string, b []byte, encrypt bool) ([]byte, error) {
	block, err := aes.NewCipher(s.mfaKey)
	if err != nil {
		return nil, err
	}
	g, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if encrypt {
		nonce := make([]byte, g.NonceSize())
		if _, err = rand.Read(nonce); err != nil {
			return nil, err
		}
		return g.Seal(nonce, nonce, b, []byte(userID)), nil
	}
	if len(b) < g.NonceSize() {
		return nil, ErrDenied
	}
	return g.Open(nil, b[:g.NonceSize()], b[g.NonceSize():], []byte(userID))
}
func (s *Service) BeginMFA(a authorization.Actor, password string) (string, error) {
	if !a.Active() || !s.allowAttempt("enroll:"+a.ID) {
		return "", ErrDenied
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return "", ErrDenied
	}
	_, hash, err := scanUser(s.db.QueryRow("SELECT * FROM users WHERE id=?", a.ID))
	if err != nil || !passwordMatches(hash, password) {
		return "", ErrLogin
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(a.ID, a.Version) {
		return "", ErrDenied
	}
	var enabled bool
	err = s.db.QueryRow("SELECT enabled FROM mfa WHERE user_id=?", a.ID).Scan(&enabled)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	if enabled {
		return "", fmt.Errorf("已绑定验证器；重置需要另一位授权管理员")
	}
	secret := make([]byte, 20)
	if _, err = rand.Read(secret); err != nil {
		return "", err
	}
	encrypted, err := s.cryptMFA(a.ID, secret, true)
	if err != nil {
		return "", err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	_, err = tx.Exec("INSERT INTO mfa VALUES(?,?,0,-1,?) ON CONFLICT(user_id) DO UPDATE SET secret=excluded.secret,expires=excluded.expires", a.ID, encrypted, s.now().Add(10*time.Minute).Unix())
	if err != nil {
		return "", err
	}
	if err = auditTx(tx, a.ID, "mfa.enroll.begin", a.ID, "pending"); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(secret), nil
}
func validCounter(secret []byte, code string, now time.Time, last int64) (int64, bool) {
	if len(code) != 6 {
		return 0, false
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	for _, delta := range []int64{0, -1, 1} {
		counter := now.Unix()/30 + delta
		if counter > last && subtle.ConstantTimeCompare([]byte(totp(secret, counter, 6)), []byte(code)) == 1 {
			return counter, true
		}
	}
	return 0, false
}
func (s *Service) ConfirmMFA(a authorization.Actor, code, sessionID string) ([]string, error) {
	if !a.Active() || !s.allowAttempt("mfa:"+a.ID) {
		return nil, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(a.ID, a.Version) {
		return nil, ErrDenied
	}
	var encrypted []byte
	var enabled bool
	var last, expires int64
	err := s.db.QueryRow("SELECT secret,enabled,last_counter,expires FROM mfa WHERE user_id=?", a.ID).Scan(&encrypted, &enabled, &last, &expires)
	if err != nil || enabled || s.now().Unix() > expires {
		return nil, ErrDenied
	}
	secret, err := s.cryptMFA(a.ID, encrypted, false)
	if err != nil {
		return nil, err
	}
	counter, ok := validCounter(secret, code, s.now(), last)
	if !ok {
		return nil, ErrLogin
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("UPDATE mfa SET enabled=1,last_counter=?,expires=0 WHERE user_id=?", counter, a.ID); err != nil {
		return nil, err
	}
	codes := []string{}
	for i := 0; i < 8; i++ {
		b := make([]byte, 16)
		if _, err = rand.Read(b); err != nil {
			return nil, err
		}
		c := hex.EncodeToString(b)
		codes = append(codes, c)
		digest := sha256.Sum256([]byte(c))
		if _, err = tx.Exec("INSERT INTO recovery VALUES(?,?)", a.ID, hex.EncodeToString(digest[:])); err != nil {
			return nil, err
		}
	}
	if err = auditTx(tx, a.ID, "mfa.enroll.confirm", a.ID, "enabled"); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	// Upgrade only the enrolling session and revoke other password-only sessions.
	for k, v := range s.sessions {
		if v.UserID == a.ID {
			if v.ID == sessionID {
				v.MFA = true
				s.sessions[k] = v
			} else {
				delete(s.sessions, k)
			}
		}
	}
	return codes, nil
}
func (s *Service) verifyMFALocked(userID, code string) (bool, error) {
	var encrypted []byte
	var enabled bool
	var last int64
	err := s.db.QueryRow("SELECT secret,enabled,last_counter FROM mfa WHERE user_id=?", userID).Scan(&encrypted, &enabled, &last)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !enabled {
		return false, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if len(code) == 32 {
		digest := sha256.Sum256([]byte(strings.ToLower(code)))
		result, err := tx.Exec("DELETE FROM recovery WHERE user_id=? AND digest=?", userID, hex.EncodeToString(digest[:]))
		if err != nil {
			return false, err
		}
		n, _ := result.RowsAffected()
		if n != 1 {
			return false, ErrLogin
		}
	} else {
		secret, e := s.cryptMFA(userID, encrypted, false)
		if e != nil {
			return false, e
		}
		counter, ok := validCounter(secret, code, s.now(), last)
		if !ok {
			return false, ErrLogin
		}
		if _, err = tx.Exec("UPDATE mfa SET last_counter=? WHERE user_id=?", counter, userID); err != nil {
			return false, err
		}
	}
	if err = auditTx(tx, userID, "mfa.verify", userID, "accepted"); err != nil {
		return false, err
	}
	return true, tx.Commit()
}
func (s *Service) ResetMFA(a authorization.Actor, id string) error {
	if !a.Active() || !a.Grants.Manage() || a.ID == id {
		return ErrDenied
	}
	u, err := s.User(id)
	if err != nil || !a.Grants.MayGrant(u.Grants) {
		return ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(a.ID, a.Version) {
		return ErrDenied
	}
	u, err = s.User(id)
	if err != nil || !a.Grants.MayGrant(u.Grants) {
		return ErrDenied
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, q := range []string{"DELETE FROM mfa WHERE user_id=?", "DELETE FROM recovery WHERE user_id=?", "UPDATE users SET version=version+1 WHERE id=?"} {
		if _, err = tx.Exec(q, id); err != nil {
			return err
		}
	}
	if err = auditTx(tx, a.ID, "mfa.reset", id, "reset; sessions revoked"); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	for k, v := range s.sessions {
		if v.UserID == id {
			delete(s.sessions, k)
		}
	}
	return nil
}

package totalreports

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

type Service struct {
	db        *persistence.DB
	now       func() time.Time
	reader    CounterReader
	syncSlots chan struct{}
	heatCache map[string]heatCacheEntry
}

func Open(db *persistence.DB) (*Service, error) {
	err := db.Schema([]string{
		`CREATE TABLE IF NOT EXISTS total_report_originals(id TEXT PRIMARY KEY,data BLOB NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS total_report_templates(kind TEXT PRIMARY KEY,data TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS total_report_docs(doc TEXT PRIMARY KEY,revision INTEGER NOT NULL,template TEXT NOT NULL,checkpoint_revision INTEGER NOT NULL,checkpoint_at INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS total_report_cells(doc TEXT NOT NULL,address TEXT NOT NULL,value TEXT NOT NULL,revision INTEGER NOT NULL,actor TEXT NOT NULL,PRIMARY KEY(doc,address))`,
		`CREATE INDEX IF NOT EXISTS total_report_delta ON total_report_cells(doc,revision)`,
		`CREATE TABLE IF NOT EXISTS total_report_formats(doc TEXT NOT NULL,address TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(doc,address))`,
		`CREATE TABLE IF NOT EXISTS total_report_ops(doc TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,receipt TEXT NOT NULL,PRIMARY KEY(doc,id))`,
		`CREATE TABLE IF NOT EXISTS total_report_checkpoints(doc TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,created INTEGER NOT NULL,actor TEXT NOT NULL,reason TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(doc,id))`,
		`CREATE INDEX IF NOT EXISTS total_report_checkpoint_order ON total_report_checkpoints(doc,created)`,
		`CREATE TABLE IF NOT EXISTS total_report_settings(key TEXT PRIMARY KEY,revision INTEGER NOT NULL,value TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS total_report_readings(doc TEXT NOT NULL,address TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(doc,address))`,
		`CREATE TABLE IF NOT EXISTS total_report_locks(doc TEXT NOT NULL,address TEXT NOT NULL,actor TEXT NOT NULL,name TEXT NOT NULL,client TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(doc,address))`,
	})
	if err != nil {
		return nil, err
	}
	return &Service{db: db, now: time.Now, syncSlots: make(chan struct{}, 1), heatCache: map[string]heatCacheEntry{}}, nil
}
func newID() string { var b [16]byte; _, _ = rand.Read(b[:]); return hex.EncodeToString(b[:]) }
func (s *Service) lock(ctx context.Context, key string) (*persistence.Tx, int64, Template, error) {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return nil, 0, Template{}, e
	}
	// Acquire the database row/write lock before reading. This works across
	// service instances, with both PostgreSQL and SQLite adapters.
	res, e := tx.ExecContext(ctx, `UPDATE total_report_docs SET revision=revision WHERE doc=?`, key)
	if e != nil {
		tx.Rollback()
		return nil, 0, Template{}, e
	}
	n, e := res.RowsAffected()
	if e != nil || n != 1 {
		tx.Rollback()
		return nil, 0, Template{}, ErrMissing
	}
	var rev int64
	var raw string
	var t Template
	e = tx.QueryRowContext(ctx, `SELECT revision,template FROM total_report_docs WHERE doc=?`, key).Scan(&rev, &raw)
	if e == nil {
		e = json.Unmarshal([]byte(raw), &t)
	}
	if e != nil {
		tx.Rollback()
		return nil, 0, t, e
	}
	return tx, rev, t, nil
}
func readCells(tx *persistence.Tx, key string, after int64) ([]Cell, error) {
	rows, e := tx.Query(`SELECT c.address,c.value,c.revision,c.actor,COALESCE(f.data,'{}') FROM total_report_cells c LEFT JOIN total_report_formats f ON f.doc=c.doc AND f.address=c.address WHERE c.doc=? AND c.revision>? ORDER BY c.address`, key, after)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Cell{}
	for rows.Next() {
		var c Cell
		var format string
		if e = rows.Scan(&c.Address, &c.Value, &c.Revision, &c.Actor, &format); e != nil {
			return nil, e
		}
		if e = json.Unmarshal([]byte(format), &c.Format); e != nil {
			return nil, e
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
func receipt(tx *persistence.Tx, key, id, digest string) (*Saved, error) {
	var old, raw string
	e := tx.QueryRow(`SELECT digest,receipt FROM total_report_ops WHERE doc=? AND id=?`, key, id).Scan(&old, &raw)
	if e == sql.ErrNoRows {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	if digest != old {
		return nil, fmt.Errorf("操作编号已经用于其他内容")
	}
	var saved Saved
	e = json.Unmarshal([]byte(raw), &saved)
	return &saved, e
}
func saveReceipt(tx *persistence.Tx, key, id, digest string, v Saved) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	_, e = tx.Exec(`INSERT INTO total_report_ops(doc,id,digest,receipt) VALUES(?,?,?,?)`, key, id, digest, string(b))
	return e
}
func digest(v any) string { b, _ := json.Marshal(v); return fmt.Sprintf("%x", sha256.Sum256(b)) }
func (s *Service) checkpoint(tx *persistence.Tx, key, actor, reason string, rev int64, force bool) (Checkpoint, error) {
	var previous, at int64
	if e := tx.QueryRow(`SELECT checkpoint_revision,checkpoint_at FROM total_report_docs WHERE doc=?`, key).Scan(&previous, &at); e != nil {
		return Checkpoint{}, e
	}
	if previous == rev || !force && s.now().Unix()-at < 600 {
		return Checkpoint{}, nil
	}
	cells, e := readCells(tx, key, -1)
	if e != nil {
		return Checkpoint{}, e
	}
	var buf bytes.Buffer
	zip := gzip.NewWriter(&buf)
	encoder := json.NewEncoder(zip)
	encoder.SetEscapeHTML(false)
	if e = encoder.Encode(cells); e != nil {
		return Checkpoint{}, e
	}
	if e = zip.Close(); e != nil {
		return Checkpoint{}, e
	}
	cp := Checkpoint{ID: newID(), Revision: rev, Created: s.now().Unix(), Actor: actor, Reason: reason}
	_, e = tx.Exec(`INSERT INTO total_report_checkpoints(doc,id,revision,created,actor,reason,data) VALUES(?,?,?,?,?,?,?)`, key, cp.ID, rev, cp.Created, actor, reason, buf.Bytes())
	if e == nil {
		_, e = tx.Exec(`UPDATE total_report_docs SET checkpoint_revision=?,checkpoint_at=? WHERE doc=?`, rev, cp.Created, key)
	}
	return cp, e
}
func decodeCheckpoint(b []byte) ([]Cell, error) {
	z, e := gzip.NewReader(bytes.NewReader(b))
	if e != nil {
		return nil, e
	}
	defer z.Close()
	var cells []Cell
	// Named pages support up to 30,000 cells including saved toolbar formats.
	// Their valid snapshots can exceed the old fixed-report 4 MiB limit.
	e = json.NewDecoder(io.LimitReader(z, 256<<20)).Decode(&cells)
	return cells, e
}

func (s *Service) Patch(ctx context.Context, kind string, year int, in Patch) (Saved, error) {
	actor, e := permission(ctx, "edit")
	if e != nil {
		return Saved{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return Saved{}, e
	}
	if !operationID.MatchString(in.ID) || len(in.Changes) == 0 || len(in.Changes) > 1000 {
		return Saved{}, fmt.Errorf("每次保存须含1至1000个单元格及有效操作编号")
	}
	tx, rev, t, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	hash := digest(struct {
		Actor string
		Patch Patch
	}{actor, in})
	cached, e := receipt(tx, key, in.ID, hash)
	if e != nil {
		return Saved{}, e
	}
	if cached != nil {
		return *cached, nil
	}
	allowed := editable(t, year)
	seen := map[string]bool{}
	changes := []Cell{}
	destructive := false
	for _, c := range in.Changes {
		if !allowed[c.Address] || seen[c.Address] || !validContent(c.Value) || !validFormat(c.Format) || c.Expected < 0 {
			return Saved{}, fmt.Errorf("%s内容无效或为自动表底", c.Address)
		}
		if e = s.checkLease(ctx, tx, key, c.Address, actor, in.Client); e != nil {
			return Saved{}, e
		}
		seen[c.Address] = true
		old := Cell{Address: c.Address}
		e = tx.QueryRow(`SELECT value,revision FROM total_report_cells WHERE doc=? AND address=?`, key, c.Address).Scan(&old.Value, &old.Revision)
		if e != nil && e != sql.ErrNoRows {
			return Saved{}, e
		}
		if old.Revision != c.Expected {
			return Saved{}, fmt.Errorf("%w：%s", ErrConflict, c.Address)
		}
		old.Format, e = readFormat(tx, key, c.Address)
		if e != nil {
			return Saved{}, e
		}
		format := c.Format
		if format == nil {
			format = old.Format
		}
		if old.Value == c.Value && sameFormat(old.Format, format) {
			continue
		}
		if old.Value != "" && c.Value == "" {
			destructive = true
		}
		changes = append(changes, Cell{Address: c.Address, Value: c.Value, Revision: rev + 1, Actor: actor, Format: format})
	}
	if len(changes) > 0 {
		reason := "定时检查点"
		if destructive || len(changes) >= 100 {
			reason = "批量覆盖或清空前"
		}
		if _, e = s.checkpoint(tx, key, actor, reason, rev, destructive || len(changes) >= 100); e != nil {
			return Saved{}, e
		}
		rev++
		for _, c := range changes {
			if e = writeCell(tx, key, c); e != nil {
				return Saved{}, e
			}
		}
		if _, e = tx.Exec(`UPDATE total_report_docs SET revision=? WHERE doc=?`, rev, key); e != nil {
			return Saved{}, e
		}
	}
	result := Saved{rev, changes}
	if e = saveReceipt(tx, key, in.ID, hash, result); e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "edit"); e != nil {
		return Saved{}, e
	}
	e = tx.Commit()
	return result, e
}

func (s *Service) Changes(ctx context.Context, kind string, year int, after int64) (Saved, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return Saved{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil || after < 0 {
		return Saved{}, fmt.Errorf("无效修订号或报表")
	}
	tx, e := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable, ReadOnly: true})
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	var rev int64
	e = tx.QueryRow(`SELECT revision FROM total_report_docs WHERE doc=?`, key).Scan(&rev)
	if e == sql.ErrNoRows {
		return Saved{}, ErrMissing
	}
	if e != nil {
		return Saved{}, e
	}
	if after > rev {
		return Saved{}, ErrConflict
	}
	cells, e := readCells(tx, key, after)
	if e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "read"); e != nil {
		return Saved{}, e
	}
	return Saved{rev, cells}, tx.Commit()
}
func (s *Service) Checkpoints(ctx context.Context, kind string, year int, before int64) ([]Checkpoint, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return nil, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return nil, e
	}
	if before == 0 {
		before = 1 << 62
	}
	rows, e := s.db.QueryContext(ctx, `SELECT id,revision,created,actor,reason FROM total_report_checkpoints WHERE doc=? AND revision<? ORDER BY revision DESC LIMIT 100`, key, before)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Checkpoint{}
	for rows.Next() {
		var c Checkpoint
		if e = rows.Scan(&c.ID, &c.Revision, &c.Created, &c.Actor, &c.Reason); e != nil {
			return nil, e
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
func (s *Service) CreateCheckpoint(ctx context.Context, kind string, year int, expected int64) (Checkpoint, error) {
	actor, e := permission(ctx, "edit")
	if e != nil {
		return Checkpoint{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return Checkpoint{}, e
	}
	tx, rev, _, e := s.lock(ctx, key)
	if e != nil {
		return Checkpoint{}, e
	}
	defer tx.Rollback()
	if rev != expected {
		return Checkpoint{}, ErrConflict
	}
	cp, e := s.checkpoint(tx, key, actor, "手动检查点", rev, true)
	if e != nil {
		return cp, e
	}
	if _, e = permission(ctx, "edit"); e != nil {
		return cp, e
	}
	return cp, tx.Commit()
}
func (s *Service) Rollback(ctx context.Context, kind string, year int, in Rollback) (Saved, error) {
	actor, e := permission(ctx, "rollback")
	if e != nil {
		return Saved{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return Saved{}, e
	}
	if !operationID.MatchString(in.ID) || len(in.Addresses) > 10000 {
		return Saved{}, fmt.Errorf("回滚请求无效")
	}
	tx, rev, template, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	hash := digest(struct {
		Actor    string
		Rollback Rollback
	}{actor, in})
	cached, e := receipt(tx, key, in.ID, hash)
	if e != nil {
		return Saved{}, e
	}
	if cached != nil {
		return *cached, nil
	}
	if rev != in.Expected {
		return Saved{}, ErrConflict
	}
	var b []byte
	e = tx.QueryRow(`SELECT data FROM total_report_checkpoints WHERE doc=? AND id=?`, key, in.Checkpoint).Scan(&b)
	if e == sql.ErrNoRows {
		return Saved{}, ErrMissing
	}
	if e != nil {
		return Saved{}, e
	}
	snapshot, e := decodeCheckpoint(b)
	if e != nil {
		return Saved{}, e
	}
	current, e := readCells(tx, key, -1)
	if e != nil {
		return Saved{}, e
	}
	target := map[string]Cell{}
	all := map[string]bool{}
	old := map[string]Cell{}
	for _, c := range snapshot {
		target[c.Address] = c
		all[c.Address] = true
	}
	for _, c := range current {
		old[c.Address] = c
		all[c.Address] = true
	}
	if len(in.Addresses) > 0 {
		all = map[string]bool{}
		for _, a := range in.Addresses {
			if !cellAddress.MatchString(a) {
				return Saved{}, fmt.Errorf("回滚单元格无效")
			}
			all[a] = true
		}
	}
	changes := []Cell{}
	allowed := editable(template, year)
	for address := range all {
		if allowed[address] && (old[address].Value != target[address].Value || !sameFormat(old[address].Format, target[address].Format)) {
			var label string
			err := tx.QueryRow(`SELECT name FROM total_report_locks WHERE doc=? AND address=? AND expires>?`, key, address, s.now().Unix()).Scan(&label)
			if err == nil {
				return Saved{}, fmt.Errorf("%w：%s 正在编辑 %s，暂不能回滚", ErrConflict, label, address)
			}
			if err != sql.ErrNoRows {
				return Saved{}, err
			}
			changes = append(changes, Cell{Address: address, Value: target[address].Value, Revision: rev + 1, Actor: actor, Format: target[address].Format})
		}
	}
	if len(changes) > 0 {
		if _, e = s.checkpoint(tx, key, actor, "回滚前", rev, true); e != nil {
			return Saved{}, e
		}
		rev++
		for _, c := range changes {
			e = writeCell(tx, key, c)
			if e != nil {
				return Saved{}, e
			}
		}
		if _, e = tx.Exec(`UPDATE total_report_docs SET revision=? WHERE doc=?`, rev, key); e != nil {
			return Saved{}, e
		}
		if _, e = s.checkpoint(tx, key, actor, "回滚至 "+in.Checkpoint, rev, true); e != nil {
			return Saved{}, e
		}
	}
	result := Saved{rev, changes}
	if e = saveReceipt(tx, key, in.ID, hash, result); e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "rollback"); e != nil {
		return Saved{}, e
	}
	return result, tx.Commit()
}

// CheckpointDirty is called by the application timer, never by the UI. Idle
// documents do not write. Input deltas are compressed only once per interval.
func (s *Service) CheckpointDirty(ctx context.Context) error {
	rows, e := s.db.QueryContext(ctx, `SELECT doc FROM total_report_docs WHERE revision<>checkpoint_revision AND checkpoint_at<=?`, s.now().Unix()-600)
	if e != nil {
		return e
	}
	keys := []string{}
	for rows.Next() {
		var k string
		if e = rows.Scan(&k); e != nil {
			rows.Close()
			return e
		}
		keys = append(keys, k)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, k := range keys {
		tx, rev, _, err := s.lock(ctx, k)
		if err != nil {
			return err
		}
		_, err = s.checkpoint(tx, k, "system", "定时检查点", rev, false)
		if err != nil {
			tx.Rollback()
			return err
		}
		if err = tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

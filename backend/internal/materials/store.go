package materials

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

type Service struct{ db *persistence.DB }
type queryer interface {
	QueryRow(string, ...any) *sql.Row
	Query(string, ...any) (*sql.Rows, error)
}

func Open(db *persistence.DB) (*Service, error) {
	// Only additive, owned tables. Asset bytes live in the same backup domain as
	// their immutable references; startup never imports or rewrites legacy data.
	tx, e := db.Begin()
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	ddl := []string{
		`CREATE TABLE IF NOT EXISTS materials_guard (id INTEGER PRIMARY KEY, revision BIGINT NOT NULL)`,
		`INSERT INTO materials_guard(id,revision) VALUES(1,0) ON CONFLICT(id) DO NOTHING`,
		`CREATE TABLE IF NOT EXISTS materials_categories (id TEXT PRIMARY KEY, parent_id TEXT NOT NULL, name TEXT NOT NULL, version BIGINT NOT NULL, body TEXT NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS materials_categories_parent ON materials_categories(parent_id)`,
		`CREATE TABLE IF NOT EXISTS materials_category_deletions (id TEXT PRIMARY KEY REFERENCES materials_categories(id), deleted_at TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS materials_items (id TEXT PRIMARY KEY, category_id TEXT NOT NULL REFERENCES materials_categories(id), version BIGINT NOT NULL, search TEXT NOT NULL, body TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS materials_balances (item_id TEXT NOT NULL REFERENCES materials_items(id), category_id TEXT NOT NULL REFERENCES materials_categories(id), quantity BIGINT NOT NULL CHECK(quantity>=0), version BIGINT NOT NULL, PRIMARY KEY(item_id,category_id))`,
		`CREATE TABLE IF NOT EXISTS materials_applications (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, version BIGINT NOT NULL, status TEXT NOT NULL, created TEXT NOT NULL, search TEXT NOT NULL, body TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS materials_application_versions (application_id TEXT NOT NULL REFERENCES materials_applications(id), version BIGINT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(application_id,version))`,
		`CREATE TABLE IF NOT EXISTS materials_documents (id TEXT PRIMARY KEY, kind TEXT NOT NULL, owner_id TEXT NOT NULL, application_id TEXT NOT NULL, source_id TEXT NOT NULL, created TEXT NOT NULL, search TEXT NOT NULL, body TEXT NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS materials_documents_application ON materials_documents(application_id,created,id)`,
		`CREATE INDEX IF NOT EXISTS materials_documents_source ON materials_documents(source_id,created,id)`,
		`CREATE INDEX IF NOT EXISTS materials_documents_kind ON materials_documents(kind,created,id)`,
		`CREATE TABLE IF NOT EXISTS materials_lines (document_id TEXT NOT NULL REFERENCES materials_documents(id), id TEXT NOT NULL, item_id TEXT NOT NULL REFERENCES materials_items(id), category_id TEXT NOT NULL REFERENCES materials_categories(id), quantity BIGINT NOT NULL CHECK(quantity>0), returned BIGINT NOT NULL DEFAULT 0 CHECK(returned>=0 AND returned<=quantity), body TEXT NOT NULL, PRIMARY KEY(document_id,id))`,
		`CREATE INDEX IF NOT EXISTS materials_lines_item ON materials_lines(item_id,document_id)`,
		`CREATE TABLE IF NOT EXISTS materials_ledger (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES materials_documents(id), item_id TEXT NOT NULL, category_id TEXT NOT NULL, created TEXT NOT NULL, body TEXT NOT NULL)`,
		`CREATE INDEX IF NOT EXISTS materials_ledger_item ON materials_ledger(item_id,created,id)`,
		`CREATE INDEX IF NOT EXISTS materials_ledger_document ON materials_ledger(document_id,created,id)`,
		`CREATE TABLE IF NOT EXISTS materials_assets (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL, data TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS materials_signatures (user_id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES materials_assets(id), version BIGINT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS materials_signature_versions (user_id TEXT NOT NULL, version BIGINT NOT NULL, asset_id TEXT NOT NULL REFERENCES materials_assets(id), action TEXT NOT NULL, created TEXT NOT NULL, PRIMARY KEY(user_id,version))`,
		// Existing current signatures become an explicit migration version. Their
		// original creation time is unknown; do not invent one during startup.
		`INSERT INTO materials_signature_versions(user_id,version,asset_id,action,created) SELECT user_id,version,asset_id,'migrated','' FROM materials_signatures WHERE 1=1 ON CONFLICT(user_id,version) DO NOTHING`,
		`CREATE TABLE IF NOT EXISTS materials_application_signatures (application_id TEXT NOT NULL REFERENCES materials_applications(id), version BIGINT NOT NULL, asset_id TEXT NOT NULL REFERENCES materials_assets(id), PRIMARY KEY(application_id,version))`,
		`CREATE TABLE IF NOT EXISTS materials_document_assets (document_id TEXT NOT NULL REFERENCES materials_documents(id), asset_id TEXT NOT NULL REFERENCES materials_assets(id), PRIMARY KEY(document_id,asset_id))`,
		`CREATE TABLE IF NOT EXISTS materials_operations (actor_id TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT NOT NULL, PRIMARY KEY(actor_id,id))`,
	}
	for _, q := range ddl {
		if _, e = tx.Exec(q); e != nil {
			return nil, e
		}
	}
	if e = tx.Commit(); e != nil {
		return nil, e
	}
	return &Service{db: db}, nil
}

func actor(ctx context.Context, capability string) (authorization.Actor, error) {
	a, ok := authorization.FromContext(ctx)
	if !ok || a.ID == "" || !a.Active() || !may(a.Grants, capability) {
		return a, authorization.ErrDenied
	}
	return a, nil
}
func may(g authorization.Grants, capability string) bool {
	switch capability {
	case "personal":
		return true
	case "chains":
		return g.MaterialsRequest || g.MaterialsApprove || g.MaterialsInbound || g.MaterialsOutbound || g.MaterialsCatalog
	case "request":
		return g.MaterialsRequest
	case "approve":
		return g.MaterialsApprove
	case "inbound":
		return g.MaterialsInbound
	case "outbound", "return":
		return g.MaterialsOutbound
	case "catalog", "transfer":
		return g.MaterialsCatalog
	case "stock":
		return g.MaterialsInbound || g.MaterialsOutbound || g.MaterialsCatalog
	case "applications":
		return g.MaterialsRequest || g.MaterialsApprove || g.MaterialsInbound
	}
	return false
}
func id() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}

const timestampLayout = "2006-01-02T15:04:05.000000000Z"

func now() string { return time.Now().UTC().Format(timestampLayout) }
func number(prefix, key string) string {
	return prefix + "-" + time.Now().UTC().Format("20060102") + "-" + strings.ToUpper(key[:12])
}
func raw(v any) string {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return string(b)
}
func decodeBody(body string, v any) error { return json.Unmarshal([]byte(body), v) }
func textValid(v string, max int, required bool) bool {
	return utf8.ValidString(v) && utf8.RuneCountInString(v) <= max && (!required || strings.TrimSpace(v) != "") && !strings.ContainsRune(v, 0)
}
func readJSON[T any](q queryer, query string, args ...any) (T, error) {
	var v T
	var b string
	e := q.QueryRow(query, args...).Scan(&b)
	if e == sql.ErrNoRows {
		return v, ErrMissing
	}
	if e != nil {
		return v, e
	}
	e = json.Unmarshal([]byte(b), &v)
	return v, e
}
func readMany[T any](q queryer, query string, args ...any) ([]T, error) {
	rows, e := q.Query(query, args...)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []T{}
	for rows.Next() {
		var b string
		var v T
		if e = rows.Scan(&b); e != nil {
			return nil, e
		}
		if e = json.Unmarshal([]byte(b), &v); e != nil {
			return nil, e
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func mutate[T any](ctx context.Context, s *Service, capability, action, operation string, input any, fn func(*persistence.Tx, authorization.Actor) (T, error)) (T, error) {
	var zero T
	a, e := actor(ctx, capability)
	if e != nil {
		return zero, e
	}
	if !textValid(operation, 100, true) {
		return zero, errors.New("缺少有效操作ID")
	}
	encoded, e := json.Marshal(input)
	if e != nil {
		return zero, e
	}
	hash := sha256.Sum256(append([]byte(action+"\n"), encoded...))
	fingerprint := hex.EncodeToString(hash[:])
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return zero, e
	}
	defer tx.Rollback()
	// Database-owned serialization, not a process mutex. PostgreSQL row locks
	// and SQLite's write transaction protect all read/validate/write decisions.
	if _, e = tx.ExecContext(ctx, "UPDATE materials_guard SET revision=revision+1 WHERE id=1"); e != nil {
		return zero, e
	}
	if !a.Active() {
		return zero, authorization.ErrDenied
	}
	var oldHash, response string
	e = tx.QueryRow("SELECT fingerprint,response FROM materials_operations WHERE actor_id=? AND id=?", a.ID, operation).Scan(&oldHash, &response)
	if e == nil {
		if oldHash != fingerprint {
			return zero, ErrConflict
		}
		e = json.Unmarshal([]byte(response), &zero)
		return zero, e
	}
	if e != sql.ErrNoRows {
		return zero, e
	}
	v, e := fn(tx, a)
	if e != nil {
		return zero, e
	}
	if !a.Active() {
		return zero, authorization.ErrDenied
	}
	if _, e = tx.Exec("INSERT INTO materials_operations(actor_id,id,fingerprint,response) VALUES(?,?,?,?)", a.ID, operation, fingerprint, raw(v)); e != nil {
		return zero, e
	}
	if e = tx.Commit(); e != nil {
		return zero, e
	}
	return v, nil
}

func pagination(f Filter) (Filter, error) {
	if f.Limit == 0 {
		f.Limit = 50
	}
	if f.Limit < 1 || f.Limit > 200 || f.Offset < 0 || f.Offset > 10000000 || f.SummaryOffset < 0 || f.SummaryOffset > 10000000 || !textValid(f.Search, 200, false) {
		return f, errors.New("分页或搜索条件无效")
	}
	for _, v := range []*string{&f.From, &f.To, &f.Until} {
		if *v != "" {
			parsed, e := time.Parse(time.RFC3339Nano, *v)
			if e != nil {
				return f, errors.New("时间筛选无效")
			}
			*v = parsed.UTC().Format(timestampLayout)
		}
	}
	if f.From != "" && (f.To != "" && f.From > f.To || f.Until != "" && f.From >= f.Until) {
		return f, errors.New("开始时间不能晚于结束时间")
	}
	return f, nil
}
func like(v string) string {
	return "%" + strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(strings.ToLower(v), "!", "!!"), "%", "!%"), "_", "!_") + "%"
}
func paged[T any](q queryer, table, where, order string, args []any, f Filter) (Page[T], error) {
	p := Page[T]{Items: []T{}}
	f, e := pagination(f)
	if e != nil {
		return p, e
	}
	if e = q.QueryRow("SELECT COUNT(*) FROM "+table+" WHERE "+where, args...).Scan(&p.Total); e != nil {
		return p, e
	}
	params := append(append([]any{}, args...), f.Limit, f.Offset)
	p.Items, e = readMany[T](q, "SELECT body FROM "+table+" WHERE "+where+" ORDER BY "+order+" LIMIT ? OFFSET ?", params...)
	return p, e
}
func getCategory(q queryer, key string) (Category, error) {
	return readJSON[Category](q, "SELECT body FROM materials_categories WHERE id=?", key)
}
func getItem(q queryer, key string) (Item, error) {
	return readJSON[Item](q, "SELECT body FROM materials_items WHERE id=?", key)
}
func getApplication(q queryer, key string) (Application, error) {
	return readJSON[Application](q, "SELECT body FROM materials_applications WHERE id=?", key)
}
func getDocument(q queryer, key string) (Document, error) {
	return readJSON[Document](q, "SELECT body FROM materials_documents WHERE id=?", key)
}
func balance(q queryer, item, category string) (n, version int64, e error) {
	e = q.QueryRow("SELECT quantity,version FROM materials_balances WHERE item_id=? AND category_id=?", item, category).Scan(&n, &version)
	if e == sql.ErrNoRows {
		e = nil
	}
	return
}
func changeBalance(tx *persistence.Tx, item, category string, delta int64) error {
	if delta > 0 {
		var total int64
		if e := tx.QueryRow("SELECT COALESCE(SUM(quantity),0) FROM materials_balances WHERE item_id=?", item).Scan(&total); e != nil {
			return e
		}
		if total > maxUnits-delta {
			return invalid("物料库存总量")
		}
	}
	if _, e := tx.Exec("INSERT INTO materials_balances(item_id,category_id,quantity,version) VALUES(?,?,0,0) ON CONFLICT(item_id,category_id) DO NOTHING", item, category); e != nil {
		return e
	}
	res, e := tx.Exec("UPDATE materials_balances SET quantity=quantity+?,version=version+1 WHERE item_id=? AND category_id=? AND quantity+?>=0 AND quantity+?<=?", delta, item, category, delta, delta, maxUnits)
	if e != nil {
		return e
	}
	n, e := res.RowsAffected()
	if e != nil {
		return e
	}
	if n != 1 {
		return ErrStock
	}
	return nil
}
func signature(q queryer, user string) (Signature, error) {
	var v Signature
	e := q.QueryRow(`SELECT CASE WHEN h.action='deleted' THEN '' ELSE s.asset_id END,s.version FROM materials_signatures s LEFT JOIN materials_signature_versions h ON h.user_id=s.user_id AND h.version=s.version WHERE s.user_id=?`, user).Scan(&v.AssetID, &v.Version)
	if e == sql.ErrNoRows {
		return v, nil
	}
	return v, e
}
func confirmedSignature(q queryer, user string, version int64) (string, error) {
	v, e := signature(q, user)
	if e != nil {
		return "", e
	}
	if v.AssetID == "" {
		return "", ErrSignature
	}
	if version != v.Version {
		return "", ErrConflict
	}
	return v.AssetID, nil
}
func invalid(field string) error { return fmt.Errorf("%s无效", field) }

// Package persistence supplies database adapters; it owns no HMI business rules.
package persistence

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	_ "modernc.org/sqlite"
)

type DB struct {
	*sql.DB
	PostgreSQL bool
}
type Tx struct {
	*sql.Tx
	pg bool
}

// ConfigFile never includes credentials in returned diagnostics.
func ConfigFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("cannot read database configuration")
	}
	var c struct {
		DSN string `json:"dsn"`
	}
	if json.Unmarshal(b, &c) != nil || c.DSN == "" {
		return "", errors.New("invalid database configuration")
	}
	return c.DSN, nil
}

func Open(path, dsn string) (*DB, error) {
	if dsn == "" {
		db, e := sql.Open("sqlite", path)
		if e != nil {
			return nil, e
		}
		db.SetMaxOpenConns(1)
		return &DB{db, false}, nil
	}
	cfg, e := pgx.ParseConfig(dsn)
	if e != nil {
		return nil, errors.New("invalid PostgreSQL connection configuration")
	}
	cfg.ConnectTimeout = 5 * time.Second
	if cfg.RuntimeParams["search_path"] == "" {
		cfg.RuntimeParams["search_path"] = "public"
	}
	cfg.RuntimeParams["statement_timeout"] = "15000"
	cfg.RuntimeParams["application_name"] = "universal_hmi"
	db := stdlib.OpenDB(*cfg)
	db.SetMaxOpenConns(4)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	if e = db.PingContext(ctx); e != nil {
		db.Close()
		return nil, errors.New("PostgreSQL connection failed; check local service and private database configuration")
	}
	return &DB{db, true}, nil
}

// Schema converts only the owned, fixed DDL used by the two legacy adapters.
func (d *DB) Schema(queries []string) error {
	for _, q := range queries {
		if d.PostgreSQL {
			if strings.HasPrefix(q, "PRAGMA ") {
				continue
			}
			q = strings.ReplaceAll(q, "INTEGER PRIMARY KEY AUTOINCREMENT", "BIGSERIAL PRIMARY KEY")
			q = strings.ReplaceAll(q, " INTEGER", " BIGINT")
			q = strings.ReplaceAll(q, " REAL", " DOUBLE PRECISION")
			q = strings.ReplaceAll(q, " BLOB", " BYTEA")
		}
		if _, e := d.Exec(q); e != nil {
			return e
		}
	}
	return nil
}

// Bind rewrites owned SQL placeholders, preserving quoted literals/identifiers.
func Bind(q string, pg bool) string {
	if !pg {
		return q
	}
	var b strings.Builder
	n := 0
	var quote byte
	for i := 0; i < len(q); i++ {
		c := q[i]
		if quote != 0 {
			b.WriteByte(c)
			if c == quote {
				if i+1 < len(q) && q[i+1] == quote {
					i++
					b.WriteByte(q[i])
				} else {
					quote = 0
				}
			}
			continue
		}
		if c == '\'' || c == '"' {
			quote = c
		}
		if c == '?' {
			n++
			b.WriteByte('$')
			b.WriteString(strconv.Itoa(n))
		} else {
			b.WriteByte(c)
		}
	}
	return b.String()
}
func argsPG(a []any, pg bool) []any {
	if !pg {
		return a
	}
	out := append([]any(nil), a...)
	for i, v := range out {
		if b, ok := v.(bool); ok {
			if b {
				out[i] = int64(1)
			} else {
				out[i] = int64(0)
			}
		}
	}
	return out
}
func (d *DB) Exec(q string, a ...any) (sql.Result, error) {
	return d.ExecContext(context.Background(), q, a...)
}
func (d *DB) ExecContext(c context.Context, q string, a ...any) (sql.Result, error) {
	return d.DB.ExecContext(c, Bind(q, d.PostgreSQL), argsPG(a, d.PostgreSQL)...)
}
func (d *DB) Query(q string, a ...any) (*sql.Rows, error) {
	return d.QueryContext(context.Background(), q, a...)
}
func (d *DB) QueryContext(c context.Context, q string, a ...any) (*sql.Rows, error) {
	return d.DB.QueryContext(c, Bind(q, d.PostgreSQL), argsPG(a, d.PostgreSQL)...)
}
func (d *DB) QueryRow(q string, a ...any) *sql.Row {
	return d.QueryRowContext(context.Background(), q, a...)
}
func (d *DB) QueryRowContext(c context.Context, q string, a ...any) *sql.Row {
	return d.DB.QueryRowContext(c, Bind(q, d.PostgreSQL), argsPG(a, d.PostgreSQL)...)
}
func (d *DB) Begin() (*Tx, error) { return d.BeginTx(context.Background(), nil) }
func (d *DB) BeginTx(c context.Context, o *sql.TxOptions) (*Tx, error) {
	t, e := d.DB.BeginTx(c, o)
	return &Tx{t, d.PostgreSQL}, e
}
func (t *Tx) Exec(q string, a ...any) (sql.Result, error) {
	return t.ExecContext(context.Background(), q, a...)
}
func (t *Tx) ExecContext(c context.Context, q string, a ...any) (sql.Result, error) {
	return t.Tx.ExecContext(c, Bind(q, t.pg), argsPG(a, t.pg)...)
}
func (t *Tx) QueryRow(q string, a ...any) *sql.Row {
	return t.QueryRowContext(context.Background(), q, a...)
}
func (t *Tx) QueryRowContext(c context.Context, q string, a ...any) *sql.Row {
	return t.Tx.QueryRowContext(c, Bind(q, t.pg), argsPG(a, t.pg)...)
}
func (t *Tx) Query(q string, a ...any) (*sql.Rows, error) {
	return t.Tx.Query(Bind(q, t.pg), argsPG(a, t.pg)...)
}
func (t *Tx) PrepareContext(c context.Context, q string) (*sql.Stmt, error) {
	return t.Tx.PrepareContext(c, Bind(q, t.pg))
}

// Lease prevents two HMI engines from collecting/acting against the same project.
// The dedicated connection stays alive for the entire server lifetime.
func (d *DB) Lease(ctx context.Context) (*sql.Conn, error) {
	c, e := d.Conn(ctx)
	if e != nil {
		return nil, e
	}
	var ok bool
	e = c.QueryRowContext(ctx, "SELECT pg_try_advisory_lock(812301527)").Scan(&ok)
	if e != nil || !ok {
		c.Close()
		return nil, fmt.Errorf("this PostgreSQL project already has an active HMI backend or cannot acquire its lease")
	}
	return c, nil
}

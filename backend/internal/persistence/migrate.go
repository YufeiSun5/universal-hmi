package persistence

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// ImportLegacy runs only while the source server is stopped, into an empty PG
// project. It never overwrites existing PostgreSQL data or edits source files.
// Table names are an internal allowlist, never user input.
func ImportLegacy(ctx context.Context, dir string, db *DB) (map[string]int, error) {
	if !db.PostgreSQL {
		return nil, fmt.Errorf("migration requires PostgreSQL")
	}
	tx, e := db.BeginTx(ctx, nil)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	groups := map[string][]string{"history.db": {"samples", "config", "executions"}, "security/identity.db": {"users", "stations", "audit", "mfa", "recovery", "custom_roles", "user_role_policy"}}
	counts := map[string]int{}
	for _, tables := range groups {
		for _, table := range tables {
			var n int
			if e = tx.QueryRow("SELECT count(*) FROM " + table).Scan(&n); e != nil {
				return nil, e
			}
			if n != 0 {
				return nil, fmt.Errorf("migration target is not empty: %s", table)
			}
		}
	}
	var n int
	if e = tx.QueryRow("SELECT count(*) FROM documents").Scan(&n); e != nil || n != 0 {
		return nil, fmt.Errorf("migration target documents are not empty or unreadable")
	}
	for file, tables := range groups {
		path := filepath.Join(dir, file)
		if _, e = os.Stat(path); os.IsNotExist(e) {
			continue
		} else if e != nil {
			return nil, e
		}
		src, err := sql.Open("sqlite", filepath.ToSlash(path)+"?mode=ro")
		if err != nil {
			return nil, err
		}
		for _, table := range tables {
			if table == "custom_roles" || table == "user_role_policy" {
				var exists int
				if err = src.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&exists); err != nil {
					src.Close()
					return nil, err
				}
				if exists == 0 {
					continue
				}
			}
			err = copyTable(ctx, src, tx, table, counts)
			if err != nil {
				src.Close()
				return nil, err
			}
		}
		src.Close()
	}
	add := func(kind, id, path string) error {
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		if _, e = tx.Exec("INSERT INTO documents(kind,id,data) VALUES(?,?,?)", kind, id, b); e != nil {
			return e
		}
		var actual []byte
		if e = tx.QueryRow("SELECT data FROM documents WHERE kind=? AND id=?", kind, id).Scan(&actual); e != nil {
			return e
		}
		if sha256.Sum256(b) != sha256.Sum256(actual) {
			return fmt.Errorf("document verification failed")
		}
		counts[kind]++
		return nil
	}
	path := filepath.Join(dir, "points.json")
	if _, e = os.Stat(path); e == nil {
		if e = add("points", "definitions", path); e != nil {
			return nil, e
		}
	} else if !os.IsNotExist(e) {
		return nil, e
	}
	for _, kind := range []string{"screens", "materials"} {
		folder := filepath.Join(dir, "screens")
		if kind == "materials" {
			folder = filepath.Join(folder, "materials")
		}
		entries, err := os.ReadDir(folder)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".json") {
				if e = add(kind, strings.TrimSuffix(entry.Name(), ".json"), filepath.Join(folder, entry.Name())); e != nil {
					return nil, e
				}
			}
		}
	}
	for _, table := range []string{"samples", "executions", "audit"} {
		// PG sequences are independent from explicitly imported historical sequence IDs.
		if _, e = tx.Exec("SELECT setval(pg_get_serial_sequence('" + table + "','seq'), COALESCE((SELECT MAX(seq) FROM " + table + "),1), EXISTS(SELECT 1 FROM " + table + "))"); e != nil {
			return nil, e
		}
	}
	if _, e = tx.Exec("INSERT INTO config(key,value) VALUES('postgres_migration','{\"completed\":true}')"); e != nil {
		return nil, e
	}
	if e = tx.Commit(); e != nil {
		return nil, e
	}
	return counts, nil
}

func copyTable(ctx context.Context, src *sql.DB, tx *Tx, table string, counts map[string]int) error {
	rows, e := src.QueryContext(ctx, "SELECT * FROM "+table)
	if e != nil {
		return e
	}
	defer rows.Close()
	cols, e := rows.Columns()
	if e != nil {
		return e
	}
	holders := make([]string, len(cols))
	for i := range holders {
		holders[i] = "?"
	}
	counts[table] = 0
	for rows.Next() {
		values := make([]any, len(cols))
		dest := make([]any, len(cols))
		for i := range values {
			dest[i] = &values[i]
		}
		if e = rows.Scan(dest...); e != nil {
			return e
		}
		if _, e = tx.Exec("INSERT INTO "+table+"("+strings.Join(cols, ",")+") VALUES("+strings.Join(holders, ",")+")", values...); e != nil {
			return e
		}
		// Every imported row is read back within the same transaction. SQLite and PG
		// use the same integer/text/blob representation for these owned schemas.
		key := cols[0]
		q := "SELECT * FROM " + table + " WHERE " + key + "=?"
		args := []any{values[0]}
		if table == "recovery" {
			q += " AND digest=?"
			args = append(args, values[1])
		}
		actual := make([]any, len(cols))
		scan := make([]any, len(cols))
		for i := range actual {
			scan[i] = &actual[i]
		}
		if e = tx.QueryRow(q, args...).Scan(scan...); e != nil {
			return e
		}
		if !reflect.DeepEqual(values, actual) {
			return fmt.Errorf("migration row verification failed in %s", table)
		}
		counts[table]++
	}
	return rows.Err()
}

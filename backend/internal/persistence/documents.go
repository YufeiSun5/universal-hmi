package persistence

import (
	"context"
	"database/sql"
	"errors"
	"os"
)

// SaveWithRecovery commits a complete document with a create-only recovery record.
func (d *Documents) SaveWithRecovery(kind, id string, data []byte, recoveryKind, recoveryID string, recovery []byte) error {
	tx, err := d.DB.BeginTx(context.Background(), nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("INSERT INTO documents(kind,id,data) VALUES(?,?,?)", recoveryKind, recoveryID, recovery); err != nil {
		return err
	}
	if _, err = tx.Exec("INSERT INTO documents(kind,id,data) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data", kind, id, data); err != nil {
		return err
	}
	return tx.Commit()
}

// Documents stores complete JSON bytes without changing domain revision semantics.
type Documents struct{ DB *DB }

func NewDocuments(db *DB) (*Documents, error) {
	_, e := db.Exec("CREATE TABLE IF NOT EXISTS documents(kind TEXT NOT NULL,id TEXT NOT NULL,data BYTEA NOT NULL,PRIMARY KEY(kind,id))")
	return &Documents{db}, e
}
func (d *Documents) Load(kind, id string) ([]byte, error) {
	var b []byte
	e := d.DB.QueryRow("SELECT data FROM documents WHERE kind=? AND id=?", kind, id).Scan(&b)
	if errors.Is(e, sql.ErrNoRows) {
		return nil, os.ErrNotExist
	}
	return b, e
}
func (d *Documents) Names(kind string) ([]string, error) {
	rows, e := d.DB.Query("SELECT id FROM documents WHERE kind=? ORDER BY id", kind)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if e = rows.Scan(&id); e != nil {
			return nil, e
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
func (d *Documents) Save(kind, id string, b []byte) error {
	_, e := d.DB.Exec("INSERT INTO documents(kind,id,data) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data", kind, id, b)
	return e
}
func (d *Documents) Delete(kind, id string) error {
	_, e := d.DB.Exec("DELETE FROM documents WHERE kind=? AND id=?", kind, id)
	return e
}

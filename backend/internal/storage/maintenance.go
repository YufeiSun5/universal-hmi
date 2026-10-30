package storage

import (
	"context"
	"encoding/json"
	"reflect"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

// ConfigurationSnapshot exposes configuration bytes without granting access to
// history, identities or audit tables. Maintenance executes one atomic change.
type ConfigurationSnapshot struct {
	Config    map[string]json.RawMessage
	Documents map[string]map[string]json.RawMessage
}

func readConfiguration(tx *persistence.Tx, documentsExist bool) (ConfigurationSnapshot, error) {
	s := ConfigurationSnapshot{Config: map[string]json.RawMessage{}, Documents: map[string]map[string]json.RawMessage{}}
	rows, e := tx.Query("SELECT key,value FROM config ORDER BY key")
	if e != nil {
		return s, e
	}
	for rows.Next() {
		var k string
		var v []byte
		if e = rows.Scan(&k, &v); e != nil {
			rows.Close()
			return s, e
		}
		s.Config[k] = append([]byte(nil), v...)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return s, e
	}
	if !documentsExist {
		return s, nil
	}
	rows, e = tx.Query("SELECT kind,id,data FROM documents ORDER BY kind,id")
	if e != nil {
		return s, e
	}
	defer rows.Close()
	for rows.Next() {
		var k, id string
		var v []byte
		if e = rows.Scan(&k, &id, &v); e != nil {
			return s, e
		}
		if s.Documents[k] == nil {
			s.Documents[k] = map[string]json.RawMessage{}
		}
		s.Documents[k][id] = append([]byte(nil), v...)
	}
	return s, rows.Err()
}

func (s *Store) MaintainConfiguration(ctx context.Context, write bool, change func(*ConfigurationSnapshot) error) error {
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if s.DB.PostgreSQL {
		if _, e = tx.Exec("LOCK TABLE config, documents IN EXCLUSIVE MODE"); e != nil {
			return e
		}
	}
	documentsExist := true
	if !s.DB.PostgreSQL {
		var count int
		if e = tx.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents'").Scan(&count); e != nil {
			return e
		}
		documentsExist = count > 0
	}
	before, e := readConfiguration(tx, documentsExist)
	if e != nil {
		return e
	}
	after := ConfigurationSnapshot{Config: map[string]json.RawMessage{}, Documents: map[string]map[string]json.RawMessage{}}
	for k, v := range before.Config {
		after.Config[k] = append([]byte(nil), v...)
	}
	for kind, docs := range before.Documents {
		after.Documents[kind] = map[string]json.RawMessage{}
		for id, v := range docs {
			after.Documents[kind][id] = append([]byte(nil), v...)
		}
	}
	if e = change(&after); e != nil {
		return e
	}
	if !write {
		return nil
	}
	for k, v := range before.Config {
		if _, ok := after.Config[k]; !ok {
			if _, e = tx.Exec("DELETE FROM config WHERE key=?", k); e != nil {
				return e
			}
		} else if reflect.DeepEqual(v, after.Config[k]) {
			continue
		}
	}
	for k, v := range after.Config {
		if reflect.DeepEqual(before.Config[k], v) {
			continue
		}
		if _, e = tx.Exec("INSERT INTO config(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", k, string(v)); e != nil {
			return e
		}
	}
	for kind, docs := range before.Documents {
		for id := range docs {
			if _, ok := after.Documents[kind][id]; !ok {
				if _, e = tx.Exec("DELETE FROM documents WHERE kind=? AND id=?", kind, id); e != nil {
					return e
				}
			}
		}
	}
	for kind, docs := range after.Documents {
		for id, v := range docs {
			if reflect.DeepEqual(before.Documents[kind][id], v) {
				continue
			}
			if _, e = tx.Exec("INSERT INTO documents(kind,id,data) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data", kind, id, []byte(v)); e != nil {
				return e
			}
		}
	}
	return tx.Commit()
}

package storage

import "encoding/json"

// CompareAndSwapConfig atomically replaces one persisted configuration value.
// A nil previous value means that the key must not exist yet.
func (s *Store) CompareAndSwapConfig(key string, previous, next any) (bool, error) {
	b, err := json.Marshal(next)
	if err != nil {
		return false, err
	}
	if previous == nil {
		r, e := s.DB.Exec("INSERT INTO config(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", key, string(b))
		if e != nil {
			return false, e
		}
		n, e := r.RowsAffected()
		return n == 1, e
	}
	a, err := json.Marshal(previous)
	if err != nil {
		return false, err
	}
	r, err := s.DB.Exec("UPDATE config SET value=? WHERE key=? AND value=?", string(b), key, string(a))
	if err != nil {
		return false, err
	}
	n, err := r.RowsAffected()
	return n == 1, err
}

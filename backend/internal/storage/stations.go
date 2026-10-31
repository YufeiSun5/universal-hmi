package storage

// StationNames returns historical immutable station keys without loading samples.
func (s *Store) StationNames() ([]string, error) {
	rows, err := s.DB.Query("SELECT DISTINCT station FROM samples ORDER BY station")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		if n != "" {
			out = append(out, n)
		}
	}
	return out, rows.Err()
}

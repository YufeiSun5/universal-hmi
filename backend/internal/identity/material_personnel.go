package identity

import "github.com/YufeiSun5/universal-hmi/backend/internal/authorization"

// MaterialPersonnel discloses only active account labels for optional document
// attribution. It grants no access to account policies or signature assets.
func (s *Service) MaterialPersonnel(a authorization.Actor) (map[string]string, error) {
	if !a.Active() || (!a.Grants.MaterialsInbound && !a.Grants.MaterialsOutbound) {
		return nil, ErrDenied
	}
	rows, e := s.db.Query("SELECT id,username FROM users WHERE disabled=? ORDER BY username", false)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, name string
		if e = rows.Scan(&id, &name); e != nil {
			return nil, e
		}
		out[id] = name
	}
	return out, rows.Err()
}

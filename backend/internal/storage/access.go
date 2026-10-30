package storage

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func ScopeFilter(ctx context.Context, f Filter) (Filter, error) {
	a, ok := authorization.FromContext(ctx)
	if !ok {
		return f, nil
	}
	if !a.Active() {
		return f, authorization.ErrDenied
	}
	if f.Station != "" && !a.Station(f.Station) {
		return f, authorization.ErrDenied
	}
	if !a.Grants.AllStations {
		allowed := make([]string, 0, len(a.StationNames))
		for _, name := range a.StationNames {
			if f.AllowedStations == nil {
				allowed = append(allowed, name)
				continue
			}
			for _, old := range f.AllowedStations {
				if old == name {
					allowed = append(allowed, name)
					break
				}
			}
		}
		f.AllowedStations = allowed
	}
	return f, nil
}
func (s *Store) BoundaryFor(ctx context.Context, f Filter) (int64, error) {
	f, err := ScopeFilter(ctx, f)
	if err != nil {
		return 0, err
	}
	w, args := where(f)
	var seq int64
	err = s.DB.QueryRowContext(ctx, "SELECT COALESCE(MAX(seq),0) FROM samples WHERE "+w, args...).Scan(&seq)
	return seq, err
}

package analysis

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func accessContext(contexts []context.Context) context.Context {
	if len(contexts) > 0 && contexts[0] != nil {
		return contexts[0]
	}
	return context.Background()
}
func fileAccess(ctx context.Context, owner string, version int64) error {
	a, ok := authorization.FromContext(ctx)
	if !ok {
		return nil
	}
	if !a.Active() || !a.Grants.Export || a.ID != owner || a.Version != version {
		return authorization.ErrDenied
	}
	return nil
}
func (s *Service) importAccess(ctx context.Context, m Mapping) error {
	a, ok := authorization.FromContext(ctx)
	if !ok {
		return nil
	}
	if !a.Active() || !a.Grants.Export || !a.Station(m.Station) {
		return authorization.ErrDenied
	}
	s.mu.Lock()
	v, exists := s.sessions[m.SessionID]
	s.mu.Unlock()
	if !exists {
		return authorization.ErrDenied
	}
	return fileAccess(ctx, v.Owner, v.Version)
}

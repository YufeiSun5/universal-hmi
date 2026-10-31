package points

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

// Visible is the public read projection. Runtime users cannot retrieve formulas,
// dependencies, broker paths or write mappings through the point catalog.
func (s *Service) Visible(ctx context.Context) ([]Definition, error) {
	a, secured := authorization.FromContext(ctx)
	rows := s.List()
	if !secured {
		return rows, nil
	}
	if !a.Active() {
		return nil, authorization.ErrDenied
	}
	out := make([]Definition, 0, len(rows))
	for _, p := range rows {
		if !a.Station(p.Station) {
			continue
		}
		if !a.Grants.Develop() {
			p.SourceID = ""
			p.SourcePath = ""
			p.Topic = ""
			p.WriteTopic = ""
			p.WriteSourceID = ""
			p.WritePath = ""
			p.Expression = ""
			p.Inputs = nil
			p.ScaleFactor = 1
			p.Offset = 0
			p.Writable = p.Writable && a.Grants.Control
		}
		out = append(out, p)
	}
	return out, nil
}

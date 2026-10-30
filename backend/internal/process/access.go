package process

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func (s *Service) VisibleList(ctx context.Context, station string, all bool) ([]Summary, error) {
	a, secured := authorization.FromContext(ctx)
	if secured && !a.Active() {
		return nil, authorization.ErrDenied
	}
	var rows []Summary
	var err error
	if all {
		rows, err = s.ListAll()
	} else {
		rows, err = s.List(station)
	}
	if err != nil || !secured {
		return rows, err
	}
	out := []Summary{}
	for _, row := range rows {
		if a.Screen(row.ID, row.Station) {
			out = append(out, row)
		}
	}
	return out, nil
}

// Explicit screen grants include static artwork, but never confer access to
// referenced point values or navigation targets belonging to other resources.
func (s *Service) VisibleDocument(ctx context.Context, id string, canPoint func(string) bool) (Document, error) {
	d, err := s.Get(id)
	if err != nil {
		return d, err
	}
	a, secured := authorization.FromContext(ctx)
	if !secured {
		return d, nil
	}
	if !a.Active() || !a.Screen(d.ID, d.Station) {
		return Document{}, authorization.ErrDenied
	}
	if a.Grants.Develop() {
		return d, nil
	}
	// Runtime readers receive the resolved artwork and authorized point IDs only.
	d.Bindings = nil
	for i := range d.Nodes {
		n := &d.Nodes[i]
		if !canPoint(n.PointID) {
			n.PointID = ""
		}
		for _, rule := range []*ArrowRule{n.ArrowVisibleRule, n.ArrowMotionRule} {
			if rule != nil {
				for j := range rule.Conditions {
					if !canPoint(rule.Conditions[j].PointID) {
						rule.Conditions[j].PointID = ""
					}
				}
			}
		}
	}
	if d.GIS != nil {
		for i := range d.GIS.Stations {
			st := &d.GIS.Stations[i]
			for _, group := range st.BindingGroups() {
				for slot, point := range group {
					if !canPoint(point) {
						delete(group, slot)
					}
				}
			}
			if st.TargetScreenID != "" {
				target, e := s.Get(st.TargetScreenID)
				if e != nil || !a.Screen(target.ID, target.Station) {
					st.TargetScreenID = ""
				}
			}
		}
	}
	return d, nil
}

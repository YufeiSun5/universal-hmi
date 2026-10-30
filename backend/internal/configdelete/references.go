package configdelete

import (
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

// Runtime definitions may intentionally remain active until Apply. New saved
// configuration must instead reference the current saved catalog.
func (s *Service) ValidateReferences(station string, ids []string) error {
	ps, ss := s.Points, s.Stations
	if err := ss.CheckWritable(station); err != nil {
		return err
	}
	index := map[string]points.Definition{}
	for _, p := range ps.List() {
		index[p.ID] = p
	}
	for _, id := range ids {
		if _, ok := index[id]; !ok {
			return fmt.Errorf("saved point no longer exists: %s", id)
		}
	}
	if station != "" {
		all, err := ss.List()
		if err != nil {
			return err
		}
		for _, s := range all {
			if s.Name == station {
				return nil
			}
		}
		return fmt.Errorf("station no longer exists: %s", station)
	}
	return nil
}

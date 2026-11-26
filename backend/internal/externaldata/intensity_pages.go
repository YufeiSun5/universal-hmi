package externaldata

import (
	"context"
	"fmt"
)

var intensityPageKinds = []struct{ metric, name string }{
	{"heat", "热单耗"}, {"water", "水单耗"}, {"electricity", "电单耗"},
}

type intensityPageStyle struct {
	Revision      int64                   `json:"revision"`
	ReportLayouts map[string]ReportLayout `json:"report_layouts,omitempty"`
}

func intensityPageID(parent, metric string) string {
	return parent + "-intensity-" + metric
}

func (c config) availableScreens() []Screen {
	energyCount := 0
	for _, screen := range c.Screens {
		if screen.Kind == "energy" {
			energyCount++
		}
	}
	screens := make([]Screen, 0, len(c.Screens)+energyCount*len(intensityPageKinds))
	for _, parent := range c.Screens {
		screens = append(screens, parent)
		if parent.Kind != "energy" {
			continue
		}
		for _, item := range intensityPageKinds {
			id := intensityPageID(parent.ID, item.metric)
			style := c.IntensityStyles[id]
			name := item.name
			if energyCount > 1 {
				name = parent.Name + " · " + name
			}
			screens = append(screens, Screen{ID: id, Name: name, SourceID: parent.SourceID, Kind: "intensity",
				Metric: item.metric, Revision: max(1, style.Revision), ReportLayouts: style.ReportLayouts})
		}
	}
	return screens
}

func (s *Service) saveIntensityStyle(draft Screen) (Screen, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.load()
	if err != nil {
		return Screen{}, err
	}
	for _, screen := range c.availableScreens() {
		if screen.ID != draft.ID || screen.Kind != "intensity" {
			continue
		}
		if draft.Revision != screen.Revision {
			return Screen{}, ErrConflict
		}
		if draft.SourceID != screen.SourceID || draft.Metric != screen.Metric {
			return Screen{}, fmt.Errorf("单耗画面的计量指标和数据源须与对应菜单一致")
		}
		if draft.ReportLayouts != nil {
			screen.ReportLayouts = draft.ReportLayouts
		}
		screen.Revision++
		if c.IntensityStyles == nil {
			c.IntensityStyles = map[string]intensityPageStyle{}
		}
		c.IntensityStyles[screen.ID] = intensityPageStyle{Revision: screen.Revision, ReportLayouts: screen.ReportLayouts}
		if err := s.repo.SaveConfig("external_data_v1", c); err != nil {
			return Screen{}, err
		}
		return screen, nil
	}
	return Screen{}, ErrMissing
}

func mayReadIntensity(ctx context.Context, screen Screen, metric string) bool {
	if screen.Kind == "intensity" {
		return mayRead(ctx, screen.ID)
	}
	if metric != "" {
		return mayRead(ctx, intensityPageID(screen.ID, metric))
	}
	for _, item := range intensityPageKinds {
		if !mayRead(ctx, intensityPageID(screen.ID, item.metric)) {
			return false
		}
	}
	return true
}

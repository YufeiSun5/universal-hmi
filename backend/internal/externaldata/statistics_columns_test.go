package externaldata

import (
	"context"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

func TestStatisticsColumnsSavePreserveConflictAndPermission(t *testing.T) {
	s, src, _ := fixture(t)
	ctx := context.Background()
	v, err := s.SaveScreen(ctx, Screen{Name: "能耗", Kind: "energy", SourceID: src.ID})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range statisticsKeys(v.Kind) {
		v.StatisticsColumns = append(v.StatisticsColumns, DisplayColumn{Key: key, Label: " 自定义列名 ", Visible: key == "date"})
	}
	v.StatisticsColumns[0], v.StatisticsColumns[1] = v.StatisticsColumns[1], v.StatisticsColumns[0]
	saved, err := s.SaveScreen(ctx, v)
	if err != nil || saved.StatisticsColumns[0].Label != "自定义列名" || saved.StatisticsColumns[0].Key != "station" {
		t.Fatal(saved, err)
	}
	if _, err = s.SaveScreen(ctx, v); !errors.Is(err, ErrConflict) {
		t.Fatal("stale layout was accepted", err)
	}
	reader := authorization.WithActor(ctx, authorization.Actor{Grants: authorization.Grants{ExternalScreenIDs: []string{saved.ID}}, Valid: func() bool { return true }})
	if _, err = s.SaveScreen(reader, saved); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("runtime changed layout", err)
	}
	saved.Name = "改名"
	saved.StatisticsColumns = nil
	renamed, err := s.SaveScreen(ctx, saved)
	if err != nil || len(renamed.StatisticsColumns) != len(statisticsKeys("energy")) || renamed.StatisticsColumns[0].Key != "station" {
		t.Fatal(renamed, err)
	}
	// An omitted layout on a name edit preserves all saved settings.
	got, err := s.Screens(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, view := range got {
		if view.ID == renamed.ID {
			found = len(view.StatisticsColumns) == len(statisticsKeys("energy"))
		}
	}
	if !found {
		t.Fatal("saved layout not returned in authorized directory")
	}
}

func TestStatisticsColumnsRejectInvalidAndInvisibleModes(t *testing.T) {
	for _, kind := range []string{"hourly", "daily", "energy"} {
		t.Run(kind, func(t *testing.T) {
			columns := []DisplayColumn{}
			for _, key := range statisticsKeys(kind) {
				columns = append(columns, DisplayColumn{Key: key, Label: key, Visible: key == "date"})
			}
			if err := validateStatisticsColumns(columns, kind); err != nil {
				t.Fatal(err)
			}
			for _, change := range []func([]DisplayColumn){
				func(c []DisplayColumn) { c[1].Key = c[0].Key },
				func(c []DisplayColumn) { c[0].Label = "\n" },
				func(c []DisplayColumn) {
					for i := range c {
						c[i].Visible = false
					}
				},
				func(c []DisplayColumn) { c[0].Key = "unknown" },
			} {
				bad := append([]DisplayColumn(nil), columns...)
				change(bad)
				if validateStatisticsColumns(bad, kind) == nil {
					t.Fatal("invalid columns accepted", bad)
				}
			}
		})
	}
	c := []DisplayColumn{}
	for _, key := range statisticsKeys("energy") {
		c = append(c, DisplayColumn{Key: key, Label: key, Visible: key == "hour_usage"})
	}
	if validateStatisticsColumns(c, "energy") == nil {
		t.Fatal("daily mode would have no visible columns")
	}
	if validateStatisticsColumns(c, "alarm") == nil {
		t.Fatal("statistics config accepted for alarm")
	}
}

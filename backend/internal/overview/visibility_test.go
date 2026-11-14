package overview

import (
	"context"
	"encoding/json"
	"testing"
)

func TestDesktopVisibilityRoundTripKeepsMobileBindings(t *testing.T) {
	store := &memoryStore{}
	s := New(store)
	hidden, shown := false, true
	c := Config{Columns: []Column{
		{ID: "pressure", Group: "二次网", Name: "泵出口压力", DesktopVisible: &hidden},
		{ID: "current", Group: "循环泵", Name: "循1电流", DesktopVisible: &shown},
		{ID: "legacy", Group: "一次网", Name: "温度"},
	}, Rows: []Row{{ID: "r", Name: "站点", Station: "s", Bindings: map[string]string{"pressure": "p1", "current": "p2"}, Additional: &AdditionalRow{Columns: []string{"current"}, Bindings: map[string]string{"current": "p3"}}}}}
	points := map[string]bool{"p1": true, "p2": true, "p3": true}
	saved, err := s.Save(context.Background(), c, points, func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	got, err := New(store).Get(context.Background(), points)
	if err != nil || got.Revision != saved.Revision || *got.Columns[0].DesktopVisible || !*got.Columns[1].DesktopVisible || got.Columns[2].DesktopVisible != nil {
		t.Fatal(got, err)
	}
	if got.Rows[0].Bindings["pressure"] != "p1" || got.Rows[0].Additional.Bindings["current"] != "p3" {
		t.Fatal("display choice removed bindings")
	}
	got.Columns[0].DesktopVisible = &shown
	if _, err = s.Save(context.Background(), got, points, func(string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal([]byte(`{"desktop_visible":"false"}`), &Column{}); err == nil {
		t.Fatal("invalid display flag accepted")
	}
}

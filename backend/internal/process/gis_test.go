package process

import (
	"errors"
	"testing"
)

func TestGISCoordinatesPersistAndConflictWithoutChangingOtherScreens(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	d := document()
	d.Kind = "gis"
	d.Station = ""
	d.Nodes = []Node{}
	d.Assets = map[string]Asset{}
	d.GIS = &GISConfig{Stations: []GISStation{{ID: "s1", Name: "站一", Longitude: 122.9, Latitude: 39.7}}}
	d.GIS.Stations[0].Bindings = map[string]string{"primary_supply": "point-a", "supply_pressure": "point-b"}
	first, err := s.Save(d)
	if err != nil {
		t.Fatal(err)
	}
	other := d
	other.ID = "other"
	other.Station = ""
	if _, err = s.Save(other); err != nil {
		t.Fatal(err)
	}
	first.GIS.Stations[0].Longitude = 123.1
	updated, err := s.Save(first)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Save(first); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale save: %v", err)
	}
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := reopened.Get(d.ID)
	unchanged, _ := reopened.Get("other")
	if got.GIS.Stations[0].Longitude != 123.1 || got.Revision != updated.Revision || unchanged.GIS.Stations[0].Longitude != 122.9 {
		t.Fatal("GIS persistence/scope mismatch")
	}
	if got.GIS.Stations[0].Bindings["primary_supply"] != "point-a" || got.GIS.Stations[0].Bindings["supply_pressure"] != "point-b" {
		t.Fatal("GIS variable references lost on position save/reopen")
	}
	for _, rows := range [][]GISStation{
		{{ID: "bad", Name: "站", Longitude: 181, Latitude: 0}},
		{{ID: "bad", Name: "站", Longitude: 0, Latitude: 86}},
		{{ID: "same", Name: "站"}, {ID: "same", Name: "站"}},
		{{ID: "bad", Name: "站", Bindings: map[string]string{"unknown": "point-a"}}},
		{{ID: "bad", Name: "站", Bindings: map[string]string{"primary_supply": "invalid/id"}}},
	} {
		invalid := got
		invalid.GIS = &GISConfig{Stations: rows}
		if _, err := s.Save(invalid); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid GIS accepted: %v", err)
		}
	}
}

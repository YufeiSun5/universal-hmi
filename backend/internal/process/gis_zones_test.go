package process

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestGISZonesRoundTripAuthorizationAndValidation(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	d := document()
	d.Kind, d.Station = "gis", ""
	d.Nodes, d.Assets = []Node{}, map[string]Asset{}
	d.GIS = &GISConfig{Stations: []GISStation{{ID: "map", Name: "站", Longitude: 122, Latitude: 39,
		Bindings: map[string]string{"primary_supply": "common"},
		Zones: []GISZone{
			{ID: "z2", Name: "二区", Bindings: map[string]string{"supply_pressure": "denied"}},
			{ID: "z1", Name: "一区", Bindings: map[string]string{"secondary_supply": "allowed"}},
		}}}}
	lookup := func(id string) (string, bool) { return "owner", id != "denied" }
	if _, err := s.SaveAuthorizedPoints(d, lookup); !errors.Is(err, ErrInvalid) {
		t.Fatalf("denied zone binding accepted: %v", err)
	}
	first, err := s.SaveAuthorizedPoints(d, func(string) (string, bool) { return "owner", true })
	if err != nil {
		t.Fatal(err)
	}
	reopened, _ := Open(dir)
	got, err := reopened.Get(d.ID)
	if err != nil || got.GIS.Stations[0].Zones[0].ID != "z2" || got.GIS.Stations[0].Zones[1].Bindings["secondary_supply"] != "allowed" {
		t.Fatalf("zone order or reference lost: %+v %v", got.GIS, err)
	}
	ctx := authorization.WithActor(context.Background(), authorization.Actor{
		Grants: authorization.Grants{Roles: []string{"viewer"}, ScreenIDs: []string{d.ID}},
		Valid:  func() bool { return true }, StationID: func(s string) string { return s },
	})
	visible, err := reopened.VisibleDocument(ctx, d.ID, func(id string) bool { return id == "allowed" })
	if err != nil || len(visible.GIS.Stations[0].Bindings) != 0 || len(visible.GIS.Stations[0].Zones[0].Bindings) != 0 || visible.GIS.Stations[0].Zones[1].Bindings["secondary_supply"] != "allowed" {
		t.Fatalf("permission projection: %+v %v", visible.GIS, err)
	}
	unchanged, _ := reopened.Get(d.ID)
	if unchanged.GIS.Stations[0].Zones[0].Bindings["supply_pressure"] != "denied" {
		t.Fatal("projection mutated stored config")
	}
	first.GIS.Stations[0].Zones[0], first.GIS.Stations[0].Zones[1] = first.GIS.Stations[0].Zones[1], first.GIS.Stations[0].Zones[0]
	if _, err := reopened.Save(first); err != nil {
		t.Fatal(err)
	}
	if _, err := reopened.Save(first); !errors.Is(err, ErrConflict) {
		t.Fatal("stale reorder accepted")
	}
	for _, zones := range [][]GISZone{
		{{ID: "x", Name: "区"}, {ID: "x", Name: "重复"}},
		{{ID: "x", Name: " "}},
		{{ID: "x", Name: "区", Bindings: map[string]string{"unknown": "allowed"}}},
		{{ID: "x", Name: "区", Bindings: map[string]string{"primary_supply": "bad/id"}}},
		make([]GISZone, 17),
	} {
		d.GIS.Stations[0].Zones = zones
		if err := Validate(d); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid zones accepted: %v", err)
		}
	}
	// Old documents need neither a migration nor synthetic zone entries.
	d.GIS.Stations[0].Zones = nil
	data, _ := json.Marshal(d)
	var legacy Document
	if err := json.Unmarshal(data, &legacy); err != nil || len(legacy.GIS.Stations[0].Zones) != 0 || legacy.GIS.Stations[0].Bindings["primary_supply"] != "common" {
		t.Fatalf("legacy document changed: %v", err)
	}
}

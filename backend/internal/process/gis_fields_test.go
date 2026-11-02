package process

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

func TestGISInformationListsPersistAndRespectAuthorization(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	d := document()
	d.Kind = "gis"
	d.Station = ""
	d.Nodes = []Node{}
	d.Assets = map[string]Asset{}
	fields := []GISField{{ID: "flow", Name: "补水流量"}, {ID: "level", Name: "水箱水位"}}
	empty := []GISField{}
	d.GIS = &GISConfig{Stations: []GISStation{{ID: "map", Name: "站", Longitude: 122, Latitude: 39, Fields: &fields, Bindings: map[string]string{"flow": "allowed", "level": "denied"}, Zones: []GISZone{{ID: "zone", Name: "空分区", Fields: &empty}}}}}
	if _, err := s.SaveAuthorizedPoints(d, func(id string) (string, bool) { return "owner", id == "allowed" }); !errors.Is(err, ErrInvalid) {
		t.Fatalf("unauthorized field accepted: %v", err)
	}
	saved, err := s.SaveAuthorizedPoints(d, func(string) (string, bool) { return "owner", true })
	if err != nil {
		t.Fatal(err)
	}
	reopened, _ := Open(dir)
	got, err := reopened.Get(d.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.GIS.Stations[0].Fields == nil || (*got.GIS.Stations[0].Fields)[1].Name != "水箱水位" || got.GIS.Stations[0].Zones[0].Fields == nil || len(*got.GIS.Stations[0].Zones[0].Fields) != 0 {
		t.Fatal("fields or explicit empty list lost")
	}
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, ScreenIDs: []string{d.ID}}, Valid: func() bool { return true }, StationID: func(s string) string { return s }})
	view, err := reopened.VisibleDocument(ctx, d.ID, func(id string) bool { return id == "allowed" })
	if err != nil || view.GIS.Stations[0].Bindings["level"] != "" || view.GIS.Stations[0].Bindings["flow"] != "allowed" {
		t.Fatalf("field permission projection failed: %v", err)
	}
	saved.GIS.Stations[0].Fields = &empty
	saved.GIS.Stations[0].Bindings = nil
	if _, err = reopened.Save(saved); err != nil {
		t.Fatal(err)
	}
	got, _ = reopened.Get(d.ID)
	bytes, _ := json.Marshal(got)
	var round Document
	if err = json.Unmarshal(bytes, &round); err != nil || round.GIS.Stations[0].Fields == nil || len(*round.GIS.Stations[0].Fields) != 0 {
		t.Fatal("deleted fields returned as legacy defaults")
	}
	for _, bad := range [][]GISField{{{ID: "x", Name: ""}}, {{ID: "x", Name: "a"}, {ID: "x", Name: "b"}}, {{ID: "bad/id", Name: "a"}}, make([]GISField, 33)} {
		d.GIS.Stations[0].Fields = &bad
		d.GIS.Stations[0].Bindings = nil
		if err := Validate(d); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid list accepted: %v", err)
		}
	}
	d.GIS.Stations[0].Fields = &empty
	d.GIS.Stations[0].Bindings = map[string]string{"flow": "allowed"}
	if err := Validate(d); !errors.Is(err, ErrInvalid) {
		t.Fatal("orphan binding accepted")
	}
}

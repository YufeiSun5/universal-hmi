package overview

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func additionalFixture() Config {
	return Config{Columns: []Column{
		{ID: "tank", Name: "水箱水位", Group: "补水水箱", Decimals: 1},
		{ID: "temp", Name: "供温", Group: "二次网", Decimals: 1},
	}, Rows: []Row{{ID: "zone", Name: "站", Area: "高区", Station: "A",
		Bindings:   map[string]string{"tank": "first", "temp": "temperature"},
		Additional: &AdditionalRow{Columns: []string{"tank", "temp"}, Bindings: map[string]string{"tank": "second"}},
	}}}
}

func TestAdditionalRoundTripOldCompatibilityAndScope(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	svc := New(store)
	points := map[string]bool{"first": true, "second": true, "temperature": true}
	station := func(string) error { return nil }
	c := additionalFixture()
	c.Rows[0].Additional = nil
	old, err := svc.Save(ctx, c, points, station)
	if err != nil || strings.Contains(string(store.raw), "additional") {
		t.Fatalf("old configuration changed: %s %v", store.raw, err)
	}
	c = additionalFixture()
	c.Revision = old.Revision
	saved, err := svc.Save(ctx, c, points, station)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := New(store).Get(ctx, points)
	if err != nil || loaded.Rows[0].Bindings["tank"] != "first" || loaded.Rows[0].Additional.Bindings["tank"] != "second" || loaded.Rows[0].Additional.Bindings["temp"] != "" {
		t.Fatal(loaded, err)
	}
	valid := true
	viewer := authorization.WithActor(ctx, authorization.Actor{
		Grants:    authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}},
		StationID: func(s string) string { return s }, Valid: func() bool { return valid },
	})
	filtered, err := svc.Get(viewer, map[string]bool{"first": true})
	if err != nil || len(filtered.Rows) != 1 || len(filtered.Rows[0].Bindings) != 1 || len(filtered.Rows[0].Additional.Bindings) != 0 || len(filtered.Rows[0].Additional.Columns) != 2 {
		t.Fatal(filtered, err)
	}
	if _, err = svc.Save(viewer, saved, points, station); err == nil {
		t.Fatal("viewer wrote additional bindings")
	}
	valid = false
	if _, err = svc.Get(viewer, points); err == nil {
		t.Fatal("revoked viewer read configuration")
	}
	// Filtering is a projection; it must not erase the persisted second reading.
	loaded, _ = svc.Get(ctx, points)
	if loaded.Rows[0].Additional.Bindings["tank"] != "second" {
		t.Fatal("scope filtering changed saved data")
	}
	loaded.Rows[0].Additional = &AdditionalRow{Columns: []string{"tank"}}
	if _, err := svc.Save(ctx, loaded, points, station); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(store.raw), `"bindings":null`) {
		t.Fatal("unbound second equipment cannot round trip as an object")
	}
}

func TestAdditionalValidationRejectsInvalidReferencesWithoutSaving(t *testing.T) {
	points := map[string]bool{"first": true, "second": true, "temperature": true}
	station := func(string) error { return nil }
	cases := map[string]*AdditionalRow{
		"duplicate":          {Columns: []string{"tank", "tank"}},
		"unknown column":     {Columns: []string{"missing"}},
		"unselected binding": {Columns: []string{"tank"}, Bindings: map[string]string{"temp": "second"}},
		"missing point":      {Columns: []string{"tank"}, Bindings: map[string]string{"tank": "unknown"}},
		"empty reference":    {Columns: []string{"tank"}, Bindings: map[string]string{"tank": ""}},
	}
	for name, additional := range cases {
		t.Run(name, func(t *testing.T) {
			store := &memoryStore{}
			svc := New(store)
			c := additionalFixture()
			saved, err := svc.Save(context.Background(), c, points, station)
			if err != nil {
				t.Fatal(err)
			}
			before := string(store.raw)
			saved.Rows[0].Additional = additional
			if _, err = svc.Save(context.Background(), saved, points, station); err == nil || string(store.raw) != before {
				t.Fatalf("invalid save changed config: %v", err)
			}
		})
	}
	// The bound includes physical rows, so a single split cannot double an
	// already-full matrix past the existing rendering limit.
	c := Config{}
	for i := 0; i < 64; i++ {
		c.Columns = append(c.Columns, Column{ID: fmt.Sprintf("c%d", i), Name: "值", Group: "组"})
	}
	for i := 0; i < 128; i++ {
		c.Rows = append(c.Rows, Row{ID: fmt.Sprintf("r%d", i), Name: "站", Station: "A"})
	}
	if err := Validate(c, points, station); err != nil {
		t.Fatal(err)
	}
	c.Rows[0].Additional = &AdditionalRow{Columns: []string{"c0"}}
	if err := Validate(c, points, station); err == nil {
		t.Fatal("additional row bypassed cell bound")
	}
	// Missing optional fields from old JSON continue to decode as one row.
	var old Row
	if err := json.Unmarshal([]byte(`{"id":"old","name":"站","station":"A","bindings":{}}`), &old); err != nil || old.Additional != nil {
		t.Fatal(old, err)
	}
}

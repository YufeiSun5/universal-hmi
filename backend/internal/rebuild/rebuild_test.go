package rebuild

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func setup(t *testing.T) *storage.Store {
	t.Helper()
	s, e := storage.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	_, e = persistence.NewDocuments(s.DB)
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func seed(t *testing.T, s *storage.Store) {
	t.Helper()
	docs, _ := persistence.NewDocuments(s.DB)
	for k, v := range map[string]any{"sources": []any{map[string]any{"id": "mqtt-original", "broker": "tcp://test-only:1883", "topic": "test/#"}}, "station_directory": []string{"old"}, "rules": []any{map[string]any{"id": "rule-old", "conditions": []any{map[string]any{"point_id": "old-point"}}}}, "policy": map[string]any{"enabled": true, "point_ids": []string{"old-point"}, "interval_ms": 1000}, "station_policies": map[string]any{"old": map[string]any{"enabled": true}}, "equipment_register": []any{map[string]any{"id": "asset", "revision": 3, "station": "old", "name": "asset remains", "photos": []string{"photo"}, "signals": map[string]any{"fault": map[string]any{"point_id": "old-point", "expression": "v > 1"}}}}, "page_navigation": map[string]any{"revision": 1, "nodes": []any{map[string]any{"id": "nav", "screen_id": "old-screen"}}}, "external_sources": map[string]any{"ciphertext": "keep"}} {
		if e := s.SaveConfig(k, v); e != nil {
			t.Fatal(e)
		}
	}
	if e := docs.Save("points", "definitions", encode([]any{map[string]any{"id": "old-point", "station": "old", "name": "old"}})); e != nil {
		t.Fatal(e)
	}
	for id, v := range map[string]any{"old-screen": map[string]any{"id": "old-screen", "revision": 1, "kind": "", "station": "old"}, "gis": map[string]any{"id": "gis", "revision": 4, "kind": "gis", "station": "", "background": map[string]any{"type": "solid", "color": "#123456"}, "nodes": []any{map[string]any{"id": "layout", "x": 12.25}}, "assets": map[string]any{"a": "unchanged"}, "gis": map[string]any{"stations": []any{map[string]any{"id": "marker", "name": "old", "longitude": 122.5, "latitude": 39.5, "bindings": map[string]string{"primary_supply": "old-point"}, "zones": []any{map[string]any{"id": "zone", "name": "一区", "bindings": map[string]string{"supply_pressure": "old-point"}}}, "target_screen_id": "old-screen"}}}}} {
		if e := docs.Save("screens", id, encode(v)); e != nil {
			t.Fatal(e)
		}
	}
	_, e := s.DB.Exec("INSERT INTO samples(point_id,station,name,value,raw,unit,quality,source_time,received_time,version) VALUES('old-point','old','old','1','1','','good',1,1,'old')")
	if e != nil {
		t.Fatal(e)
	}
}
func snapshot(t *testing.T, s *storage.Store) storage.ConfigurationSnapshot {
	t.Helper()
	var out storage.ConfigurationSnapshot
	if e := s.MaintainConfiguration(context.Background(), false, func(v *storage.ConfigurationSnapshot) error { out = *v; return nil }); e != nil {
		t.Fatal(e)
	}
	return out
}
func TestRebuildAtomicOncePreservesSourcesHistoryGISAssets(t *testing.T) {
	s := setup(t)
	seed(t, s)
	before := snapshot(t, s)
	// Deliberate source whitespace proves unrelated bytes do not get reserialized.
	original := ` [ { "id" : "mqtt-original", "topic" : "test/#" } ] `
	if _, e := s.DB.Exec("UPDATE config SET value=? WHERE key='sources'", original); e != nil {
		t.Fatal(e)
	}
	plan, e := Run(context.Background(), s, "plan", "manifest-hash", "")
	if e != nil || plan.Status != "ready" {
		t.Fatalf("%v %+v", e, plan)
	}
	if len(snapshot(t, s).Documents["screens"]) != 2 {
		t.Fatal("plan mutated")
	}
	if _, e = Run(context.Background(), s, "commit", "manifest-hash", "stale"); e == nil {
		t.Fatal("stale plan accepted")
	}
	if _, ok := snapshot(t, s).Config[markerKey]; ok {
		t.Fatal("failed transaction marker")
	}
	result, e := Run(context.Background(), s, "commit", "manifest-hash", plan.PreviewToken)
	if e != nil || result.Status != "applied" {
		t.Fatalf("%v %+v", e, result)
	}
	after := snapshot(t, s)
	if string(after.Config["sources"]) != original {
		t.Fatal("MQTT bytes changed")
	}
	if string(after.Documents["points"]["definitions"]) != "[]" || len(after.Documents["screens"]) != 1 {
		t.Fatal("old configuration retained")
	}
	var oldGIS, newGIS map[string]any
	json.Unmarshal(before.Documents["screens"]["gis"], &oldGIS)
	json.Unmarshal(after.Documents["screens"]["gis"], &newGIS)
	for _, key := range []string{"nodes", "assets", "background", "station"} {
		if !reflect.DeepEqual(oldGIS[key], newGIS[key]) {
			t.Fatal("GIS layout changed", key)
		}
	}
	if !reflect.DeepEqual(before.Config["external_sources"], after.Config["external_sources"]) {
		t.Fatal("external connection changed")
	}
	zones := newGIS["gis"].(map[string]any)["stations"].([]any)[0].(map[string]any)["zones"].([]any)
	if len(zones) != 1 || zones[0].(map[string]any)["name"] != "一区" || len(zones[0].(map[string]any)["bindings"].(map[string]any)) != 0 {
		t.Fatal("zone layout lost or deleted reference retained")
	}
	var devices []map[string]any
	json.Unmarshal(after.Config["equipment_register"], &devices)
	if devices[0]["name"] != "asset remains" || len(devices[0]["signals"].(map[string]any)) != 0 {
		t.Fatal("asset loss or dangling signal")
	}
	var count int
	if e = s.DB.QueryRow("SELECT count(*) FROM samples").Scan(&count); e != nil || count != 1 {
		t.Fatal("history changed")
	}
	// Subsequent scanned variable must survive repeat launch.
	docs, _ := persistence.NewDocuments(s.DB)
	if e = docs.Save("points", "definitions", encode([]any{map[string]any{"id": "new-scanned"}})); e != nil {
		t.Fatal(e)
	}
	repeat, e := Run(context.Background(), s, "commit", "", "bad-old-token")
	if e != nil || repeat.Status != "already_applied" {
		t.Fatalf("%v %+v", e, repeat)
	}
	if string(snapshot(t, s).Documents["points"]["definitions"]) == "[]" {
		t.Fatal("repeat erased newly scanned variables")
	}
}
func TestMaintenanceRollbackAndMalformedConfiguration(t *testing.T) {
	s := setup(t)
	seed(t, s)
	before := snapshot(t, s)
	e := s.MaintainConfiguration(context.Background(), true, func(v *storage.ConfigurationSnapshot) error {
		v.Config["sources"] = encode("changed")
		delete(v.Documents["screens"], "gis")
		return errors.New("injected failure")
	})
	if e == nil || !reflect.DeepEqual(before, snapshot(t, s)) {
		t.Fatal("failed maintenance changed original")
	}
	s.SaveConfig("equipment_register", "invalid-object")
	broken := snapshot(t, s)
	if _, e = Run(context.Background(), s, "plan", "manifest", ""); e == nil {
		t.Fatal("malformed configuration accepted")
	}
	if !reflect.DeepEqual(broken, snapshot(t, s)) {
		t.Fatal("invalid plan wrote data")
	}
	_ = filepath.Separator
}

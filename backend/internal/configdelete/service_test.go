package configdelete

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func setup(t *testing.T) (*Service, *persistence.Documents) {
	t.Helper()
	dir := t.TempDir()
	db, e := storage.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	docs, e := persistence.NewDocuments(db.DB)
	if e != nil {
		t.Fatal(e)
	}
	ps, e := points.OpenDocuments(filepath.Join(dir, "points.json"), docs)
	if e != nil {
		t.Fatal(e)
	}
	stationService := stations.New(db, func() ([]string, error) {
		var deleted []string
		db.LoadConfig("station_directory_deleted", &deleted)
		names := []string{"history-only", "other-history"}
		out := []string{}
		for _, name := range names {
			keep := true
			for _, d := range deleted {
				if d == name {
					keep = false
				}
			}
			if keep {
				out = append(out, name)
			}
		}
		return out, nil
	})
	return &Service{Points: ps, Store: db, Stations: stationService}, docs
}
func variable(t *testing.T, s *Service, name string) points.Definition {
	t.Helper()
	p, e := s.Points.Create(points.CreateInput{Name: name, Station: "owner", DataType: "FLOAT", SourceType: "manual"})
	if e != nil {
		t.Fatal(e)
	}
	return p
}
func TestAtomicBatchDeleteRevisionReferencesAndRepeat(t *testing.T) {
	s, _ := setup(t)
	a, b := variable(t, s, "a"), variable(t, s, "b")
	r := Request{Targets: []Target{{ID: a.ID, Revision: points.Revision(a)}, {ID: b.ID, Revision: points.Revision(b)}}}
	plan, e := s.Run(context.Background(), r, false, false)
	if e != nil || !plan.CanCommit {
		t.Fatalf("%v %+v", e, plan)
	}
	r.PreviewToken = plan.PreviewToken
	// New reference after preview rejects the entire batch, including unrelated b.
	s.Store.SaveConfig("rules", []any{map[string]any{"id": "rule", "conditions": []any{map[string]any{"point_id": a.ID}}}})
	blocked, e := s.Run(context.Background(), r, false, true)
	if e != ErrConflict || len(s.Points.List()) != 2 || blocked.Items[0].Status != "blocked" {
		t.Fatalf("%v %+v", e, blocked)
	}
	s.Store.SaveConfig("rules", []any{})
	plan, e = s.Run(context.Background(), r, false, false)
	if e != nil {
		t.Fatal(e)
	}
	r.PreviewToken = plan.PreviewToken
	result, e := s.Run(context.Background(), r, false, true)
	if e != nil || len(result.Deleted) != 2 || len(s.Points.List()) != 0 {
		t.Fatalf("%v %+v", e, result)
	}
	if _, e = s.Run(context.Background(), r, false, true); e != ErrConflict {
		t.Fatal("missing repeat identities accepted")
	}
}
func TestBatchDeleteVirtualInputsAndAllReferenceKinds(t *testing.T) {
	for _, kind := range []string{"virtual", "screen", "gis", "gis_zone", "equipment_register", "rules", "policy", "station_policies"} {
		t.Run(kind, func(t *testing.T) {
			s, docs := setup(t)
			p := variable(t, s, "x")
			r := Request{Targets: []Target{{ID: p.ID, Revision: points.Revision(p)}}}
			var value any
			switch kind {
			case "virtual":
				_, e := s.Points.Create(points.CreateInput{Name: "derived", Station: "elsewhere", SourceType: "virtual", DataType: "FLOAT", Inputs: []string{p.ID}, Expression: "v[0]"})
				if e != nil {
					t.Fatal(e)
				}
			case "screen":
				b, _ := json.Marshal(map[string]any{"bindings": map[string]any{"node": map[string]any{"visible": map[string]any{"conditions": []any{map[string]any{"point_id": p.ID}}}}}})
				docs.Save("screens", "instance", b)
			case "gis":
				b, _ := json.Marshal(map[string]any{"gis": map[string]any{"stations": []any{map[string]any{"bindings": map[string]string{"supply": p.ID}}}}})
				docs.Save("screens", "gis", b)
			case "gis_zone":
				b, _ := json.Marshal(map[string]any{"gis": map[string]any{"stations": []any{map[string]any{"zones": []any{map[string]any{"id": "zone", "bindings": map[string]string{"supply_pressure": p.ID}}}}}}})
				docs.Save("screens", "gis", b)
			case "equipment_register":
				value = []any{map[string]any{"id": "asset", "signals": map[string]any{"running": map[string]any{"point_id": p.ID}}}}
			case "rules":
				value = []any{map[string]any{"id": "rule", "actions": []any{map[string]any{"point_id": p.ID}}}}
			case "policy":
				value = map[string]any{"point_ids": []string{p.ID}}
			case "station_policies":
				value = map[string]any{"owner": map[string]any{"point_ids": []string{p.ID}}}
			}
			if value != nil {
				s.Store.SaveConfig(kind, value)
			}
			plan, e := s.Run(context.Background(), r, false, false)
			if e != nil || plan.CanCommit || len(plan.Items[0].References) == 0 {
				t.Fatalf("%v %+v", e, plan)
			}
		})
	}
}
func TestStationDeleteHistoryTombstoneAndRecreate(t *testing.T) {
	s, docs := setup(t)
	s.Stations.Create("empty")
	r := Request{Targets: []Target{{Name: "history-only"}, {Name: "empty"}}}
	plan, e := s.Run(context.Background(), r, true, false)
	if e != nil || !plan.CanCommit {
		t.Fatalf("%v %+v", e, plan)
	}
	r.PreviewToken = plan.PreviewToken
	out, e := s.Run(context.Background(), r, true, true)
	if e != nil || len(out.Deleted) != 2 {
		t.Fatalf("%v %+v", e, out)
	}
	all, e := s.Stations.List()
	if e != nil || len(all) != 1 || all[0].Name != "other-history" {
		t.Fatalf("unrelated history station hidden %+v %v", all, e)
	}
	if _, e = s.Stations.Create("history-only"); e != nil {
		t.Fatal("same-name station not recoverable", e)
	}
	// GIS marker business target is an explicit blocker even when directory is empty.
	b, _ := json.Marshal(map[string]any{"kind": "gis", "gis": map[string]any{"stations": []any{map[string]any{"id": "marker", "name": "history-only", "target_screen_id": "target"}}}})
	docs.Save("screens", "gis", b)
	r = Request{Targets: []Target{{Name: "history-only"}}}
	plan, e = s.Run(context.Background(), r, true, false)
	if e != nil || plan.CanCommit || len(plan.Items[0].References) == 0 {
		t.Fatalf("GIS target not protected %v %+v", e, plan)
	}
}
func TestDeletePermissionDuplicateAndRevision(t *testing.T) {
	s, _ := setup(t)
	p := variable(t, s, "x")
	r := Request{Targets: []Target{{ID: p.ID, Revision: "stale"}}}
	plan, e := s.Run(context.Background(), r, false, false)
	if e != nil || plan.CanCommit || plan.Items[0].Status != "conflict" {
		t.Fatalf("%v %+v", e, plan)
	}
	r.Targets = append(r.Targets, r.Targets[0])
	if _, e = s.Run(context.Background(), r, false, false); e == nil {
		t.Fatal("duplicate accepted")
	}
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return true }})
	if _, e = s.Run(ctx, r, false, false); e != authorization.ErrDenied {
		t.Fatal("permission bypass")
	}
}

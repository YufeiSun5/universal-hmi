package ownership

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func fixture(t *testing.T) (*Service, *storage.Store, *persistence.Documents) {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	docs, err := persistence.NewDocuments(db.DB)
	if err != nil {
		t.Fatal(err)
	}
	ps, err := points.OpenDocuments(filepath.Join(dir, "points.json"), docs)
	if err != nil {
		t.Fatal(err)
	}
	screens, err := process.OpenDocuments(filepath.Join(dir, "screens"), docs)
	if err != nil {
		t.Fatal(err)
	}
	st := stations.New(db, nil)
	for _, name := range []string{"IO-01", "A", "B", "Shared"} {
		if _, err = st.Create(name); err != nil {
			t.Fatal(err)
		}
	}
	return &Service{Points: ps, Screens: screens, Stations: st, Store: db}, db, docs
}
func variable(t *testing.T, s *Service, name string) points.Definition {
	t.Helper()
	p, err := s.Points.Create(points.CreateInput{Station: "IO-01", Name: name, SourceType: "manual", DataType: "FLOAT", StaleMS: 60000})
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func screen(t *testing.T, s *Service, id, station string, ids ...string) {
	t.Helper()
	d := process.Document{SchemaVersion: 1, ID: id, Name: id, Station: station, Width: 1000, Height: 600, Assets: map[string]process.Asset{}, Nodes: []process.Node{}}
	for i, id := range ids {
		n := process.Node{ID: "n" + id, Kind: "value", X: float64(i * 100), Y: 10, Width: 100, Height: 40, Color: "#000000", Fill: "none", FontSize: 20, StrokeWidth: 2, PointID: id}
		d.Nodes = append(d.Nodes, n)
	}
	_, err := s.Screens.SaveAuthorizedPoints(d, func(id string) (string, bool) { return "IO-01", true })
	if err != nil {
		t.Fatal(err)
	}
}
func selected(p points.Definition, station string) Request {
	return Request{Targets: []points.StationTarget{{ID: p.ID, Revision: points.Revision(p), Station: station}}}
}
func plan(t *testing.T, s *Service, r Request) Result {
	t.Helper()
	out, err := s.Run(context.Background(), r, false)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestOwnershipSuggestionsSharedUnreferencedAndArrow(t *testing.T) {
	s, _, _ := fixture(t)
	a := variable(t, s, "single")
	b := variable(t, s, "shared")
	c := variable(t, s, "unreferenced")
	screen(t, s, "a", "A", a.ID, b.ID)
	screen(t, s, "b", "B", b.ID)
	d, err := s.Screens.Get("b")
	if err != nil {
		t.Fatal(err)
	}
	d.Nodes[0].PointID = ""
	d.Nodes[0].Kind = "pipe"
	d.Nodes[0].Points = []process.Position{{X: 10, Y: 10}, {X: 200, Y: 10}}
	zero := 0.0
	d.Nodes[0].ArrowVisibleRule = &process.ArrowRule{Match: "all", Conditions: []process.ArrowCondition{{Slot: "fixture", PointID: b.ID, Operator: ">", Value: &zero}}}
	if _, err = s.Screens.SaveAuthorizedPoints(d, func(string) (string, bool) { return "IO-01", true }); err != nil {
		t.Fatal(err)
	}
	out := plan(t, s, Request{})
	if out.CanCommit || out.Counts["single"] != 1 || out.Counts["shared"] != 1 || out.Counts["unreferenced"] != 1 {
		t.Fatalf("%+v", out)
	}
	for _, it := range out.Items {
		switch it.ID {
		case a.ID:
			if it.SuggestedStation != "A" {
				t.Fatal(it)
			}
		case b.ID:
			if it.SuggestedStation != "" || len(it.ScreenStations) != 2 {
				t.Fatal(it)
			}
		case c.ID:
			if it.TargetStation != "IO-01" {
				t.Fatal(it)
			}
		}
	}
}

func TestOwnershipAtomicBackupPreservesLiveHistoryBindingsAndRollback(t *testing.T) {
	s, db, docs := fixture(t)
	p := variable(t, s, "temperature")
	screen(t, s, "a", "A", p.ID)
	engine, err := rt.New(s.Points, db)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	if _, err := engine.Apply(); err != nil {
		t.Fatal(err)
	}
	if err := engine.Manual(p.ID, 42.5); err != nil {
		t.Fatal(err)
	}
	sample := storage.Sample{PointID: p.ID, Station: "IO-01", Name: p.Name, Value: 42.5, Quality: "good", SourceTime: time.Now(), Version: "old"}
	if err := db.Append(context.Background(), []storage.Sample{sample}); err != nil {
		t.Fatal(err)
	}
	liveBefore, _ := json.Marshal(engine.Snapshot())
	docBefore, _ := docs.Load("screens", "a")
	r := selected(p, "A")
	preview := plan(t, s, r)
	if !preview.CanCommit {
		t.Fatal(preview)
	}
	r.PreviewToken = preview.PreviewToken
	out, err := s.Run(context.Background(), r, true)
	if err != nil || !out.Saved || out.Applied || out.Backup == nil {
		t.Fatal(out, err)
	}
	after := s.Points.List()[0]
	expected := p
	expected.Station = "A"
	if !reflect.DeepEqual(after, expected) {
		t.Fatal(after, expected)
	}
	liveAfter, _ := json.Marshal(engine.Snapshot())
	if string(liveBefore) != string(liveAfter) {
		t.Fatal("commit changed runtime")
	}
	docAfter, _ := docs.Load("screens", "a")
	if string(docBefore) != string(docAfter) {
		t.Fatal("changed binding")
	}
	rows, err := db.Query(context.Background(), storage.Filter{PointID: p.ID, Limit: 100})
	if err != nil || len(rows) != 1 || rows[0].Station != "IO-01" {
		t.Fatal(rows, err)
	}
	raw, err := docs.Load("ownership_backups", out.Backup.ID)
	if err != nil || len(raw) == 0 {
		t.Fatal(err)
	}
	if _, err = s.Run(context.Background(), r, true); err == nil {
		t.Fatal("stale repeat accepted")
	}
	rollback := Request{Targets: out.Backup.RollbackTargets}
	back := plan(t, s, rollback)
	rollback.PreviewToken = back.PreviewToken
	if _, err = s.Run(context.Background(), rollback, true); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(s.Points.List()[0], p) {
		t.Fatal("rollback differs")
	}
	again := selected(p, "A")
	again.PreviewToken = plan(t, s, again).PreviewToken
	second, err := s.Run(context.Background(), again, true)
	if err != nil || second.Backup.ID == out.Backup.ID {
		t.Fatal("move rollback move recovery collision", err)
	}
}

func TestOwnershipBlocksDependenciesAndStalePlans(t *testing.T) {
	for _, test := range []struct {
		name, key string
		value     func(string) any
		code      string
	}{
		{"explicit", "station_policies", func(id string) any {
			return map[string]any{"IO-01": map[string]any{"enabled": false, "point_ids": []string{id}}}
		}, "station-storage-policy"},
		{"whole-source", "station_policies", func(string) any {
			return map[string]any{"IO-01": map[string]any{"enabled": true, "point_ids": []string{}}}
		}, "enabled-whole-station-storage-policy"},
		{"whole-target", "station_policies", func(string) any { return map[string]any{"A": map[string]any{"enabled": true}} }, "enabled-whole-station-storage-policy"},
		{"rule", "rules", func(id string) any {
			return []any{map[string]any{"station": "IO-01", "conditions": []any{map[string]any{"point_id": id}}}}
		}, "scoped-automation-rule"},
	} {
		t.Run(test.name, func(t *testing.T) {
			s, db, _ := fixture(t)
			p := variable(t, s, "p")
			db.SaveConfig(test.key, test.value(p.ID))
			r := selected(p, "A")
			out := plan(t, s, r)
			if out.CanCommit || out.Items[0].Status != "blocked" || !containsString(out.Items[0].Blockers, test.code) {
				t.Fatal(out)
			}
			r.PreviewToken = out.PreviewToken
			if _, err := s.Run(context.Background(), r, true); err == nil {
				t.Fatal("blocked commit")
			}
			if s.Points.List()[0].Station != "IO-01" {
				t.Fatal("partial write")
			}
		})
	}
	s, db, _ := fixture(t)
	p := variable(t, s, "p")
	r := selected(p, "A")
	out := plan(t, s, r)
	r.PreviewToken = out.PreviewToken
	db.SaveConfig("rules", []any{map[string]any{"name": "changed"}})
	if _, err := s.Run(context.Background(), r, true); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
}
func containsString(rows []string, want string) bool {
	for _, v := range rows {
		if v == want {
			return true
		}
	}
	return false
}

func TestOwnershipPermissionCollisionAndRecoveryFailure(t *testing.T) {
	s, _, docs := fixture(t)
	p := variable(t, s, "same")
	q := variable(t, s, "other")
	screen(t, s, "a", "A", p.ID)
	actor := authorization.Actor{Valid: func() bool { return true }, StationID: func(n string) string { return n }, Grants: authorization.Grants{Roles: []string{"engineer"}, StationIDs: []string{"A"}}}
	ctx := authorization.WithActor(context.Background(), actor)
	out, err := s.Run(ctx, Request{}, false)
	if !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(out, err)
	}
	if _, err = s.Run(ctx, selected(p, "A"), false); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	r := selected(p, "A")
	out = plan(t, s, r)
	r.PreviewToken = out.PreviewToken
	// A persistence trigger failing the recovery insert must roll back all writes.
	if _, err = docs.DB.Exec("CREATE TRIGGER fail_recovery BEFORE INSERT ON documents WHEN NEW.kind='ownership_backups' BEGIN SELECT RAISE(ABORT, 'fixture recovery failure'); END"); err != nil {
		t.Fatal(err)
	}
	before := s.Points.List()
	if _, err = s.Run(context.Background(), r, true); err == nil {
		t.Fatal("recovery overwrite")
	}
	if !reflect.DeepEqual(before, s.Points.List()) {
		t.Fatal("memory changed on recovery failure")
	}
	reopened, err := points.OpenDocuments("", docs)
	if err != nil || !reflect.DeepEqual(before, reopened.List()) {
		t.Fatal("durable partial write", err)
	}
	if _, err = docs.DB.Exec("DROP TRIGGER fail_recovery"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Run(context.Background(), r, true); err != nil {
		t.Fatal("same-plan retry after backup failure", err)
	}
	back := s.Points.List()[0]
	if back.ID != p.ID {
		back = s.Points.List()[1]
	}
	p = back
	input := points.CreateInput{Station: "B", Name: p.Name, SourceType: "manual", DataType: "FLOAT"}
	if _, err = s.Points.Update(q.ID, input); err != nil {
		t.Fatal(err)
	}
	out = plan(t, s, selected(p, "B"))
	if out.CanCommit || !containsString(out.Items[0].Blockers, "target-name-collision") && !containsString(out.Items[1].Blockers, "target-name-collision") {
		t.Fatal(out)
	}
}

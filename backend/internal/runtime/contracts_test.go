package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestStationPoliciesSnapshotsAndRulesDoNotLeak(t *testing.T) {
	e, ps := setup(t)
	a, _ := ps.Create(points.CreateInput{Station: "A", Name: "input", DataType: "FLOAT", SourceType: "manual", Writable: true})
	b, _ := ps.Create(points.CreateInput{Station: "B", Name: "input", DataType: "FLOAT", SourceType: "manual", Writable: true})
	e.Apply()
	e.Manual(a.ID, 1.0)
	e.Manual(b.ID, 2.0)
	p := Policy{Enabled: false, IntervalMS: 200, RetentionDays: 7, PointIDs: []string{a.ID}}
	if err := e.SetPolicy("A", p); err != nil {
		t.Fatal(err)
	}
	if e.StoragePolicy("").RetentionDays != 30 || e.StoragePolicy("B").RetentionDays != 30 {
		t.Fatal("station policy changed global/another station")
	}
	if err := e.SetPolicy("B", p); err == nil {
		t.Fatal("cross station storage point accepted")
	}
	if err := e.SnapshotStation("A"); err != nil {
		t.Fatal(err)
	}
	rows, err := e.Store.Query(context.Background(), storage.Filter{})
	if err != nil || len(rows) != 1 || rows[0].PointID != a.ID {
		t.Fatalf("snapshot scope: %+v %v", rows, err)
	}
	rule := Rule{ID: "station-rule", Name: "station", Station: "A", Logic: "and", Conditions: []Condition{{a.ID, ">", 0}}, CooldownMS: 200, Trigger: "rising", Actions: []Action{{"write", b.ID, 5}}}
	if err := e.SetRules([]Rule{rule}); err == nil {
		t.Fatal("cross station action accepted")
	}
	rule.Actions = []Action{{"snapshot", "", 0}, {"storage_start", "", 0}}
	rule.Enabled = true
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	e.evaluate(time.Now())
	e.mu.Unlock()
	if !e.StoragePolicy("A").Enabled || e.StoragePolicy("").Enabled || e.StoragePolicy("B").Enabled {
		t.Fatal("rule storage action escaped station")
	}
	// Moving a definition invalidates old scoped references without moving history.
	_, err = ps.Update(a.ID, points.CreateInput{Station: "B", Name: "moved", DataType: "FLOAT", SourceType: "manual", Writable: true})
	if err != nil {
		t.Fatal(err)
	}
	e.Apply()
	e.Manual(a.ID, 3.0)
	preview := e.Preview(rule)
	if preview["known"] != false {
		t.Fatal("moved rule input leaked into former station")
	}
	if err := e.SnapshotStation("A"); err != nil {
		t.Fatal(err)
	}
	rows, err = e.Store.Query(context.Background(), storage.Filter{Station: "A"})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Value != 1.0 {
			t.Fatalf("moved value leaked %+v", r)
		}
	}
}

func TestRestartRestoresStationPolicyDisablesRulesAndDoesNotReplayCommands(t *testing.T) {
	dir := t.TempDir()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	p, _ := ps.Create(points.CreateInput{Station: "A", Name: "x", DataType: "FLOAT", SourceType: "manual"})
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	e, err := New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	if err = e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 500, RetentionDays: 15, PointIDs: []string{p.ID}}); err != nil {
		t.Fatal(err)
	}
	if err = e.SetRules([]Rule{{ID: "rule", Name: "rule", Enabled: true, Station: "A", Logic: "and", Conditions: []Condition{{p.ID, ">", 1}}, CooldownMS: 200, Trigger: "rising", Actions: []Action{{"snapshot", "", 0}}}}); err != nil {
		t.Fatal(err)
	}
	saved := Result{CommandID: "interrupted-physical", PointID: p.ID, State: "accepted", Value: 7, Version: e.version, At: time.Now()}
	if err = db.SaveConfig("command:"+saved.CommandID, saved); err != nil {
		t.Fatal(err)
	}
	e.Close()
	e, err = New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if policy := e.StoragePolicy("A"); !policy.Enabled || policy.RetentionDays != 15 || len(policy.PointIDs) != 1 {
		t.Fatalf("policy lost %+v", policy)
	}
	if e.rules[0].Enabled {
		t.Fatal("restart enabled actions")
	}
	result, err := e.Command(saved.CommandID)
	if err != nil || result.State != "unknown" {
		t.Fatalf("interrupted intent: %+v %v", result, err)
	}
	w := Write{CommandID: saved.CommandID, PointID: p.ID, Value: 7, Version: saved.Version}
	result, err = e.Write(w)
	if err != nil || result.State != "unknown" || len(e.live) != 0 {
		t.Fatalf("replayed command: %+v %v", result, err)
	}
}

func TestIndexedAcquisitionAtFifteenThousandPoints(t *testing.T) {
	dir := t.TempDir()
	definitions := make([]points.Definition, 0, 15000)
	for station := 0; station < 30; station++ {
		for n := 0; n < 500; n++ {
			definitions = append(definitions, points.Definition{ID: fmt.Sprintf("p-%d-%d", station, n), Station: fmt.Sprintf("S%02d", station), Name: fmt.Sprintf("P%03d", n), DataType: "FLOAT", SourceType: "mqtt", SourceID: fmt.Sprintf("source-%d", station/6), SourcePath: fmt.Sprintf("local%d/p%d", station%6, n), Topic: "data", ScaleFactor: 1, StaleMS: 10000})
		}
	}
	path := filepath.Join(dir, "points.json")
	data, _ := json.Marshal(definitions)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	ps, err := points.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	e, err := New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	now := time.Now()
	batch := make([]acquisition.Raw, 0, len(definitions))
	for i, p := range definitions {
		batch = append(batch, acquisition.Raw{SourceID: p.SourceID, Topic: p.Topic, Path: p.SourcePath, Value: float64(i), Quality: "good", Time: now, ReceivedTime: now})
	}
	e.Submit(batch)
	deadline := time.Now().Add(5 * time.Second)
	for e.processed.Load() != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.live) != 15000 {
		t.Fatalf("mapped %d/15000", len(e.live))
	}
	for i, p := range definitions {
		if e.live[p.ID].Value != float64(i) {
			t.Fatalf("source/path collision: %s", p.ID)
		}
	}
	if e.acceptedSamples.Load() != 15000 || e.processedSamples.Load() != 15000 || e.dropped.Load() != 0 {
		t.Fatal("dishonest sample counters")
	}
}

func TestFreshPhysicalReadbackRequiresNonRetainedNonPredatingGoodMatchingSample(t *testing.T) {
	e, ps := setup(t)
	p, _ := ps.Create(points.CreateInput{Station: "A", Name: "x", DataType: "FLOAT", SourceType: "mqtt", SourceID: "source", SourcePath: "path", Topic: "topic"})
	version, _ := e.Apply()
	published := time.Now().Add(-time.Second)
	id := "readback-command"
	reset := func() {
		e.pending[id] = &pendingWrite{Target: p, Result: Result{CommandID: id, PointID: p.ID, Value: 9, Version: version, State: "acknowledged", At: published.Add(-time.Second), PublishedAt: &published}, Deadline: time.Now().Add(time.Second)}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, raw := range []acquisition.Raw{
		{SourceID: "source", Topic: "topic", Path: "path", Value: 9.0, Quality: "good", Time: time.Now(), Retained: true},
		{SourceID: "source", Topic: "topic", Path: "path", Value: 9.0, Quality: "good", Time: published.Add(-time.Second)},
		{SourceID: "other", Topic: "topic", Path: "path", Value: 9.0, Quality: "good", Time: time.Now()},
		{SourceID: "source", Topic: "topic", Path: "path", Value: 9.0, Quality: "bad", Time: time.Now()},
		{SourceID: "source", Topic: "topic", Path: "path", Value: 8.0, Quality: "good", Time: time.Now()},
	} {
		reset()
		e.observeReadbackLocked(p, raw, time.Now())
		if e.pending[id] == nil {
			t.Fatalf("invalid readback confirmed %+v", raw)
		}
	}
	reset()
	now := time.Now()
	e.observeReadbackLocked(p, acquisition.Raw{SourceID: "source", Topic: "topic", Path: "path", Value: 9.0, Quality: "good", Time: now}, now)
	if e.pending[id] != nil {
		t.Fatal("fresh physical readback not confirmed")
	}
	var result Result
	e.Store.LoadConfig("command:"+id, &result)
	if result.State != "readback_confirmed" {
		t.Fatalf("confirmation not durable %+v", result)
	}
}

func TestRestartDistinguishesUnsentPublishingAndAcknowledgedCommands(t *testing.T) {
	e, _ := setup(t)
	for _, test := range []struct{ id, state, publish, ack, readback, wantState, wantPublish, wantReadback string }{
		{"restart-queued", "accepted", "queued", "pending", "pending", "failed", "not_sent", "pending"},
		{"restart-publishing", "accepted", "publishing", "pending", "pending", "unknown", "unknown", "pending"},
		{"restart-acknowledged", "acknowledged", "sent", "acknowledged", "pending", "acknowledged", "sent", "unconfirmed"},
	} {
		r := Result{CommandID: test.id, State: test.state, PublishState: test.publish, ACKState: test.ack, ReadbackState: test.readback}
		if err := e.Store.SaveConfig("command:"+test.id, r); err != nil {
			t.Fatal(err)
		}
		got, err := e.Command(test.id)
		if err != nil || got.State != test.wantState || got.PublishState != test.wantPublish || got.ReadbackState != test.wantReadback {
			t.Fatalf("restart recovery %+v %v", got, err)
		}
	}
}

func TestWriteActionMissingValueCannotDefaultToZero(t *testing.T) {
	for _, body := range []string{`{"type":"write","point_id":"p"}`, `{"type":"write","point_id":"p","value":null}`} {
		var action Action
		if err := json.Unmarshal([]byte(body), &action); err == nil {
			t.Fatal("missing write action value accepted")
		}
	}
	var action Action
	if err := json.Unmarshal([]byte(`{"type":"write","point_id":"p","value":0}`), &action); err != nil {
		t.Fatal(err)
	}
}

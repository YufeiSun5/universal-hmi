package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

// Stop the background clock, then exercise the same scan with explicit times.
// Every test uses its own on-disk SQLite database, never a production source.
func policyFixture(t *testing.T) (*Engine, *points.Service) {
	t.Helper()
	dir := t.TempDir()
	ps, err := points.Open(filepath.Join(dir, "points.json"))
	if err != nil {
		t.Fatal(err)
	}
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	e, err := New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	e.Close()
	return e, ps
}

func policyPoint(t *testing.T, ps *points.Service, station, name string, staleMS int) points.Definition {
	t.Helper()
	p, err := ps.Create(points.CreateInput{Station: station, Name: name, DataType: "FLOAT", SourceType: "manual", StaleMS: staleMS, Unit: "bar"})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func policyApply(t *testing.T, e *Engine) {
	t.Helper()
	if _, err := e.Apply(); err != nil {
		t.Fatal(err)
	}
}

func policyRows(t *testing.T, e *Engine, count int) []storage.Sample {
	t.Helper()
	rows, err := e.Store.Query(context.Background(), storage.Filter{})
	if err != nil || len(rows) != count {
		t.Fatalf("persisted rows=%d, want %d: %v; rows=%+v", len(rows), count, err, rows)
	}
	return rows
}

func storageRule(id, pointID, trigger, action string) Rule {
	return Rule{ID: id, Name: id, Enabled: true, Station: "A", Logic: "and", Conditions: []Condition{{PointID: pointID, Op: ">", Value: 5}}, CooldownMS: 200, Trigger: trigger, Actions: []Action{{Type: action}}}
}

func TestPeriodicStoragePersistsAtIntervalAndKeepsSampleTimestamps(t *testing.T) {
	e, ps := policyFixture(t)
	a := policyPoint(t, ps, "A", "selected", 1500)
	b := policyPoint(t, ps, "A", "excluded", 1500)
	c := policyPoint(t, ps, "B", "other station", 1500)
	policyApply(t, e)
	if err := e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 1000, RetentionDays: 7, PointIDs: []string{a.ID}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	for _, p := range []points.Definition{a, b, c} {
		e.ingest(p, 7.0, "good", now, now.Add(20*time.Millisecond))
	}
	e.evaluate(now)
	policyRows(t, e, 1)
	for _, elapsed := range []time.Duration{0, 200 * time.Millisecond, 999 * time.Millisecond} {
		e.evaluate(now.Add(elapsed))
		policyRows(t, e, 1)
	}
	e.evaluate(now.Add(time.Second))
	e.evaluate(now.Add(time.Second))
	rows := policyRows(t, e, 2)
	for _, r := range rows {
		if r.PointID != a.ID || r.Station != "A" || r.Unit != "bar" || r.Raw != 7.0 || r.Value != 7.0 || r.Quality != "good" || r.Version != e.version || !r.SourceTime.Equal(now) || !r.ReceivedTime.Equal(now.Add(20*time.Millisecond)) {
			t.Fatalf("snapshot did not preserve input semantics: %+v", r)
		}
	}
	e.evaluate(now.Add(2 * time.Second))
	rows = policyRows(t, e, 3)
	if rows[2].Quality != "stale" || rows[0].Quality != "good" {
		t.Fatalf("stale transition mutated or mislabeled history: %+v", rows)
	}
}

func TestChangedOnlyStorageTracksValueQualityAndConfiguration(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 1000)
	policyApply(t, e)
	if err := e.SetPolicy("A", Policy{Enabled: true, ChangedOnly: true, IntervalMS: 200, RetentionDays: 7}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	for _, elapsed := range []time.Duration{200, 400} {
		at := now.Add(elapsed * time.Millisecond)
		e.ingest(p, 7.0, "good", at, at)
		e.evaluate(at)
	}
	policyRows(t, e, 1)
	e.evaluate(now.Add(1500 * time.Millisecond))
	policyRows(t, e, 2)
	at := now.Add(1800 * time.Millisecond)
	e.ingest(p, 7.0, "bad", at, at)
	e.evaluate(at)
	policyRows(t, e, 3)
	at = now.Add(2 * time.Second)
	e.ingest(p, 7.0, "good", at, at)
	e.evaluate(at)
	rows := policyRows(t, e, 4)
	for i, want := range []string{"good", "stale", "bad", "good"} {
		if rows[i].Quality != want {
			t.Fatalf("quality[%d]=%s, want %s", i, rows[i].Quality, want)
		}
	}
	oldVersion := e.version
	p, err := ps.Update(p.ID, points.CreateInput{Station: "A", Name: "renamed", DataType: "FLOAT", SourceType: "manual", Unit: "kPa", StaleMS: 1000})
	if err != nil {
		t.Fatal(err)
	}
	policyApply(t, e)
	at = now.Add(2200 * time.Millisecond)
	e.ingest(p, 7.0, "good", at, at)
	e.evaluate(at)
	rows = policyRows(t, e, 5)
	if rows[0].Version != oldVersion || rows[0].Unit != "bar" || rows[0].Name != "input" || rows[4].Version == oldVersion || rows[4].Unit != "kPa" || rows[4].Name != "renamed" {
		t.Fatalf("configuration was not frozen: %+v", rows)
	}
}

func TestRepeatedStorageStartDoesNotResetIntervalOrChangedCache(t *testing.T) {
	for _, changedOnly := range []bool{false, true} {
		t.Run(map[bool]string{false: "periodic", true: "changed_only"}[changedOnly], func(t *testing.T) {
			e, ps := policyFixture(t)
			p := policyPoint(t, ps, "A", "input", 10000)
			policyApply(t, e)
			if err := e.SetPolicy("A", Policy{IntervalMS: 1000, RetentionDays: 7, ChangedOnly: changedOnly}); err != nil {
				t.Fatal(err)
			}
			rule := storageRule("repeat-start", p.ID, "periodic", "storage_start")
			if err := e.SetRules([]Rule{rule}); err != nil {
				t.Fatal(err)
			}
			now := time.Now()
			e.ingest(p, 7.0, "good", now, now)
			for _, ms := range []int{0, 200, 400, 600, 800} {
				e.evaluate(now.Add(time.Duration(ms) * time.Millisecond))
				policyRows(t, e, 1)
			}
			e.evaluate(now.Add(time.Second))
			want := 2
			if changedOnly {
				want = 1
			}
			policyRows(t, e, want)
		})
	}
}

func TestSavingUnchangedRuleDoesNotRepeatRisingAction(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyApply(t, e)
	rule := storageRule("save-stable", p.ID, "rising", "snapshot")
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	policyRows(t, e, 1)
	// The editor saves the whole rule list, including unchanged enabled rules.
	other := storageRule("another-rule", p.ID, "rising", "snapshot")
	other.Enabled = false
	if err := e.SetRules([]Rule{other, rule}); err != nil {
		t.Fatal(err)
	}
	e.evaluate(now.Add(time.Second))
	policyRows(t, e, 1)
	rule.Name = "renamed without rearming"
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	e.evaluate(now.Add(1200 * time.Millisecond))
	policyRows(t, e, 1)
	e.ingest(p, 1.0, "good", now.Add(2*time.Second), now.Add(2*time.Second))
	e.evaluate(now.Add(2 * time.Second))
	e.ingest(p, 7.0, "good", now.Add(3*time.Second), now.Add(3*time.Second))
	e.evaluate(now.Add(3 * time.Second))
	policyRows(t, e, 2)
}

func TestStorageFailureRemainsVisibleAcrossSuccessfulIndependentScope(t *testing.T) {
	e, ps := policyFixture(t)
	a := policyPoint(t, ps, "A", "failing", 10000)
	b := policyPoint(t, ps, "B", "working", 10000)
	policyApply(t, e)
	if err := e.SetPolicy("", Policy{Enabled: true, IntervalMS: 1000, RetentionDays: 7, PointIDs: []string{a.ID}}); err != nil {
		t.Fatal(err)
	}
	if err := e.SetPolicy("B", Policy{Enabled: true, IntervalMS: 200, RetentionDays: 7}); err != nil {
		t.Fatal(err)
	}
	_, err := e.Store.DB.Exec(`CREATE TRIGGER reject_a BEFORE INSERT ON samples WHEN NEW.station='A' BEGIN SELECT RAISE(ABORT, 'isolated storage failure'); END`)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(a, 7.0, "good", now, now)
	e.ingest(b, 8.0, "good", now, now)
	e.evaluate(now)
	policyRows(t, e, 1)
	if !strings.Contains(e.storageError, "isolated storage failure") {
		t.Fatalf("successful independent policy hid failure: %q", e.storageError)
	}
	e.evaluate(now.Add(200 * time.Millisecond))
	policyRows(t, e, 2)
	if !strings.Contains(e.storageError, "isolated storage failure") {
		t.Fatalf("failure cleared before failing policy retried: %q", e.storageError)
	}
	if _, err := e.Store.DB.Exec("DROP TRIGGER reject_a"); err != nil {
		t.Fatal(err)
	}
	e.evaluate(now.Add(time.Second))
	policyRows(t, e, 4)
	if e.storageError != "" {
		t.Fatalf("recovered storage failure did not clear: %q", e.storageError)
	}
}

func TestRuleExecutionLogFailureIsNotHiddenBySuccessfulStorage(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyApply(t, e)
	if err := e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 200, RetentionDays: 7}); err != nil {
		t.Fatal(err)
	}
	rule := storageRule("log-failure", p.ID, "periodic", "snapshot")
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Store.DB.Exec(`CREATE TRIGGER reject_log BEFORE INSERT ON executions BEGIN SELECT RAISE(ABORT, 'isolated rule log failure'); END`); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	policyRows(t, e, 2)
	if !strings.Contains(e.storageError, "isolated rule log failure") {
		t.Fatalf("successful storage hid execution log failure: %q", e.storageError)
	}
	if _, err := e.Store.DB.Exec("DROP TRIGGER reject_log"); err != nil {
		t.Fatal(err)
	}
	e.evaluate(now.Add(200 * time.Millisecond))
	if e.storageError != "" {
		t.Fatalf("successful rule log retry did not clear failure: %q", e.storageError)
	}
}

func TestConditionStorageStartStopAndHoldWriteActualRows(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyPoint(t, ps, "B", "excluded", 10000)
	policyApply(t, e)
	if err := e.SetPolicy("A", Policy{IntervalMS: 200, RetentionDays: 7}); err != nil {
		t.Fatal(err)
	}
	start := storageRule("start-on-high", p.ID, "rising", "storage_start")
	start.HoldMS = 400
	stop := storageRule("stop-on-recovery", p.ID, "recovery", "storage_stop")
	stop.HoldMS = 400
	if err := e.SetRules([]Rule{start, stop}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.evaluate(now) // missing is unknown, not zero
	policyRows(t, e, 0)
	e.ingest(p, 7.0, "bad", now, now)
	e.evaluate(now)
	policyRows(t, e, 0)
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	e.evaluate(now.Add(399 * time.Millisecond))
	policyRows(t, e, 0)
	e.evaluate(now.Add(400 * time.Millisecond))
	policyRows(t, e, 1)
	e.evaluate(now.Add(600 * time.Millisecond))
	policyRows(t, e, 2)
	at := now.Add(800 * time.Millisecond)
	e.ingest(p, 1.0, "good", at, at)
	e.evaluate(at)
	e.evaluate(now.Add(time.Second))
	policyRows(t, e, 2)
	if e.StoragePolicy("A").Enabled || e.StoragePolicy("").Enabled {
		t.Fatal("recovery failed to stop scoped storage")
	}
	logs, err := e.Store.Logs()
	if err != nil || len(logs) != 2 {
		t.Fatalf("start/stop executions=%d: %v", len(logs), err)
	}
	for _, raw := range logs {
		var log struct {
			Station string `json:"station"`
			Results []struct {
				State string `json:"state"`
			} `json:"results"`
		}
		if err := json.Unmarshal(raw, &log); err != nil || log.Station != "A" || len(log.Results) != 1 || log.Results[0].State != "completed" {
			t.Fatalf("incorrect persisted action result: %s, %v", raw, err)
		}
	}
}

func TestConditionThresholdJSONRequiresExplicitValue(t *testing.T) {
	for _, body := range []string{`{"point_id":"p","op":">"}`, `{"point_id":"p","op":">","value":null}`} {
		var condition Condition
		if err := json.Unmarshal([]byte(body), &condition); err == nil {
			t.Fatalf("missing threshold defaulted to zero: %s", body)
		}
	}
	var condition Condition
	if err := json.Unmarshal([]byte(`{"point_id":"p","op":">","value":0}`), &condition); err != nil || condition.Value != 0 {
		t.Fatalf("explicit zero threshold rejected: %+v %v", condition, err)
	}
}

func TestRulePreviewRejectsInvalidDefinitionsWithoutSideEffects(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyApply(t, e)
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	valid := storageRule("preview-valid", p.ID, "rising", "storage_start")
	if got := e.Preview(valid); got["known"] != true || got["matches"] != true || got["side_effects"] != false {
		t.Fatalf("valid preview: %+v", got)
	}
	invalid := []Rule{{}, valid, valid, valid, valid}
	invalid[1].Logic = "invalid"
	invalid[2].Conditions = []Condition{{PointID: p.ID, Op: "invalid", Value: 5}}
	invalid[3].Actions = []Action{{Type: "run_shell"}}
	invalid[4].HoldMS = -1
	for _, rule := range invalid {
		got := e.Preview(rule)
		if got["known"] != false || got["matches"] != false || got["side_effects"] != false || got["error"] == nil {
			t.Fatalf("invalid definition produced misleading preview: %+v => %+v", rule, got)
		}
	}
	policyRows(t, e, 0)
	logs, err := e.Store.Logs()
	if err != nil || len(logs) != 0 || len(e.rules) != 0 || len(e.ruleStates) != 0 || e.StoragePolicy("A").Enabled {
		t.Fatalf("preview performed an action or saved a rule: logs=%s err=%v", logs, err)
	}
}

func TestRuleActionsRecordPartialFailureAndContinueInOrder(t *testing.T) {
	e, ps := policyFixture(t)
	input := policyPoint(t, ps, "A", "input", 10000)
	max := 10.0
	output, err := ps.Create(points.CreateInput{Station: "A", Name: "output", DataType: "FLOAT", SourceType: "manual", Writable: true, Max: &max})
	if err != nil {
		t.Fatal(err)
	}
	policyApply(t, e)
	rule := storageRule("partial-actions", input.ID, "rising", "snapshot")
	rule.Actions = []Action{{Type: "write", PointID: output.ID, Value: 99}, {Type: "write", PointID: output.ID, Value: 8}, {Type: "snapshot"}}
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(input, 7.0, "good", now, now)
	e.evaluate(now)
	rows := policyRows(t, e, 2)
	for _, r := range rows {
		if r.PointID == output.ID && r.Value != 8.0 {
			t.Fatalf("snapshot did not observe preceding successful action: %+v", r)
		}
	}
	logs, err := e.Store.Logs()
	if err != nil || len(logs) != 2 {
		t.Fatalf("expected one successful local command and one rule log: %s %v", logs, err)
	}
	var execution struct {
		Type    string `json:"type"`
		Results []struct {
			State   string `json:"state"`
			Message string `json:"message"`
		} `json:"results"`
	}
	if err := json.Unmarshal(logs[0], &execution); err != nil {
		t.Fatal(err)
	}
	if execution.Type != "rule" || len(execution.Results) != 3 || execution.Results[0].State != "failed" || !strings.Contains(execution.Results[0].Message, "range") || execution.Results[1].State != "readback_confirmed" || execution.Results[2].State != "completed" {
		t.Fatalf("partial result was mislabeled: %s", logs[0])
	}
	e.evaluate(now.Add(time.Second))
	policyRows(t, e, 2)
	logs, _ = e.Store.Logs()
	if len(logs) != 2 {
		t.Fatal("partially successful rising rule repeated without a new edge")
	}
}

func TestRestartStorageResumesOnlyFreshSamplesAndNeverEnabledRules(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "points.json")
	ps, err := points.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	p := policyPoint(t, ps, "A", "input", 10000)
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	e, err := New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	e.Close()
	if err := e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 200, RetentionDays: 7, PointIDs: []string{p.ID}}); err != nil {
		t.Fatal(err)
	}
	rule := storageRule("restart-disabled", p.ID, "rising", "snapshot")
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	policyRows(t, e, 2)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	ps, err = points.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	db, err = storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	e, err = New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	e.Close()
	policy := e.StoragePolicy("A")
	if !policy.Enabled || policy.IntervalMS != 200 || policy.RetentionDays != 7 || len(policy.PointIDs) != 1 || policy.PointIDs[0] != p.ID || len(e.live) != 0 || len(e.rules) != 1 || e.rules[0].Enabled {
		t.Fatalf("restart contract changed: policy=%+v, samples=%+v, rules=%+v", policy, e.live, e.rules)
	}
	e.evaluate(now.Add(time.Second))
	policyRows(t, e, 2)
	at := now.Add(2 * time.Second)
	e.ingest(p, 8.0, "good", at, at)
	e.evaluate(at)
	rows := policyRows(t, e, 3)
	if rows[2].Value != 8.0 || !rows[2].SourceTime.Equal(at.UTC().Truncate(time.Millisecond)) {
		t.Fatalf("fresh sample was not durably resumed: %+v", rows[2])
	}
	logs, err := e.Store.Logs()
	if err != nil || len(logs) != 1 {
		t.Fatalf("restart replayed a disabled rule: %s %v", logs, err)
	}
}

func TestSavedPolicyAndRulesDoNotShareMutableCallerSlices(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	q := policyPoint(t, ps, "A", "other", 10000)
	policyApply(t, e)
	policy := Policy{IntervalMS: 200, RetentionDays: 7, PointIDs: []string{p.ID}}
	if err := e.SetPolicy("", policy); err != nil {
		t.Fatal(err)
	}
	policy.PointIDs[0] = q.ID
	read := e.StoragePolicy("")
	read.PointIDs[0] = q.ID
	if got := e.StoragePolicy(""); got.PointIDs[0] != p.ID {
		t.Fatalf("caller mutated policy: %+v", got)
	}
	rule := storageRule("immutable-rule", p.ID, "rising", "snapshot")
	rules := []Rule{rule}
	if err := e.SetRules(rules); err != nil {
		t.Fatal(err)
	}
	rules[0].Enabled = false
	rule.Conditions[0].PointID = q.ID
	rule.Actions[0].Type = "storage_start"
	if !e.rules[0].Enabled || e.rules[0].Conditions[0].PointID != p.ID || e.rules[0].Actions[0].Type != "snapshot" {
		t.Fatalf("caller mutated active rule: %+v", e.rules)
	}
}

func TestRuleTriggersRespectDuplicateScansAndCooldownBoundaries(t *testing.T) {
	for _, test := range []struct {
		trigger string
		counts  []int
	}{
		{"rising", []int{1, 1, 1, 1, 1, 2}},
		{"periodic", []int{1, 1, 1, 2, 2, 3}},
		{"recovery", []int{0, 0, 0, 0, 1, 1}},
	} {
		t.Run(test.trigger, func(t *testing.T) {
			e, ps := policyFixture(t)
			p := policyPoint(t, ps, "A", "input", 1000)
			policyApply(t, e)
			rule := storageRule("trigger-"+test.trigger, p.ID, test.trigger, "snapshot")
			if err := e.SetRules([]Rule{rule}); err != nil {
				t.Fatal(err)
			}
			now := time.Now()
			for i, ms := range []int{0, 0, 199, 200, 400, 600} {
				at := now.Add(time.Duration(ms) * time.Millisecond)
				value := 7.0
				if ms == 400 {
					value = 1
				}
				e.ingest(p, value, "good", at, at)
				e.evaluate(at)
				policyRows(t, e, test.counts[i])
			}
			// Loss of freshness or bad quality is unknown, never a recovery edge.
			e.evaluate(now.Add(1601 * time.Millisecond))
			policyRows(t, e, test.counts[len(test.counts)-1])
			at := now.Add(2 * time.Second)
			e.ingest(p, 1.0, "bad", at, at)
			e.evaluate(at)
			policyRows(t, e, test.counts[len(test.counts)-1])
		})
	}
}

func TestRuleHoldRestartsAfterUnknownInput(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 1000)
	policyApply(t, e)
	rule := storageRule("continuous-hold", p.ID, "rising", "snapshot")
	rule.HoldMS = 400
	if err := e.SetRules([]Rule{rule}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, ms := range []int{0, 300, 400, 799} {
		quality := "good"
		if ms == 300 {
			quality = "bad"
		}
		at := now.Add(time.Duration(ms) * time.Millisecond)
		e.ingest(p, 7.0, quality, at, at)
		e.evaluate(at)
		policyRows(t, e, 0)
	}
	e.evaluate(now.Add(800 * time.Millisecond))
	policyRows(t, e, 1)
}

func TestConditionLogicDoesNotSubstituteMissingBadOrStaleInputs(t *testing.T) {
	e, ps := policyFixture(t)
	a := policyPoint(t, ps, "A", "a", 1000)
	b := policyPoint(t, ps, "A", "b", 1000)
	policyApply(t, e)
	now := time.Now()
	e.ingest(a, 7.0, "good", now, now)
	for _, logic := range []string{"and", "or"} {
		rule := storageRule("logic-"+logic, a.ID, "rising", "snapshot")
		rule.Logic = logic
		rule.Conditions = append(rule.Conditions, Condition{PointID: b.ID, Op: ">", Value: 5})
		delete(e.live, b.ID)
		if match, known := e.condition(rule, now); known || match {
			t.Fatalf("%s replaced missing input with a value", logic)
		}
		e.ingest(b, 1.0, "bad", now, now)
		if match, known := e.condition(rule, now); known || match {
			t.Fatalf("%s evaluated bad-quality input", logic)
		}
		e.ingest(b, 1.0, "good", now, now)
		if match, known := e.condition(rule, now); !known || match != (logic == "or") {
			t.Fatalf("%s comparison = %t known=%t", logic, match, known)
		}
		if match, known := e.condition(rule, now.Add(1001*time.Millisecond)); known || match {
			t.Fatalf("%s evaluated stale input", logic)
		}
	}
}

func TestChangedOnlyRetriesFailedBatchWithoutAdvancingValueBaseline(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyApply(t, e)
	if err := e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 200, RetentionDays: 7, ChangedOnly: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Store.DB.Exec(`CREATE TRIGGER reject_samples BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'retry test'); END`); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	e.evaluate(now)
	policyRows(t, e, 0)
	if e.storageError == "" {
		t.Fatal("failed append was not visible")
	}
	if _, err := e.Store.DB.Exec("DROP TRIGGER reject_samples"); err != nil {
		t.Fatal(err)
	}
	e.evaluate(now.Add(200 * time.Millisecond))
	policyRows(t, e, 1)
	if e.storageError != "" {
		t.Fatalf("recovered policy error did not clear: %s", e.storageError)
	}
	e.evaluate(now.Add(400 * time.Millisecond))
	policyRows(t, e, 1)
}

func TestCommandPersistenceFailureIsNotHiddenByPolicySuccess(t *testing.T) {
	for _, target := range []string{"config", "executions"} {
		t.Run(target, func(t *testing.T) {
			e, ps := policyFixture(t)
			p := policyPoint(t, ps, "A", "input", 10000)
			policyApply(t, e)
			if err := e.SetPolicy("A", Policy{Enabled: true, IntervalMS: 200, RetentionDays: 7}); err != nil {
				t.Fatal(err)
			}
			statement := "CREATE TRIGGER reject_command BEFORE INSERT ON " + target
			if target == "config" {
				statement += " WHEN NEW.key='command:write-audit'"
			}
			statement += " BEGIN SELECT RAISE(ABORT, 'command persistence failure'); END"
			if _, err := e.Store.DB.Exec(statement); err != nil {
				t.Fatal(err)
			}
			result := Result{CommandID: "write-audit", PointID: p.ID, Value: 7, Version: e.version, State: "unknown", At: time.Now()}
			if err := e.persistResultLocked(result); err == nil {
				t.Fatal("command persistence failure was not reported")
			}
			now := time.Now()
			e.ingest(p, 7.0, "good", now, now)
			e.evaluate(now)
			policyRows(t, e, 1)
			if !strings.Contains(e.storageError, "command:write-audit") || !strings.Contains(e.storageError, "command persistence failure") {
				t.Fatalf("history success hid command persistence failure: %q", e.storageError)
			}
			if _, err := e.Store.DB.Exec("DROP TRIGGER reject_command"); err != nil {
				t.Fatal(err)
			}
			if err := e.persistResultLocked(result); err != nil || e.storageError != "" {
				t.Fatalf("command persistence recovery: %v, status=%q", err, e.storageError)
			}
		})
	}
}

func TestStorageFailureDetailsAreBoundedAndOverflowRemainsVisible(t *testing.T) {
	e := &Engine{}
	failure := fmt.Errorf("unresolved persistence failure")
	for i := 0; i < maxStorageFailureDetails+100; i++ {
		e.recordStorageErrorLocked(fmt.Sprintf("command:%d", i), failure)
	}
	if len(e.storageFailures) != maxStorageFailureDetails+1 || !strings.Contains(e.storageError, "additional storage failures omitted") {
		t.Fatalf("failure detail bound or overflow warning missing: count=%d status=%s", len(e.storageFailures), e.storageError)
	}
	for i := 0; i < maxStorageFailureDetails+100; i++ {
		e.recordStorageErrorLocked(fmt.Sprintf("command:%d", i), nil)
	}
	if len(e.storageFailures) != 1 || !strings.Contains(e.storageError, "overflow") {
		t.Fatalf("unreconciled omitted operations incorrectly became healthy: %+v", e.storageFailures)
	}
	e.recordStorageErrorLocked("policy:A", nil)
	if e.storageError == "" {
		t.Fatal("unrelated success cleared overflow")
	}
}

func TestRuleConditionOperatorsRequireExactSupportedMembership(t *testing.T) {
	e, ps := policyFixture(t)
	p := policyPoint(t, ps, "A", "input", 10000)
	policyApply(t, e)
	now := time.Now()
	e.ingest(p, 7.0, "good", now, now)
	for _, operator := range []string{">", ">=", "<", "<=", "==", "!="} {
		rule := storageRule("valid-operator", p.ID, "rising", "snapshot")
		rule.Conditions[0].Op = operator
		if err := e.SetRules([]Rule{rule}); err != nil {
			t.Fatalf("supported operator %q rejected: %v", operator, err)
		}
		if preview := e.Preview(rule); preview["known"] != true || preview["matches"] != compare(7, 5, operator) || preview["side_effects"] != false {
			t.Fatalf("supported operator %q preview: %+v", operator, preview)
		}
	}
	for _, operator := range []string{"", "|", ">|>=", "<|<=", "==|!=", ">|>=|<|<=|==|!=", " >", ">= "} {
		rule := storageRule("invalid-operator", p.ID, "rising", "snapshot")
		rule.Conditions[0].Op = operator
		if err := e.SetRules([]Rule{rule}); err == nil {
			t.Fatalf("unsupported composite/partial operator %q accepted", operator)
		}
		if preview := e.Preview(rule); preview["known"] != false || preview["matches"] != false || preview["error"] == nil || preview["side_effects"] != false {
			t.Fatalf("unsupported operator %q produced valid preview: %+v", operator, preview)
		}
	}
	if len(e.rules) != 1 || e.rules[0].ID != "valid-operator" {
		t.Fatal("rejected operator changed active rules")
	}
	policyRows(t, e, 0)
}

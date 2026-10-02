package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func focusedRequest(t *testing.T, h http.Handler, method, path string, body any, out any) {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	w := request(h, method, path, string(encoded))
	if w.Code < 200 || w.Code >= 300 {
		t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
	}
	if out != nil {
		if err := json.Unmarshal(w.Body.Bytes(), out); err != nil {
			t.Fatal(err)
		}
	}
}

func focusedHistory(t *testing.T, h http.Handler, station string) []storage.Sample {
	t.Helper()
	var page struct {
		Items []storage.Sample `json:"items"`
	}
	focusedRequest(t, h, "GET", "/api/v1/history?station="+station, nil, &page)
	return page.Items
}

func focusedWait(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("background workflow did not reach the expected state")
}

// Use public HTTP contracts and the real background scan/SQLite persistence.
// Conditions and writes use engineering units; manual samples are raw units.
func TestHTTPScaledConditionPreviewAndActionSequence(t *testing.T) {
	h, _, _ := platform(t)
	create := func(name string, factor, offset float64, writable bool) points.Definition {
		var p points.Definition
		focusedRequest(t, h, "POST", "/api/v1/points", points.CreateInput{
			Station: "A", Name: name, SourceType: "manual", DataType: "FLOAT",
			ScaleFactor: &factor, Offset: offset, Writable: writable, StaleMS: 10000,
		}, &p)
		return p
	}
	input := create("scaled sensor", 2.5, -10, false)
	output := create("scaled setpoint", -0.5, 20, true)
	focusedRequest(t, h, "POST", "/api/v1/apply", nil, nil)
	focusedRequest(t, h, "POST", "/api/v1/points/"+input.ID+"/sample", map[string]any{"value": 12}, nil)
	focusedRequest(t, h, "POST", "/api/v1/points/"+output.ID+"/sample", map[string]any{"value": 0}, nil)
	rule := rt.Rule{ID: "scaled-condition", Name: "engineering threshold", Station: "A", Logic: "and", Trigger: "rising", CooldownMS: 200,
		Conditions: []rt.Condition{{PointID: input.ID, Op: ">=", Value: 20}},
		Actions:    []rt.Action{{Type: "write", PointID: output.ID, Value: 15}, {Type: "snapshot"}},
	}
	var preview map[string]any
	focusedRequest(t, h, "POST", "/api/v1/rules/preview", rule, &preview)
	if preview["known"] != true || preview["matches"] != true || preview["side_effects"] != false {
		t.Fatalf("preview: %v", preview)
	}
	if rows := focusedHistory(t, h, "A"); len(rows) != 0 {
		t.Fatal("preview stored rows")
	}
	var state struct {
		Values []storage.Sample `json:"values"`
	}
	focusedRequest(t, h, "GET", "/api/v1/runtime", nil, &state)
	for _, s := range state.Values {
		if s.PointID == output.ID && s.Raw != float64(0) {
			t.Fatal("preview performed write")
		}
	}
	rule.Enabled = true
	focusedRequest(t, h, "PUT", "/api/v1/rules", map[string]any{"items": []rt.Rule{rule}}, nil)
	focusedWait(t, func() bool { return len(focusedHistory(t, h, "A")) == 2 })
	rows := focusedHistory(t, h, "A")
	for _, s := range rows {
		if s.Quality != "good" || s.SourceTime.IsZero() || s.ReceivedTime.IsZero() || s.Version == "" {
			t.Fatalf("incomplete frozen row: %+v", s)
		}
		switch s.PointID {
		case input.ID:
			if s.Raw != float64(12) || s.Value != float64(20) {
				t.Fatalf("read conversion: %+v", s)
			}
		case output.ID:
			if s.Raw != float64(10) || s.Value != float64(15) {
				t.Fatalf("write inverse conversion: %+v", s)
			}
		default:
			t.Fatalf("unexpected row: %+v", s)
		}
	}
	// Re-saving an unchanged rule must not execute its write/snapshot again.
	focusedRequest(t, h, "PUT", "/api/v1/rules", map[string]any{"items": []rt.Rule{rule}}, nil)
	time.Sleep(450 * time.Millisecond)
	if rows := focusedHistory(t, h, "A"); len(rows) != 2 {
		t.Fatalf("unchanged save replayed actions: %d rows", len(rows))
	}
	var logs struct {
		Items []map[string]any `json:"items"`
	}
	focusedRequest(t, h, "GET", "/api/v1/executions", nil, &logs)
	rules := 0
	for _, row := range logs.Items {
		if row["type"] != "rule" {
			continue
		}
		rules++
		results := row["results"].([]any)
		if len(results) != 2 || results[0].(map[string]any)["state"] != "readback_confirmed" || results[1].(map[string]any)["state"] != "completed" {
			t.Fatalf("action results: %v", results)
		}
	}
	if rules != 1 {
		t.Fatalf("expected one logged execution, got %d", rules)
	}
}

func TestHTTPTimedStoragePersistsWithoutUISession(t *testing.T) {
	h, _, _ := platform(t)
	var p points.Definition
	focusedRequest(t, h, "POST", "/api/v1/points", map[string]any{"station": "timer", "name": "sensor", "source_type": "manual", "data_type": "FLOAT", "scale_factor": 0.25, "offset": 2, "stale_ms": 10000}, &p)
	focusedRequest(t, h, "POST", "/api/v1/apply", nil, nil)
	focusedRequest(t, h, "POST", "/api/v1/points/"+p.ID+"/sample", map[string]any{"value": 8}, nil)
	policy := rt.Policy{Station: "timer", Enabled: true, IntervalMS: 200, RetentionDays: 30, PointIDs: []string{p.ID}}
	focusedRequest(t, h, "PUT", "/api/v1/storage?station=timer", policy, nil)
	// No UI session or acquisition update is needed between periodic captures.
	time.Sleep(700 * time.Millisecond)
	focusedWait(t, func() bool { return len(focusedHistory(t, h, "timer")) >= 2 })
	policy.Enabled = false
	focusedRequest(t, h, "PUT", "/api/v1/storage?station=timer", policy, nil)
	rows := focusedHistory(t, h, "timer")
	if len(rows) < 2 {
		t.Fatalf("periodic storage failed: %d rows", len(rows))
	}
	for _, row := range rows {
		if row.Raw != float64(8) || row.Value != float64(4) || !row.SourceTime.Equal(rows[0].SourceTime) || !row.ReceivedTime.Equal(rows[0].ReceivedTime) {
			t.Fatalf("frozen source timestamp/value changed: %+v", row)
		}
	}
	time.Sleep(450 * time.Millisecond)
	if got := len(focusedHistory(t, h, "timer")); got != len(rows) {
		t.Fatal(fmt.Sprintf("disabled policy continued: %d -> %d", len(rows), got))
	}
}

func TestHTTPRuleMissingThresholdCannotBecomeZero(t *testing.T) {
	h, _, _ := platform(t)
	for _, endpoint := range []string{"/api/v1/rules", "/api/v1/rules/preview"} {
		for _, value := range []string{"", `,"value":null`} {
			body := `{"id":"missing-value","name":"invalid","enabled":true,"logic":"and","trigger":"rising","cooldown_ms":200,"conditions":[{"point_id":"p","op":">"` + value + `}],"actions":[{"type":"snapshot"}]}`
			method := "POST"
			if endpoint == "/api/v1/rules" {
				body = `{"items":[` + body + `]}`
				method = "PUT"
			}
			w := request(h, method, endpoint, body)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("%s accepted implicit zero threshold: %d %s", endpoint, w.Code, w.Body.String())
			}
		}
	}
}

package server

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func readDeltaFrame(t *testing.T, scanner *bufio.Scanner) (string, map[string]any) {
	t.Helper()
	event := ""
	var data map[string]any
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: ") {
			event = strings.TrimPrefix(line, "event: ")
		}
		if strings.HasPrefix(line, "data: ") {
			if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &data); err != nil {
				t.Fatal(err)
			}
		}
		if line == "" {
			return event, data
		}
	}
	t.Fatalf("stream closed: %v", scanner.Err())
	return "", nil
}

func TestDeltaStreamSelectionHeartbeatResetRevocationAndFiftySessions(t *testing.T) {
	_, ps, e := platform(t)
	var targets []points.Definition
	for _, station := range []string{"A", "B"} {
		p, err := ps.Create(points.CreateInput{Station: station, Name: station, SourceType: "manual", DataType: "FLOAT", StaleMS: 60000})
		if err != nil {
			t.Fatal(err)
		}
		targets = append(targets, p)
	}
	if _, err := e.Apply(); err != nil {
		t.Fatal(err)
	}
	for _, p := range targets {
		if err := e.Manual(p.ID, 1.0); err != nil {
			t.Fatal(err)
		}
	}
	e.RequireIdentity()
	var authorized atomic.Bool
	authorized.Store(true)
	h := runtimeStream(e)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := authorization.Actor{ID: r.Header.Get("X-Test-Session"), Valid: authorized.Load, StationID: func(n string) string { return n }, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}}
		h(w, withStreamAccess(r.WithContext(authorization.WithActor(r.Context(), a)), authorized.Load))
	}))
	defer srv.Close()
	connect := func(path string, i int) (*http.Response, *bufio.Scanner) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		t.Cleanup(cancel)
		req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+path, nil)
		req.Header.Set("X-Test-Session", fmt.Sprint(i))
		response, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 {
			response.Body.Close()
			t.Fatalf("connection %d: %d", i, response.StatusCode)
		}
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 4096), 4*1024*1024)
		return response, scanner
	}
	path := "/?protocol=delta&ids=" + targets[0].ID + "," + targets[1].ID
	var responses []*http.Response
	defer func() {
		for _, r := range responses {
			r.Body.Close()
		}
	}()
	var scanner *bufio.Scanner
	var first map[string]any
	for i := 0; i < 50; i++ {
		r, s := connect(path, i)
		responses = append(responses, r)
		event, frame := readDeltaFrame(t, s)
		values := frame["values"].([]any)
		if event != "runtime-delta" || frame["kind"] != "reset" || frame["sequence"] != float64(1) || len(values) != 1 || values[0].(map[string]any)["point_id"] != targets[0].ID {
			t.Fatal("scope or initial reset", frame)
		}
		if values[0].(map[string]any)["raw"] != nil {
			t.Fatal("viewer raw value leaked")
		}
		if i == 0 {
			scanner = s
			first = frame
		}
	}
	_, heartbeat := readDeltaFrame(t, scanner)
	if heartbeat["kind"] != "delta" || len(heartbeat["values"].([]any)) != 0 || heartbeat["meta"] != nil {
		t.Fatal("unchanged values/metadata resent", heartbeat)
	}
	if err := e.Manual(targets[0].ID, 42.0); err != nil {
		t.Fatal(err)
	}
	for {
		_, frame := readDeltaFrame(t, scanner)
		values := frame["values"].([]any)
		if len(values) == 0 {
			continue
		}
		v := values[0].(map[string]any)
		if len(values) != 1 || v["value"] != 42.0 || v["name"] != nil || v["unit"] != nil {
			t.Fatal("invalid compact delta", frame)
		}
		break
	}
	responses[0].Body.Close()
	r, s := connect(path, 51)
	responses = append(responses, r)
	_, frame := readDeltaFrame(t, s)
	if frame["kind"] != "reset" || frame["epoch"] == first["epoch"] || frame["values"].([]any)[0].(map[string]any)["value"] != 42.0 {
		t.Fatal("reconnect reset", frame)
	}
	if err := ps.Delete(targets[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Apply(); err != nil {
		t.Fatal(err)
	}
	for {
		_, frame = readDeltaFrame(t, s)
		if frame["kind"] == "reset" {
			break
		}
	}
	if len(frame["values"].([]any)) != 0 || len(frame["removed"].([]any)) != 1 {
		t.Fatal("deleted point retained", frame)
	}
	authorized.Store(false)
	for {
		event, _ := readDeltaFrame(t, s)
		if event == "session-expired" {
			break
		}
	}
}

func TestDeltaEmptyAndInvalidSelections(t *testing.T) {
	_, _, e := platform(t)
	h := runtimeStream(e)
	for _, ids := range []string{",bad", "%20a", "a,,b", strings.Repeat("a,", 5000) + "b"} {
		w := httptest.NewRecorder()
		h(w, httptest.NewRequest("GET", "/?protocol=delta&ids="+ids, nil))
		if w.Code != 400 {
			t.Fatalf("invalid selection accepted %d", w.Code)
		}
	}
	ids, err := subscriptionIDs(httptest.NewRequest("GET", "/?ids=", nil))
	if err != nil || ids == nil || len(ids) != 0 {
		t.Fatal("empty means health-only", ids, err)
	}
}

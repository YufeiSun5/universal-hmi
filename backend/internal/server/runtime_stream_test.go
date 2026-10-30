package server

import (
	"bufio"
	"context"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuntimeStreamSnapshotUpdatesRevocationAndReconnect(t *testing.T) {
	h, ps, e := platform(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "temperature", DataType: "FLOAT", SourceType: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	var allowed atomic.Bool
	allowed.Store(true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { h.ServeHTTP(w, withStreamAccess(r, allowed.Load)) }))
	defer server.Close()
	connect := func() (*http.Response, *bufio.Scanner) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		t.Cleanup(cancel)
		req, _ := http.NewRequestWithContext(ctx, "GET", server.URL+"/api/v1/runtime/events", nil)
		response, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 || response.Header.Get("Content-Type") != "text/event-stream" {
			t.Fatalf("bad stream: %v", response)
		}
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 4096), 32*1024*1024)
		return response, scanner
	}
	frame := func(scanner *bufio.Scanner) (string, map[string]any) {
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
		t.Fatalf("stream ended: %v", scanner.Err())
		return "", nil
	}
	response, scanner := connect()
	defer response.Body.Close()
	event, data := frame(scanner)
	if event != "runtime" || len(data["values"].([]any)) != 1 {
		t.Fatalf("missing initial snapshot: %v", data)
	}
	if err := e.Manual(p.ID, 42.5); err != nil {
		t.Fatal(err)
	}
	for {
		_, data = frame(scanner)
		value := data["values"].([]any)[0].(map[string]any)
		if value["value"] == 42.5 {
			break
		}
	}
	allowed.Store(false)
	for {
		event, _ = frame(scanner)
		if event == "session-expired" {
			break
		}
	}
	response.Body.Close()
	allowed.Store(true)
	response2, scanner2 := connect()
	defer response2.Body.Close()
	_, data = frame(scanner2)
	if data["values"].([]any)[0].(map[string]any)["value"] != 42.5 {
		t.Fatal("reconnect did not replace with current snapshot")
	}
}

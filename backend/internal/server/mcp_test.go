package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

// Existing business-operation fixtures explicitly opt into runtime write mode.
// New mode-control tests exercise the production read-only startup and API gate.
func newFixtureMCPHandler(api http.Handler, options MCPOptions) http.Handler {
	h := NewMCPHandler(api, options)
	if options.AllowWrite {
		h.mode = MCPWrite
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := PrincipalFromContext(r.Context()); !ok {
			r = r.WithContext(context.WithValue(r.Context(), principalKey{}, Principal{Username: "local-fixture", Local: true, AllowWrite: true}))
		}
		h.ServeHTTP(w, r)
	})
}

func mcpRequest(h http.Handler, body string) *httptest.ResponseRecorder {
	request := httptest.NewRequest("POST", "http://127.0.0.1/mcp", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("MCP-Protocol-Version", MCPProtocolVersion)
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	return response
}
func mcpRPC(t *testing.T, h http.Handler, method string, params any) map[string]any {
	t.Helper()
	data, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 7, "method": method, "params": params})
	if err != nil {
		t.Fatal(err)
	}
	response := mcpRequest(h, string(data))
	if response.Code != 200 {
		t.Fatalf("%s: HTTP %d %s", method, response.Code, response.Body.String())
	}
	var result map[string]any
	if err = json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func mcpCall(t *testing.T, h http.Handler, name string, args any) map[string]any {
	t.Helper()
	response := mcpRPC(t, h, "tools/call", map[string]any{"name": name, "arguments": args})
	if response["error"] != nil {
		t.Fatalf("%s: %v", name, response["error"])
	}
	result := response["result"].(map[string]any)
	if result["isError"] != false {
		t.Fatalf("%s: %v", name, result)
	}
	return result["structuredContent"].(map[string]any)
}
func mcpCode(t *testing.T, response map[string]any, want int) {
	t.Helper()
	err, ok := response["error"].(map[string]any)
	if !ok || err["code"] != float64(want) {
		t.Fatalf("wanted RPC error %d; got %v", want, response)
	}
}
func TestMCPInventoryCoversEveryBusinessRoute(t *testing.T) {
	routes := map[string]bool{}
	for _, name := range []string{"server.go", "platform.go"} {
		file, err := parser.ParseFile(token.NewFileSet(), name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(file, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok || len(call.Args) == 0 {
				return true
			}
			selector, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || selector.Sel.Name != "HandleFunc" {
				return true
			}
			literal, ok := call.Args[0].(*ast.BasicLit)
			if !ok || literal.Kind != token.STRING {
				return true
			}
			route, err := strconv.Unquote(literal.Value)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(route, " /api/v1/") || route == "GET /health" {
				routes[route] = true
			}
			return true
		})
	}
	names := map[string]bool{}
	for _, tool := range MCPToolInventory() {
		if names[tool.Name] {
			t.Fatalf("duplicate MCP name %s", tool.Name)
		}
		names[tool.Name] = true
		route := tool.Method + " " + tool.Path
		if !routes[route] {
			t.Fatalf("uncovered or duplicate MCP route %s", route)
		}
		delete(routes, route)
		if tool.Method != "GET" && !tool.Write && tool.Name != "rule_preview" && tool.Name != "import_preview" {
			t.Fatalf("mutation marked read-only: %+v", tool)
		}
	}
	if len(routes) != 0 {
		t.Fatalf("business HTTP routes missing from MCP: %v", routes)
	}
	if len(names) != 33 {
		t.Fatalf("review inventory size changed: %d", len(names))
	}
}
func TestMCPLifecycleAndProtocolErrors(t *testing.T) {
	var dispatches atomic.Int32
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dispatches.Add(1)
		writeJSON(w, 200, map[string]any{"ok": true})
	}), MCPOptions{AllowWrite: true})
	for _, version := range []string{MCPProtocolVersion, "2025-06-18", "2025-03-26", "future-unsupported"} {
		response := mcpRPC(t, h, "initialize", map[string]any{"protocolVersion": version, "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "test", "version": "1"}})
		want := version
		if version == "future-unsupported" {
			want = MCPProtocolVersion
		}
		if response["result"].(map[string]any)["protocolVersion"] != want {
			t.Fatal(response)
		}
	}
	response := mcpRequest(h, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if response.Code != 202 || response.Body.Len() != 0 {
		t.Fatal(response.Code, response.Body.String())
	}
	mcpRPC(t, h, "ping", map[string]any{})
	mcpCode(t, mcpRPC(t, h, "arbitrary/execute", map[string]any{}), -32601)
	mcpCode(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "shell", "arguments": map[string]any{}}), -32602)
	mcpCode(t, mcpRPC(t, h, "tools/list", map[string]any{"cursor": "not-issued"}), -32602)
	mcpCode(t, mcpRPC(t, h, "ping", map[string]any{"ignored": true}), -32602)
	mcpCode(t, mcpRPC(t, h, "initialize", map[string]any{"protocolVersion": MCPProtocolVersion}), -32602)
	for _, body := range []string{`{`, `[]`, `null`, `{"jsonrpc":"2.0","id":null,"method":"ping"}`, `{"jsonrpc":"1.0","id":1,"method":"ping"}`, `{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}`, `{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/call"}`, `{"jsonrpc":"2.0","id":1,"method":"ping"} {}`, `{"jsonrpc":"2.0","id":1,"result":{}}`} {
		if result := mcpRequest(h, body); result.Code != 400 {
			t.Fatalf("malformed request accepted: %s => %d %s", body, result.Code, result.Body.String())
		}
	}
	response = mcpRequest(h, `{"jsonrpc":"2.0","method":"tools/call","params":{"name":"configuration_apply","arguments":{}}}`)
	if response.Code != 400 || dispatches.Load() != 0 {
		t.Fatal("notification executed a business operation")
	}
}
func TestMCPReadOnlyAndPermissionIntersection(t *testing.T) {
	var calls atomic.Int32
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	for _, options := range []MCPOptions{{}, {AllowWrite: true, Authorize: func(_ *http.Request, write bool) bool { return !write }}} {
		h := newFixtureMCPHandler(api, options)
		listed := mcpRPC(t, h, "tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any)
		for _, raw := range listed {
			tool := raw.(map[string]any)
			if tool["annotations"].(map[string]any)["readOnlyHint"] != true {
				t.Fatal("write advertised to reader", tool)
			}
		}
		mcpCall(t, h, "points_list", map[string]any{})
		mcpCode(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "configuration_apply", "arguments": map[string]any{}}), -32003)
	}
	if calls.Load() != 2 {
		t.Fatal("denied write was dispatched")
	}
	h := newFixtureMCPHandler(api, MCPOptions{AllowWrite: true, Authorize: func(_ *http.Request, _ bool) bool { return false }})
	if result := mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); result.Code != 403 {
		t.Fatal("denied read accepted")
	}
}
func TestMCPHTTPGuardsAndBounds(t *testing.T) {
	var calls atomic.Int32
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		writeJSON(w, 200, map[string]any{"ok": true})
	}), MCPOptions{})
	tests := []struct {
		name, method, key, value string
		status                   int
	}{
		{"get", "GET", "", "", 405}, {"delete", "DELETE", "", "", 405},
		{"origin", "POST", "Origin", "http://evil.test", 403}, {"get origin", "GET", "Origin", "http://evil.test", 403},
		{"version", "POST", "MCP-Protocol-Version", "unsupported", 400}, {"content type", "POST", "Content-Type", "text/plain", 415},
		{"accept", "POST", "Accept", "application/json", 406},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(test.method, "http://127.0.0.1/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Accept", "application/json, text/event-stream")
			if test.key != "" {
				request.Header.Set(test.key, test.value)
			}
			response := httptest.NewRecorder()
			h.ServeHTTP(response, request)
			if response.Code != test.status {
				t.Fatalf("%d %s", response.Code, response.Body.String())
			}
		})
	}
	response := mcpRequest(h, strings.Repeat(" ", MaxMCPRequestBytes+1))
	if response.Code != 413 {
		t.Fatalf("large request: %d", response.Code)
	}
	deep := strings.Repeat("[", 34) + `0` + strings.Repeat("]", 34)
	if result := mcpRequest(h, deep); result.Code != 400 {
		t.Fatal("unbounded depth accepted")
	}
	if calls.Load() != 0 {
		t.Fatal("guarded request dispatched")
	}
	bounded := &mcpResponseWriter{header: make(http.Header), limit: 8}
	if _, err := bounded.Write([]byte("123456789")); err == nil || !bounded.overflow || bounded.body.Len() != 0 {
		t.Fatal("response bound ignored")
	}
}
func TestMCPStrictArgumentsAndNoArbitraryDispatch(t *testing.T) {
	var calls atomic.Int32
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); writeJSON(w, 200, map[string]any{}) }), MCPOptions{AllowWrite: true})
	for _, test := range []struct{ name, args string }{
		{"points_list", `{"path":"/etc/passwd"}`}, {"points_create", `{"station":"A","name":"x","data_type":"FLOAT","source_type":"manual","shell":"id"}`},
		{"points_update", `{"id":"x","point":{"station":"A","name":"x","data_type":"FLOAT","source_type":"manual","extra":1}}`},
		{"point_write", `{"command_id":"abcdefgh","point_id":"x","version":"v"}`}, {"point_write", `{"command_id":"abcdefgh","point_id":"x","version":"v","value":null}`},
		{"point_sample", `{"id":"x","sample":{"value":{}}}`}, {"history_query", `{"limit":5001}`}, {"history_query", `{"limit":1.5}`},
		{"configuration_apply", `{"force":true}`}, {"sources_save", `{"items":[{"id":"x","name":"x","broker":"tcp://localhost:1883","topic":"x","protocol":"generic","password":"secret"}]}`},
		{"export_download", `{"id":"x","max_bytes":1048577}`}, {"export_download", `{"id":".."}`},
		{"import_upload", `{"filename":"../../a.csv","data_base64":"YQ=="}`}, {"import_upload", `{"filename":"a.csv","data_base64":"not base64"}`},
		{"import_upload", `{"filename":"a.exe","data_base64":"YQ=="}`},
	} {
		response := mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"`+test.name+`","arguments":`+test.args+`}}`)
		var parsed map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &parsed); err != nil {
			t.Fatal(err)
		}
		mcpExpectToolError(t, parsed)
	}
	if calls.Load() != 0 {
		t.Fatalf("%d invalid calls reached business handlers", calls.Load())
	}
}
func TestMCPPointScalingStorageAndRulesUseSameServices(t *testing.T) {
	api, _, engine := platform(t)
	h := newFixtureMCPHandler(api, MCPOptions{AllowWrite: true})
	point := mcpCall(t, h, "points_create", map[string]any{"station": "A", "name": "pressure", "data_type": "FLOAT", "source_type": "manual", "scale_factor": 2, "offset": 10, "writable": true})
	id := point["id"].(string)
	version := mcpCall(t, h, "configuration_apply", map[string]any{})["version"].(string)
	mcpCall(t, h, "point_sample", map[string]any{"id": id, "sample": map[string]any{"value": 5}})
	state := mcpCall(t, h, "runtime_get", map[string]any{})
	sample := state["values"].([]any)[0].(map[string]any)
	if sample["value"] != float64(20) || sample["raw"] != float64(5) {
		t.Fatal("scaling bypassed", sample)
	}
	mcpCall(t, h, "point_write_capability", map[string]any{"id": id})
	result := mcpCall(t, h, "point_write", map[string]any{"command_id": "mcp-command-1", "point_id": id, "version": version, "value": 14})
	if result["state"] != "readback_confirmed" {
		t.Fatal(result)
	}
	mcpCall(t, h, "command_get", map[string]any{"id": "mcp-command-1"})
	mcpCall(t, h, "storage_save", map[string]any{"station": "A", "policy": map[string]any{"enabled": false, "interval_ms": 500, "retention_days": 20}})
	mcpCall(t, h, "storage_snapshot", map[string]any{"station": "A"})
	history := mcpCall(t, h, "history_query", map[string]any{"station": "A", "limit": 1})
	if len(history["items"].([]any)) != 1 {
		t.Fatal(history)
	}
	mcpCall(t, h, "history_catalog", map[string]any{"station": "A"})
	rule := map[string]any{"id": "mcp-rule", "name": "snapshot when pressure positive", "enabled": false, "logic": "and", "conditions": []any{map[string]any{"point_id": id, "op": ">", "value": 0}}, "hold_ms": 0, "cooldown_ms": 200, "trigger": "rising", "actions": []any{map[string]any{"type": "snapshot"}}}
	before := request(api, "GET", "/api/v1/executions", "").Body.String()
	mcpCall(t, h, "rule_preview", rule)
	after := request(api, "GET", "/api/v1/executions", "").Body.String()
	if before != after {
		t.Fatal("preview executed rule")
	}
	mcpCall(t, h, "rules_save", map[string]any{"items": []any{rule}})
	mcpCall(t, h, "executions_list", map[string]any{})
	rule["actions"] = []any{map[string]any{"type": "shell", "script": "exit 0"}}
	mcpExpectToolError(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "rule_preview", "arguments": rule}))
	if engine.Snapshot()["version"] != version {
		t.Fatal("preview changed runtime version")
	}
	mcpCall(t, h, "points_update", map[string]any{"id": id, "point": map[string]any{"station": "A", "name": "pressure", "data_type": "FLOAT", "source_type": "manual", "scale_factor": -2, "offset": 35, "writable": true}})
	mcpCall(t, h, "configuration_apply", map[string]any{})
	mcpCall(t, h, "point_sample", map[string]any{"id": id, "sample": map[string]any{"value": 10}})
	state = mcpCall(t, h, "runtime_get", map[string]any{})
	if state["values"].([]any)[0].(map[string]any)["value"] != float64(15) {
		t.Fatal("negative scaling lost")
	}
	old := mcpCall(t, h, "history_query", map[string]any{"station": "A"})
	if old["items"].([]any)[0].(map[string]any)["value"] != float64(14) {
		t.Fatal("history was rescaled")
	}
}
func TestMCPImportExportRoundTripAndChunking(t *testing.T) {
	api, _, _ := platform(t)
	h := newFixtureMCPHandler(api, MCPOptions{AllowWrite: true})
	data := "time,value\n2026-10-01T00:00:00Z,42\n2026-10-01T00:00:01Z,43\n"
	upload := mcpCall(t, h, "import_upload", map[string]any{"filename": "readings.csv", "data_base64": base64.StdEncoding.EncodeToString([]byte(data))})
	mapping := map[string]any{"session_id": upload["session_id"], "sheet": "CSV", "time_column": 0, "value_column": 1, "header": true, "station": "imported", "name": "temperature", "unit": "C"}
	preview := mcpCall(t, h, "import_preview", mapping)
	if preview["count"] != float64(2) {
		t.Fatal(preview)
	}
	mcpCall(t, h, "import_commit", mapping)
	mcpCall(t, h, "import_commit", mapping) // same mapping remains idempotent
	history := mcpCall(t, h, "history_query", map[string]any{"station": "imported"})
	if len(history["items"].([]any)) != 2 {
		t.Fatal("import not idempotent", history)
	}
	job := mcpCall(t, h, "export_create", map[string]any{"station": "imported", "format": "csv", "before": history["boundary"]})
	deadline := time.Now().Add(5 * time.Second)
	for {
		jobs := mcpCall(t, h, "jobs_list", map[string]any{})["items"].([]any)
		if len(jobs) == 1 && jobs[0].(map[string]any)["state"] == "completed" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("export did not complete", jobs)
		}
		time.Sleep(10 * time.Millisecond)
	}
	var downloaded bytes.Buffer
	offset := float64(0)
	for {
		chunk := mcpCall(t, h, "export_download", map[string]any{"id": job["id"], "offset": offset, "max_bytes": 17})
		payload, err := base64.StdEncoding.DecodeString(chunk["data_base64"].(string))
		if err != nil {
			t.Fatal(err)
		}
		if len(payload) > 17 || chunk["offset"] != offset {
			t.Fatal("invalid chunk", chunk)
		}
		downloaded.Write(payload)
		offset = chunk["next_offset"].(float64)
		if chunk["eof"] == true {
			if float64(downloaded.Len()) != chunk["total_bytes"] {
				t.Fatal("length mismatch")
			}
			break
		}
	}
	if !strings.Contains(downloaded.String(), "42") || !strings.Contains(downloaded.String(), "43") {
		t.Fatal(downloaded.String())
	}
	mcpCall(t, h, "job_delete", map[string]any{"id": job["id"]})
	failed := mcpRPC(t, h, "tools/call", map[string]any{"name": "export_download", "arguments": map[string]any{"id": job["id"]}})
	if failed["result"].(map[string]any)["isError"] != true {
		t.Fatal("missing file returned success")
	}
}

func TestMCPRangePreventsWholeFileBuffering(t *testing.T) {
	path := t.TempDir() + "/large.csv"
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = file.Truncate(5 * MaxMCPDownloadBytes); err != nil {
		t.Fatal(err)
	}
	file.Close()
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/api/v1/jobs/job/file" || r.Header.Get("Range") == "" {
			t.Fatal("uncontrolled file request", r.URL)
		}
		http.ServeFile(w, r, path)
	})
	h := newFixtureMCPHandler(api, MCPOptions{})
	result := mcpCall(t, h, "export_download", map[string]any{"id": "job"})
	if result["total_bytes"] != float64(5*MaxMCPDownloadBytes) || result["next_offset"] != float64(MaxMCPDownloadBytes) || result["eof"] != false {
		t.Fatal(result)
	}
}
func TestMCPIdentityEscapingAndContextPreservation(t *testing.T) {
	type contextKey struct{}
	api := http.NewServeMux()
	api.HandleFunc("GET /api/v1/commands/{id}", func(w http.ResponseWriter, r *http.Request) {
		if r.Context().Value(contextKey{}) != "principal" {
			t.Error("lost authorization context")
		}
		writeJSON(w, 200, map[string]string{"id": r.PathValue("id")})
	})
	h := newFixtureMCPHandler(api, MCPOptions{})
	for _, id := range []string{"../sources/x/connect", "a?x=1#test", "a%2Fb", "hello/there"} {
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{"name": "command_get", "arguments": map[string]any{"id": id}}})
		req := httptest.NewRequest("POST", "http://127.0.0.1/mcp", bytes.NewReader(data)).WithContext(context.WithValue(context.Background(), contextKey{}, "principal"))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		response := httptest.NewRecorder()
		h.ServeHTTP(response, req)
		var parsed map[string]any
		json.Unmarshal(response.Body.Bytes(), &parsed)
		result, ok := parsed["result"].(map[string]any)
		if !ok || result["isError"] != false || result["structuredContent"].(map[string]any)["id"] != id {
			t.Fatalf("escaped identity changed route or value: %s => %s", id, response.Body.String())
		}
	}
}
func TestMCPConcurrentRequestsBounded(t *testing.T) {
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-release
		writeJSON(w, 200, map[string]any{})
	}), MCPOptions{})
	done := make(chan struct{}, 4)
	for i := 0; i < 4; i++ {
		go func() {
			mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"points_list"}}`)
			done <- struct{}{}
		}()
	}
	for i := 0; i < 4; i++ {
		<-started
	}
	response := mcpRequest(h, `{"jsonrpc":"2.0","id":2,"method":"ping"}`)
	close(release)
	for i := 0; i < 4; i++ {
		<-done
	}
	if response.Code != 429 || response.Header().Get("Retry-After") == "" {
		t.Fatalf("unbounded concurrency: %d", response.Code)
	}
}
func ExampleNewMCPHandler() {
	api := http.NewServeMux() // Supply the actual PlatformHandler in production.
	mux := http.NewServeMux()
	mux.Handle("/mcp", NewMCPHandler(api, MCPOptions{}))
	mux.Handle("/", api)
	// The caller then wraps mux in the shared Auth.Handler. No listener is opened.
	fmt.Println(len(MCPToolInventory()))
	// Output: 33
}

func TestMCPHTTPSOriginPreservedForMutationAndReadOnlyPreview(t *testing.T) {
	api, ps, engine := platform(t)
	created, err := ps.Create(points.CreateInput{Station: "A", Name: "test", DataType: "FLOAT", SourceType: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = engine.Apply(); err != nil {
		t.Fatal(err)
	}
	h := newFixtureMCPHandler(api, MCPOptions{AllowWrite: true})
	calls := []map[string]any{
		{"name": "point_sample", "arguments": map[string]any{"id": created.ID, "sample": map[string]any{"value": 3}}},
		{"name": "rule_preview", "arguments": map[string]any{"id": "preview", "name": "preview", "enabled": false, "logic": "and", "conditions": []any{map[string]any{"point_id": created.ID, "op": ">", "value": 1}}, "hold_ms": 0, "cooldown_ms": 200, "trigger": "rising", "actions": []any{map[string]any{"type": "snapshot"}}}},
	}
	for _, call := range calls {
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": call})
		req := httptest.NewRequest("POST", "https://127.0.0.1/mcp", bytes.NewReader(data))
		req.Header.Set("Origin", "https://127.0.0.1")
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		response := httptest.NewRecorder()
		h.ServeHTTP(response, req)
		var parsed map[string]any
		if err = json.Unmarshal(response.Body.Bytes(), &parsed); err != nil {
			t.Fatal(err)
		}
		result, ok := parsed["result"].(map[string]any)
		if !ok || result["isError"] != false || result["structuredContent"].(map[string]any)["error"] != nil {
			t.Fatalf("HTTPS origin lost for %s: %s", call["name"], response.Body.String())
		}
	}
}

func TestMCPBoundedConditionalActionSequence(t *testing.T) {
	api, _, _ := platform(t)
	h := newFixtureMCPHandler(api, MCPOptions{AllowWrite: true})
	point := mcpCall(t, h, "points_create", map[string]any{"station": "A", "name": "setpoint", "data_type": "FLOAT", "source_type": "manual", "writable": true})
	id := point["id"]
	mcpCall(t, h, "configuration_apply", map[string]any{})
	mcpCall(t, h, "point_sample", map[string]any{"id": id, "sample": map[string]any{"value": 5}})
	actions := []any{map[string]any{"type": "write", "point_id": id, "value": 7}, map[string]any{"type": "snapshot"}, map[string]any{"type": "storage_start"}, map[string]any{"type": "storage_stop"}}
	rule := map[string]any{"id": "mcp-sequence", "name": "bounded actions", "station": "A", "enabled": true, "logic": "and", "conditions": []any{map[string]any{"point_id": id, "op": ">", "value": 1}}, "hold_ms": 0, "cooldown_ms": 200, "trigger": "rising", "actions": actions}
	preview := mcpCall(t, h, "rule_preview", rule)
	if preview["matches"] != true || preview["side_effects"] != false {
		t.Fatal(preview)
	}
	if logs := mcpCall(t, h, "executions_list", map[string]any{})["items"].([]any); len(logs) != 0 {
		t.Fatal("preview ran enabled actions")
	}
	mcpCall(t, h, "rules_save", map[string]any{"items": []any{rule}})
	deadline := time.Now().Add(3 * time.Second)
	for {
		logs := mcpCall(t, h, "executions_list", map[string]any{})["items"].([]any)
		var log map[string]any
		for _, entry := range logs {
			item := entry.(map[string]any)
			if item["type"] == "rule" && item["rule_id"] == "mcp-sequence" {
				log = item
				break
			}
		}
		if log != nil {
			steps := log["results"].([]any)
			if len(steps) != 4 || steps[0].(map[string]any)["state"] != "readback_confirmed" {
				t.Fatal(log)
			}
			for _, step := range steps[1:] {
				if step.(map[string]any)["state"] != "completed" {
					t.Fatal(log)
				}
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("conditional sequence did not execute")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if policy := mcpCall(t, h, "storage_get", map[string]any{"station": "A"}); policy["enabled"] != false {
		t.Fatal("storage_stop did not complete", policy)
	}
	if history := mcpCall(t, h, "history_query", map[string]any{"station": "A"}); len(history["items"].([]any)) != 1 {
		t.Fatal("snapshot sequence did not store exactly one frame", history)
	}
	actions[0] = map[string]any{"type": "write", "point_id": id}
	mcpExpectToolError(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "rule_preview", "arguments": rule}))
	rule["actions"] = make([]any, 17)
	for i := range rule["actions"].([]any) {
		rule["actions"].([]any)[i] = map[string]any{"type": "snapshot"}
	}
	mcpExpectToolError(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "rule_preview", "arguments": rule}))
}

func TestMCPInvalidDownstreamJSONIsError(t *testing.T) {
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("not json")) }), MCPOptions{})
	result := mcpRPC(t, h, "tools/call", map[string]any{"name": "points_list"})["result"].(map[string]any)
	if result["isError"] != true {
		t.Fatal("invalid JSON represented as success", result)
	}
}

func mcpExpectToolError(t *testing.T, response map[string]any) {
	t.Helper()
	result, ok := response["result"].(map[string]any)
	if !ok || response["error"] != nil || result["isError"] != true {
		t.Fatalf("wanted tool execution error; got %v", response)
	}
}
func TestMCPRejectsLocalDNSRebinding(t *testing.T) {
	h := newFixtureMCPHandler(http.NotFoundHandler(), MCPOptions{DevOrigin: "http://dev.test:8080"})
	for _, host := range []string{"attacker.example", "attacker.example:18080", "localhost.attacker.example", "127.0.0.1:0", "127.0.0.1:99999", "user@localhost", "127.0.0.1:"} {
		req := httptest.NewRequest("POST", "http://127.0.0.1/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
		req.Host = host
		req.Header.Set("Origin", "http://"+host)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != 403 {
			t.Fatalf("rebound host accepted: %s => %d", host, w.Code)
		}
	}
	for _, host := range []string{"localhost", "127.0.0.1:18080", "[::1]:18080"} {
		req := httptest.NewRequest("POST", "http://"+host+"/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
		req.Header.Set("Origin", "http://"+host)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != 200 {
			t.Fatalf("valid local host rejected: %s => %d", host, w.Code)
		}
	}
}
func TestMCPRulePreviewSeparatesUnknownQualityAndInvalidDefinition(t *testing.T) {
	api, ps, engine := platform(t)
	point, err := ps.Create(points.CreateInput{Station: "A", Name: "missing sample", DataType: "FLOAT", SourceType: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = engine.Apply(); err != nil {
		t.Fatal(err)
	}
	h := newFixtureMCPHandler(api, MCPOptions{})
	rule := map[string]any{"id": "preview", "name": "preview", "enabled": false, "logic": "and", "conditions": []any{map[string]any{"point_id": point.ID, "op": ">", "value": 0}}, "hold_ms": 0, "cooldown_ms": 200, "trigger": "rising", "actions": []any{map[string]any{"type": "snapshot"}}}
	result := mcpCall(t, h, "rule_preview", rule)
	if result["known"] != false || result["side_effects"] != false {
		t.Fatal(result)
	}
	rule["conditions"] = []any{map[string]any{"point_id": "does-not-exist", "op": ">", "value": 0}}
	mcpExpectToolError(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "rule_preview", "arguments": rule}))
}

func TestMCPPreservesExactIntegerResults(t *testing.T) {
	h := newFixtureMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"qid":9223372036854775806}`))
	}), MCPOptions{})
	response := mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"command_get","arguments":{"id":"large-qid"}}}`)
	if response.Code != 200 || !strings.Contains(response.Body.String(), `"qid":9223372036854775806`) || strings.Contains(response.Body.String(), `"isError":true`) {
		t.Fatalf("large integer rounded: %s", response.Body.String())
	}
}

package server

import (
	"bufio"
	"context"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestIdentityHTTPScopesMCPAndRevokedStream(t *testing.T) {
	raw, ps, engine := platform(t)
	a, e := ps.Create(points.CreateInput{Station: "A", Name: "public-A", SourceType: "manual", DataType: "FLOAT"})
	if e != nil {
		t.Fatal(e)
	}
	b, e := ps.Create(points.CreateInput{Station: "B", Name: "private-B", SourceType: "manual", DataType: "FLOAT"})
	if e != nil {
		t.Fatal(e)
	}
	engine.Apply()
	engine.Manual(a.ID, 10.0)
	engine.Manual(b.ID, 20.0)
	for _, station := range []string{"A", "B"} {
		d := process.Document{SchemaVersion: 1, ID: "screen-" + station, Name: "drawing-" + station, Station: station, Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}}
		data, _ := json.Marshal(d)
		if w := request(raw, "PUT", "/api/v1/screens/"+d.ID, string(data)); w.Code != 200 {
			t.Fatal(w.Body)
		}
	}
	d := process.Document{SchemaVersion: 1, ID: "shared-map", Name: "Shared layout", Kind: "gis", Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}, GIS: &process.GISConfig{Stations: []process.GISStation{{ID: "marker", Name: "Static marker", Longitude: 122, Latitude: 39, TargetScreenID: "screen-B", Bindings: map[string]string{"primary_supply": a.ID, "secondary_supply": b.ID}}}}}
	data, _ := json.Marshal(d)
	if w := request(raw, "PUT", "/api/v1/screens/shared-map", string(data)); w.Code != 200 {
		t.Fatal(w.Body)
	}
	if w := request(raw, "PUT", "/api/v1/navigation", `{"revision":0,"enabled":true,"nodes":[{"id":"a","label":"allowed","screen_id":"screen-A"},{"id":"b","label":"private-menu-B","screen_id":"screen-B"}]}`); w.Code != 200 {
		t.Fatal(w.Body)
	}
	now := time.Now()
	engine.Store.Append(context.Background(), []storage.Sample{{PointID: a.ID, Station: "A", Name: "public-A", Value: 10.0, Raw: 10.0, Quality: "good", SourceTime: now, ReceivedTime: now}, {PointID: b.ID, Station: "B", Name: "private-B", Value: 20.0, Raw: 20.0, Quality: "good", SourceTime: now, ReceivedTime: now}})
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", "long test password for security")
	if e != nil {
		t.Fatal(e)
	}
	ids.RegisterStations([]string{"A", "B"})
	user, e := ids.Change(ids.Actor(owner), "", identity.Change{Username: "reader", Password: "long test password for security", Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")}, ScreenIDs: []string{"shared-map"}}})
	if e != nil {
		t.Fatal(e)
	}
	mux := http.NewServeMux()
	mux.Handle("/", raw)
	mux.Handle("/mcp", NewMCPHandler(raw, MCPOptions{AllowWrite: true}))
	srv := httptest.NewUnstartedServer(nil)
	origin := "http://" + srv.Listener.Addr().String()
	h, e := IdentityHandler(ids, IdentityOptions{Origin: origin, LocalSetup: true}, mux)
	if e != nil {
		t.Fatal(e)
	}
	srv.Config.Handler = h
	srv.Start()
	defer srv.Close()
	_, _, token, e := ids.Login(user.Username, "long test password for security", "test", true)
	if e != nil {
		t.Fatal(e)
	}
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json, text/event-stream")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, path := range []string{"/api/v1/points", "/api/v1/runtime", "/api/v1/history", "/api/v1/history/catalog"} {
		w := call("GET", path, "")
		if w.Code != 200 || strings.Contains(w.Body.String(), "private-B") || strings.Contains(w.Body.String(), b.ID) {
			t.Fatalf("scope %s: %d %s", path, w.Code, w.Body.String())
		}
	}
	for _, path := range []string{"/api/v1/screens?all=true", "/api/v1/navigation", "/api/v1/screens/shared-map"} {
		w := call("GET", path, "")
		if w.Code != 200 || strings.Contains(w.Body.String(), "screen-B") || strings.Contains(w.Body.String(), b.ID) || strings.Contains(w.Body.String(), "private-menu-B") {
			t.Fatal("screen/navigation leaked", path, w.Code, w.Body)
		}
	}
	if w := call("GET", "/api/v1/screens/screen-B", ""); w.Code != 403 {
		t.Fatal("direct screen bypass", w.Code)
	}
	for _, op := range [][2]string{{"POST", "/api/v1/points"}, {"PUT", "/api/v1/sources"}, {"POST", "/api/v1/apply"}, {"POST", "/api/v1/write"}, {"POST", "/api/v1/export"}, {"GET", "/api/v1/history?station=B"}, {"GET", "/api/v1/security/users"}} {
		if w := call(op[0], op[1], "{}"); w.Code != 403 {
			t.Fatalf("bypass %v: %d %s", op, w.Code, w.Body.String())
		}
	}
	rpc := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"configuration_apply","arguments":{}}}`
	if w := call("POST", "/mcp", rpc); w.Code != 200 || !strings.Contains(w.Body.String(), `"isError":true`) || !strings.Contains(w.Body.String(), "permission_denied") {
		t.Fatalf("MCP mutation bypass: %d %s", w.Code, w.Body.String())
	}
	rpc = `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"points_list","arguments":{}}}`
	if w := call("POST", "/mcp", rpc); w.Code != 200 || strings.Contains(w.Body.String(), b.ID) || !strings.Contains(w.Body.String(), a.ID) {
		t.Fatalf("MCP read scope: %d %s", w.Code, w.Body.String())
	}
	// Directly dispatched REST calls retain actor context, independently of MCP mutation opt-in.
	r := httptest.NewRequest("POST", "/api/v1/apply", nil)
	r = r.WithContext(authorization.WithActor(r.Context(), ids.Actor(user)))
	w := httptest.NewRecorder()
	raw.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("transport-independent dispatch bypass")
	}
	req, _ := http.NewRequest("GET", origin+"/api/v1/runtime/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, e := srv.Client().Do(req)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	reader := bufio.NewReader(resp.Body)
	line, e := reader.ReadString('\n')
	if e != nil || !strings.Contains(line, "runtime") {
		t.Fatal("missing initial stream")
	}
	_, e = ids.Change(ids.Actor(owner), user.ID, identity.Change{Username: user.Username, Version: user.Version, Disabled: true, Grants: user.Grants})
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan bool, 1)
	go func() {
		for {
			line, e := reader.ReadString('\n')
			if strings.Contains(line, "session-expired") {
				done <- true
				return
			}
			if e != nil {
				done <- false
				return
			}
		}
	}()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("stream failed without expiry")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("revoked stream kept running")
	}
	if call("GET", "/api/v1/runtime", "").Code != 401 {
		t.Fatal("revoked token survived")
	}
	_, _, token, e = ids.Login(owner.Username, "long test password for security", "test2", true)
	if e != nil {
		t.Fatal(e)
	}
	if w := call("POST", "/api/v1/points", `{"station":"A","name":"engineer-created","data_type":"FLOAT","source_type":"manual"}`); w.Code != 201 {
		t.Fatalf("engineer blocked %d %s", w.Code, w.Body.String())
	}
}

func TestIdentityRemoteRequiresMFAAndCookieCSRF(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", "long test password for security")
	if e != nil {
		t.Fatal(e)
	}
	srv := httptest.NewUnstartedServer(nil)
	origin := "https://" + srv.Listener.Addr().String()
	h, e := IdentityHandler(ids, IdentityOptions{Origin: origin}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if e != nil {
		t.Fatal(e)
	}
	srv.Config.Handler = h
	srv.StartTLS()
	defer srv.Close()
	code, data := integrationRequest(t, srv.Client(), origin, "POST", authLoginPath, `{"username":"owner","password":"long test password for security","issue_token":true}`, "")
	if code != 200 {
		t.Fatalf("login %d %s", code, data)
	}
	var result map[string]any
	json.Unmarshal(data, &result)
	if result["mfa_required"] != true {
		t.Fatal("remote MFA not required")
	}
	req, _ := http.NewRequest("GET", origin+"/api/v1/runtime", nil)
	req.Header.Set("Authorization", "Bearer "+result["bearer_token"].(string))
	resp, e := srv.Client().Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatal("password-only remote data access")
	}
	_, sess, token, e := ids.Login(owner.Username, "long test password for security", "cookie", false)
	if e != nil {
		t.Fatal(e)
	}
	req, _ = http.NewRequest("POST", origin+authLogoutPath, strings.NewReader("{}"))
	req.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: token})
	resp, e = srv.Client().Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatal("cookie mutation without CSRF")
	}
	req.Header.Set("X-CSRF-Token", sess.CSRF)
	req.Body, _ = req.GetBody()
	resp, e = srv.Client().Do(req)
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatal("logout blocked during enrollment")
	}
}

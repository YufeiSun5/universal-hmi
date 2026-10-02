package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func modeServer(api http.Handler, options MCPOptions, auth *Auth) (*MCPHandler, http.Handler) {
	mcp := NewMCPHandler(api, options)
	mux := http.NewServeMux()
	mux.Handle("/mcp", mcp)
	mux.Handle(MCPSettingsPath, mcp.SettingsHandler())
	mux.Handle("/", api)
	if auth == nil {
		return mcp, LocalAuthHandler(mux, options.DevOrigin)
	}
	return mcp, auth.Handler(mux)
}
func settingsRequest(h http.Handler, method, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
	origin := "http://127.0.0.1"
	if cookie != nil {
		origin = "https://hmi.example:18443"
	}
	r := httptest.NewRequest(method, origin+MCPSettingsPath, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if cookie != nil {
		r.AddCookie(cookie)
	}
	r.Header.Set("X-CSRF-Token", csrf)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func settingsBody(t *testing.T, w *httptest.ResponseRecorder, status int) map[string]any {
	t.Helper()
	if w.Code != status {
		t.Fatalf("want %d got %d: %s", status, w.Code, w.Body)
	}
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestMCPModesDefaultCeilingOffAndRecovery(t *testing.T) {
	for _, startup := range []bool{false, true} {
		t.Run(fmt.Sprint(startup), func(t *testing.T) {
			var writes atomic.Int32
			api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" {
					writes.Add(1)
				}
				writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi"})
			})
			_, h := modeServer(api, MCPOptions{AllowWrite: startup}, nil)
			state := settingsBody(t, settingsRequest(h, "GET", "", nil, ""), 200)
			if state["mode"] != "read_only" || state["effective_write_allowed"] != false || state["can_change_mode"] != true || state["can_enable_write"] != startup {
				t.Fatal(state)
			}
			mcpCode(t, mcpRPC(t, h, "tools/call", map[string]any{"name": "configuration_apply", "arguments": map[string]any{}}), -32003)
			state = settingsBody(t, settingsRequest(h, "PUT", `{"mode":"off","revision":1}`, nil, ""), 200)
			if state["mode"] != "off" || state["available_tool_count"] != float64(0) {
				t.Fatal(state)
			}
			if w := mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); w.Code != 503 || !strings.Contains(w.Body.String(), "mcp_disabled") {
				t.Fatal(w.Code, w.Body)
			}
			settingsBody(t, settingsRequest(h, "PUT", `{"mode":"read_only","revision":1}`, nil, ""), 409)
			state = settingsBody(t, settingsRequest(h, "PUT", `{"mode":"read_only","revision":2}`, nil, ""), 200)
			if state["mode"] != "read_only" {
				t.Fatal(state)
			}
			mcpCall(t, h, "health_get", map[string]any{})
			status := 403
			if startup {
				status = 200
			}
			state = settingsBody(t, settingsRequest(h, "PUT", `{"mode":"write","revision":3}`, nil, ""), status)
			if startup {
				if state["effective_write_allowed"] != true {
					t.Fatal(state)
				}
				mcpCall(t, h, "configuration_apply", map[string]any{})
			}
			expected := int32(0)
			if startup {
				expected = 1
			}
			if writes.Load() != expected {
				t.Fatal("mode changes mutated business state", writes.Load())
			}
			// A fresh process/adapter always returns to read-only even with startup opt-in.
			_, fresh := modeServer(api, MCPOptions{AllowWrite: true}, nil)
			if state := settingsBody(t, settingsRequest(fresh, "GET", "", nil, ""), 200); state["mode"] != "read_only" {
				t.Fatal(state)
			}
		})
	}
}

func TestMCPSettingsAuthenticationCSRFExpiryAndAccountPermissions(t *testing.T) {
	for _, writable := range []bool{false, true} {
		t.Run(fmt.Sprint(writable), func(t *testing.T) {
			a := newFixtureAuth(t, writable)
			_, h := modeServer(http.NotFoundHandler(), MCPOptions{AllowWrite: true, Authorize: func(r *http.Request, write bool) bool {
				p, ok := PrincipalFromContext(r.Context())
				return ok && (!write || p.AllowWrite)
			}}, a)
			cookie, session := fixtureLogin(t, a, false)
			csrf := session["csrf_token"].(string)
			state := settingsBody(t, settingsRequest(h, "GET", "", cookie, ""), 200)
			if state["can_change_mode"] != writable || state["can_enable_write"] != writable {
				t.Fatal(state)
			}
			settingsBody(t, settingsRequest(h, "PUT", `{"mode":"write","revision":1}`, cookie, "forged"), 403)
			code := 403
			if writable {
				code = 200
			}
			settingsBody(t, settingsRequest(h, "PUT", `{"mode":"write","revision":1}`, cookie, csrf), code)
			now := time.Now().Add(9 * time.Hour)
			a.now = func() time.Time { return now }
			settingsBody(t, settingsRequest(h, "GET", "", cookie, ""), 401)
			settingsBody(t, settingsRequest(h, "PUT", `{"mode":"off","revision":2}`, cookie, csrf), 401)
		})
	}
	// The controller never accepts a forged permission body/header or a missing principal.
	mcp := NewMCPHandler(http.NotFoundHandler(), MCPOptions{AllowWrite: true})
	settingsBody(t, settingsRequest(mcp.SettingsHandler(), "PUT", `{"mode":"write","revision":1}`, nil, ""), 403)
}

func TestMCPSettingsRejectForgedOriginTransportAndPayload(t *testing.T) {
	a := newFixtureAuth(t, true)
	_, h := modeServer(http.NotFoundHandler(), MCPOptions{AllowWrite: true}, a)
	cookie, session := fixtureLogin(t, a, false)
	for _, address := range []string{"https://evil.example", "http://hmi.example:18443", "https://127.0.0.1:18443"} {
		r := httptest.NewRequest("PUT", address+MCPSettingsPath, strings.NewReader(`{"mode":"write","revision":1}`))
		r.AddCookie(cookie)
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", session["csrf_token"].(string))
		r.Header.Set("X-Forwarded-Host", "hmi.example:18443")
		r.Header.Set("X-Forwarded-Proto", "https")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal(address, w.Code, w.Body)
		}
	}
	_, local := modeServer(http.NotFoundHandler(), MCPOptions{AllowWrite: true}, nil)
	for _, body := range []string{`{}`, `{"mode":"write"}`, `{"mode":"write","revision":0}`, `{"mode":"write","revision":1.5}`, `{"mode":"unknown","revision":1}`, `{"mode":"write","revision":1,"allow_write":true}`, `{"mode":"off","mode":"write","revision":1}`, `{"mode":"write","revision":1} {}`} {
		settingsBody(t, settingsRequest(local, "PUT", body, nil, ""), 400)
	}
	settingsBody(t, settingsRequest(local, "PUT", strings.Repeat("x", 1025), nil, ""), 413)
	for _, host := range []string{"evil.test", "localhost.evil.test"} {
		r := httptest.NewRequest("PUT", "http://"+host+MCPSettingsPath, strings.NewReader(`{"mode":"write","revision":1}`))
		r.Header.Set("Origin", "http://"+host)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		local.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal(host, w.Code)
		}
	}
	r := httptest.NewRequest("PUT", "http://127.0.0.1"+MCPSettingsPath, strings.NewReader(`{"mode":"write","revision":1}`))
	r.Header.Set("Origin", "http://evil.test")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	local.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross origin local mutation", w.Code)
	}
}

func TestMCPModeTransitionDrainsAdmittedDispatchAndConflicts(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	_, h := modeServer(api, MCPOptions{AllowWrite: true}, nil)
	settingsBody(t, settingsRequest(h, "PUT", `{"mode":"write","revision":1}`, nil, ""), 200)
	dispatched := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		dispatched <- mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"configuration_apply","arguments":{}}}`)
	}()
	<-entered
	changed := make(chan *httptest.ResponseRecorder, 1)
	go func() { changed <- settingsRequest(h, "PUT", `{"mode":"off","revision":2}`, nil, "") }()
	select {
	case w := <-changed:
		t.Fatal("mode completed before admitted dispatch", w.Code)
	case <-time.After(25 * time.Millisecond):
	}
	close(release)
	if w := <-dispatched; w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	settingsBody(t, <-changed, 200)
	if w := mcpRequest(h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); w.Code != 503 {
		t.Fatal(w.Code)
	}
	var wg sync.WaitGroup
	var changedCount atomic.Int32
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := settingsRequest(h, "PUT", `{"mode":"read_only","revision":3}`, nil, "")
			if w.Code == 200 {
				changedCount.Add(1)
			} else if w.Code != 409 && w.Code != 429 {
				t.Errorf("concurrent status %d", w.Code)
			}
		}()
	}
	wg.Wait()
	if changedCount.Load() != 1 {
		t.Fatal("stale writers changed mode", changedCount.Load())
	}
}

// The principal intersection is enforced by the transport itself, even if a
// composition accidentally omits the optional additional Authorize callback.
func TestMCPWriteRequiresPrincipalEvenWithoutCallback(t *testing.T) {
	var calls atomic.Int32
	h := NewMCPHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		writeJSON(w, 200, map[string]any{"ok": true})
	}), MCPOptions{AllowWrite: true})
	h.mode = MCPWrite // explicit isolated mode fixture, not a public control path
	body := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"configuration_apply","arguments":{}}}`
	for _, principal := range []*Principal{nil, {Username: "reader", AllowWrite: false}, {Username: "writer", AllowWrite: true}} {
		r := httptest.NewRequest("POST", "http://127.0.0.1/mcp", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json, text/event-stream")
		if principal != nil {
			r = r.WithContext(context.WithValue(r.Context(), principalKey{}, *principal))
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		denied := principal == nil || !principal.AllowWrite
		if w.Code != 200 || strings.Contains(w.Body.String(), `"code":-32003`) != denied {
			t.Fatal(w.Code, w.Body)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("principal permission was bypassed", calls.Load())
	}
}

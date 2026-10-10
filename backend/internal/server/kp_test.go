package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

func TestKPHTTPBusinessBoundaryAndEmbeddedShell(t *testing.T) {
	now := time.Now()
	s, e := kpbridge.New(kpbridge.Options{SourceID: "kp", WorkspaceID: "default", Now: func() time.Time { return now }, Grants: []kpbridge.Grant{{Subject: "A", UserID: "user-a", DisplayName: "A", Role: "viewer"}, {Subject: "B", UserID: "user-b", DisplayName: "B", Role: "operator"}}, Verifier: kpbridge.VerifyFunc(func(_ context.Context, _ string, b kpbridge.Bootstrap) (kpbridge.Identity, error) {
		return kpbridge.Identity{Subject: b.UserName, UserName: b.UserName}, nil
	})})
	if e != nil {
		t.Fatal(e)
	}
	dir := t.TempDir()
	if e = os.WriteFile(filepath.Join(dir, "index.html"), []byte(`<html><base href="/"></html>`), 0600); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(dir, "main.dart.js"), []byte("fixture"), 0600); e != nil {
		t.Fatal(e)
	}
	called := 0
	business := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called++
		p, ok := PrincipalFromContext(r.Context())
		if !ok || p.UserID == "" || p.Provider != "kp" || p.WorkspaceID != "default" {
			t.Errorf("invalid principal: %+v", p)
		}
		writeJSON(w, 200, map[string]any{"username": p.Username})
	})
	h, e := KPHandler(s, KPOptions{PublicOrigin: "http://127.0.0.1:18145", KPOrigins: []string{"http://127.0.0.1:11001"}, WebDir: dir, LocalTrial: true}, nil, business)
	if e != nil {
		t.Fatal(e)
	}
	call := func(method, path, body, token, origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18145"+path, strings.NewReader(body))
		r.RemoteAddr = "192.0.2.1:123"
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	parse := func(w *httptest.ResponseRecorder) map[string]any {
		t.Helper()
		if w.Code != 200 {
			t.Fatalf("status=%d %s", w.Code, w.Body)
		}
		var b map[string]any
		if json.Unmarshal(w.Body.Bytes(), &b) != nil {
			t.Fatal(w.Body)
		}
		return b
	}
	if w := call("GET", "/api/v1/points", "", "", ""); w.Code != 401 || called != 0 {
		t.Fatal(w.Code, called)
	}
	if w := call("GET", "/kp/", "", "", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `href="/kp/"`) || !strings.Contains(w.Header().Get("Content-Security-Policy"), "http://127.0.0.1:11001") || w.Header().Get("X-Frame-Options") != "" {
		t.Fatal(w.Code, w.Header(), w.Body)
	}
	if w := call("GET", "/kp/main.dart.js", "", "", ""); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if w := call("GET", "/kp/assets/", "", "", ""); w.Code != 404 {
		t.Fatal(w.Code)
	}
	if w := call("POST", "/api/v1/kp/bootstrap", `{"contextId":"a","loginVersion":"v","userName":"A"}`, "", "https://untrusted.invalid"); w.Code != 403 {
		t.Fatal(w.Code)
	}
	if w := call("POST", "/api/v1/kp/bootstrap", `{"contextId":"a","loginVersion":"v","userName":"A","unknown":1}`, "", ""); w.Code != 400 {
		t.Fatal(w.Code)
	}
	boot := parse(call("POST", "/api/v1/kp/bootstrap", `{"contextId":"a","loginVersion":"v","userName":"A"}`, "", "http://127.0.0.1:11001"))
	if boot["ok"] != true {
		t.Fatal(boot)
	}
	body, _ := json.Marshal(map[string]any{"ticket": boot["ticket"]})
	web := parse(call("POST", "/api/v1/web/redeem", string(body), "", ""))
	token := web["webToken"].(string)
	if w := call("GET", "/api/v1/runtime", "", token, ""); w.Code != 200 || called != 1 {
		t.Fatal(w.Code, called)
	}
	if w := call("POST", "/api/v1/write", `{}`, token, ""); w.Code != 403 || called != 1 {
		t.Fatal(w.Code, called)
	}
	if w := call("GET", "/api/v1/runtime", "", boot["bridgeToken"].(string), ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	parse(call("POST", "/api/v1/web/logout", `{}`, token, ""))
	if w := call("GET", "/api/v1/runtime", "", token, ""); w.Code != 401 || called != 1 {
		t.Fatal(w.Code, called)
	}
	if v := parse(call("GET", "/api/v1/web/status", "", token, "")); v["state"] != "logout_requested" {
		t.Fatal(v)
	}
	c := map[string]any{"contextId": "a", "loginVersion": "v", "bridgeToken": boot["bridgeToken"]}
	body, _ = json.Marshal(c)
	if p := parse(call("POST", "/api/v1/kp/poll", string(body), "", "")); p["command"] != "logout" {
		t.Fatal(p)
	}
	c["success"] = false
	body, _ = json.Marshal(c)
	parse(call("POST", "/api/v1/kp/logoff-result", string(body), "", ""))
	if v := parse(call("GET", "/api/v1/web/status", "", token, "")); v["state"] != "logout_requested" {
		t.Fatal(v)
	}
	c["success"] = true
	body, _ = json.Marshal(c)
	parse(call("POST", "/api/v1/kp/logoff-result", string(body), "", ""))
	if v := parse(call("POST", "/api/v1/web/logout", `{}`, token, "")); v["state"] != "closed" {
		t.Fatal(v)
	}
	// Expiry is checked for business requests even if no cleanup timer ran.
	boot = parse(call("POST", "/api/v1/kp/bootstrap", `{"contextId":"b","loginVersion":"v","userName":"B"}`, "", ""))
	body, _ = json.Marshal(map[string]any{"ticket": boot["ticket"]})
	web = parse(call("POST", "/api/v1/web/redeem", string(body), "", ""))
	token = web["webToken"].(string)
	if w := call("POST", "/api/v1/write", `{}`, token, ""); w.Code != 200 {
		t.Fatal(w.Code)
	}
	now = now.Add(30 * time.Second)
	if w := call("POST", "/api/v1/write", `{}`, token, ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
}

func TestKPNoVerifierAndNoLocalAuthBypass(t *testing.T) {
	s, e := NewKPService(KPConfig{SourceID: "kp", WorkspaceID: "default"}, false, nil)
	if e != nil {
		t.Fatal(e)
	}
	h, e := KPHandler(s, KPOptions{PublicOrigin: "https://hmi.example", KPOrigins: []string{"https://kp.example"}}, nil, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Fatal("unauthorized business") }))
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		method, path, body string
		want               int
	}{{"POST", "/api/v1/kp/bootstrap", `{"contextId":"a","loginVersion":"v","userName":"A"}`, 503}, {"GET", "/api/v1/points", "", 401}} {
		r := httptest.NewRequest(tc.method, "https://hmi.example"+tc.path, strings.NewReader(tc.body))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(w.Code, w.Body)
		}
	}
	for _, o := range []KPOptions{{PublicOrigin: "http://hmi.example", KPOrigins: []string{"https://kp.example"}}, {PublicOrigin: "http://hmi.example", LocalTrial: true, KPOrigins: []string{"http://127.0.0.1"}}, {PublicOrigin: "https://hmi.example", KPOrigins: []string{"*"}}} {
		if _, e := KPHandler(s, o, nil, http.NotFoundHandler()); e == nil {
			t.Fatal("accepted unsafe options")
		}
	}
}

func TestKPObservedIPIsMetadataNotAuthentication(t *testing.T) {
	s, e := NewKPService(KPConfig{SourceID: "kp", WorkspaceID: "default", Users: []kpbridge.Grant{{Subject: "A", UserID: "a", DisplayName: "A", Role: "viewer"}}}, true, nil)
	if e != nil {
		t.Fatal(e)
	}
	h, e := KPHandler(s, KPOptions{PublicOrigin: "http://127.0.0.1:18145", KPOrigins: []string{"http://127.0.0.1:11001"}, LocalTrial: true}, nil, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]any{"ok": true}) }))
	if e != nil {
		t.Fatal(e)
	}
	call := func(method, path, body, token, remote string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18145"+path, strings.NewReader(body))
		r.RemoteAddr = remote
		r.Header.Set("X-Forwarded-For", "203.0.113.66")
		r.Header.Set("Forwarded", "for=203.0.113.66")
		r.Header.Set("Cookie", "unrelated=shared-browser-cookie")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	parse := func(w *httptest.ResponseRecorder) map[string]any {
		t.Helper()
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
		var v map[string]any
		if json.Unmarshal(w.Body.Bytes(), &v) != nil {
			t.Fatal(w.Body)
		}
		return v
	}
	b := parse(call("POST", "/api/v1/kp/bootstrap", `{"contextId":"tab","loginVersion":"v","userName":"A"}`, "", "192.0.2.1:123"))
	data, _ := json.Marshal(map[string]any{"ticket": b["ticket"]})
	w := parse(call("POST", "/api/v1/web/redeem", string(data), "", "198.51.100.1:123"))
	if w["kpObservedIp"] != "192.0.2.1" || w["webObservedIp"] != "198.51.100.1" {
		t.Fatal(w)
	}
	// VPN or DHCP changes do not revoke a valid instance credential.
	if r := call("GET", "/api/v1/runtime", "", w["webToken"].(string), "198.51.100.2:123"); r.Code != 200 {
		t.Fatal(r.Code, r.Body)
	}
	if r := call("POST", "/api/v1/web/logout", "null", w["webToken"].(string), "198.51.100.2:123"); r.Code != 400 {
		t.Fatal(r.Code)
	}
	if r := call("GET", "/api/v1/runtime", "", "", "198.51.100.1:123"); r.Code != 401 {
		t.Fatal("same IP/cookie bypassed authentication", r.Code)
	}
}

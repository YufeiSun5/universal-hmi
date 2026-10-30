package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestLocalPasswordPolicyHTTPAndRemoteBoundary(t *testing.T) {
	s, err := identity.OpenDatabase(t.TempDir(), "", identity.Options{LocalPasswords: true})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	if _, err = IdentityHandler(s, IdentityOptions{Origin: "https://example.invalid"}, next); err == nil {
		t.Fatal("remote handler accepted local password policy")
	}
	origin := "http://127.0.0.1:18153"
	h, err := IdentityHandler(s, IdentityOptions{Origin: origin, LocalSetup: true}, next)
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Origin", origin)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	w := call("GET", "/api/v1/auth/session", "")
	var state map[string]any
	if err = json.Unmarshal(w.Body.Bytes(), &state); err != nil || state["password_min_length"] != float64(5) || state["setup_required"] != true {
		t.Fatalf("wrong session policy: %s", w.Body)
	}
	w = call("POST", "/api/v1/auth/setup", `{"username":"admin","password":"admin"}`)
	if w.Code != 200 {
		t.Fatalf("local setup: %d %s", w.Code, w.Body)
	}
	w = call("POST", "/api/v1/auth/login", `{"username":"admin","password":"admin","issue_token":true}`)
	if w.Code != 200 {
		t.Fatalf("local login: %d %s", w.Code, w.Body)
	}
}

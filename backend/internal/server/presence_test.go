package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestOnlineHTTPAuthenticationAndPeer(t *testing.T) {
	s, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner, err := s.Bootstrap("engineer", "online test long password")
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Change(s.Actor(owner), "", identity.Change{Username: "operator", Password: "online test long password", Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if err != nil {
		t.Fatal(err)
	}
	_, _, engineerToken, err := s.Login("engineer", "online test long password", "test", true)
	if err != nil {
		t.Fatal(err)
	}
	_, _, readerToken, err := s.Login("operator", "online test long password", "test2", true)
	if err != nil {
		t.Fatal(err)
	}
	h, err := IdentityHandler(s, IdentityOptions{Origin: "http://127.0.0.1:18080", LocalSetup: true}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	call := func(token, path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "http://127.0.0.1:18080"+path, nil)
		r.RemoteAddr = "127.0.0.1:45678"
		r.Header.Set("User-Agent", "Mozilla/5.0")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("", "/api/v1/auth/presence"); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(readerToken, "/api/v1/auth/presence"); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(readerToken, "/api/v1/security/online"); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
	w := call(engineerToken, "/api/v1/security/online")
	var snapshot identity.OnlineSnapshot
	if err := json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil || w.Code != 200 || snapshot.Connections != 2 || snapshot.Users != 2 {
		t.Fatalf("%d %s %v", w.Code, w.Body, err)
	}
	for _, row := range snapshot.Items {
		if row.IP != "127.0.0.1" {
			t.Fatal("incorrect peer", row)
		}
	}
	if identityActivity("/api/v1/auth/presence") || identityActivity("/api/v1/security/online") {
		t.Fatal("presence counts as user interaction")
	}
}

package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/networkaccess"
)

func TestLANPeerAndPublicRouteCannotBeSpoofed(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	gate := LANPeerHandler(next)
	for _, tc := range []struct {
		peer string
		want int
	}{{"192.168.1.2:90", 204}, {"10.0.0.5:99", 204}, {"203.0.113.9:88", 403}, {"127.0.0.1:9", 403}} {
		r := httptest.NewRequest("GET", "https://192.168.1.3:18443/", nil)
		r.RemoteAddr = tc.peer
		r.Header.Set("X-Forwarded-For", "192.168.1.2")
		w := httptest.NewRecorder()
		gate.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(tc, w.Code)
		}
	}
	public, e := PublicAccessHandler(next, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "192.168.0.0/16"}}})
	if e != nil {
		t.Fatal(e)
	}
	for _, method := range []string{"GET", "PUT"} {
		r := httptest.NewRequest(method, "https://192.168.1.3:18443/api/v1/security/network-access", nil)
		r.RemoteAddr = "192.168.1.2:9"
		w := httptest.NewRecorder()
		LANPeerHandler(public).ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal("network management exposed", method, w.Code)
		}
	}
}
func TestNetworkConfigurationRequiresLocalSessionAndCSRF(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	if _, e = ids.Bootstrap("owner", publicFixturePassword); e != nil {
		t.Fatal(e)
	}
	_, session, token, e := ids.Login("owner", publicFixturePassword, "test", false)
	if e != nil {
		t.Fatal(e)
	}
	svc := networkaccess.New(t.TempDir(), "https://203.0.113.1:9090", true, "")
	h, e := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true, NetworkAccess: svc}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		method, peer, csrf, credential string
		want                           int
	}{
		{"GET", "127.0.0.1:1", "", "", 401},
		{"GET", "127.0.0.1:1", "", token, 200},
		{"PUT", "127.0.0.1:1", "", token, 403},
		{"PUT", "192.168.1.2:1", session.CSRF, token, 403},
		{"PUT", "127.0.0.1:1", session.CSRF, token, 200},
		{"PUT", "127.0.0.1:1", session.CSRF, token, 409},
	} {
		r := httptest.NewRequest(tc.method, "http://127.0.0.1:12345/api/v1/security/network-access", strings.NewReader(`{"revision":0,"enabled":false,"address":"192.168.50.5","port":18443}`))
		r.RemoteAddr = tc.peer
		r.Header.Set("Origin", "http://127.0.0.1:12345")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", tc.csrf)
		if tc.credential != "" {
			r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: tc.credential})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(tc.method, tc.peer, w.Code, w.Body.String())
		}
	}
}

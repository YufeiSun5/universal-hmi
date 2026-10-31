package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func publicBoundaryFixture(t *testing.T, rules []PublicIPRule) (http.Handler, http.Handler) {
	t.Helper()
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Header().Set("X-Reached", "api"); w.WriteHeader(204) })
	static := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Reached", "static")
		w.WriteHeader(200)
	})
	h, err := PublicAccessHandler(api, PublicAccessOptions{WebAllowlist: rules, Static: static})
	if err != nil {
		t.Fatal(err)
	}
	return h, api
}
func publicBoundaryCall(h http.Handler, method, url, peer string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "https://203.0.113.5"+url, nil)
	r.RemoteAddr = peer
	r.Header.Set("Authorization", "Bearer synthetic-admin-token")
	r.Header.Set("X-Forwarded-For", "192.0.2.1")
	r.Header.Set("Forwarded", "for=192.0.2.1")
	r.Header.Set("X-Client-Channel", "android")
	r.Header.Set("X-Device-ID", "claimed-approved")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestPublicBoundaryPeerOnly(t *testing.T) {
	h, _ := publicBoundaryFixture(t, []PublicIPRule{{CIDR: "192.0.2.0/24"}, {CIDR: "2001:db8:1::/48"}, {CIDR: "198.51.100.1"}})
	for _, tc := range []struct {
		peer string
		ok   bool
	}{
		{"192.0.2.1:1234", true}, {"[::ffff:192.0.2.1]:1234", true}, {"[2001:db8:1::9]:1234", true}, {"198.51.100.1:1234", true},
		{"192.0.3.1:1234", false}, {"[2001:db8:2::9]:1234", false}, {"127.0.0.1:1234", false}, {"[fe80::1%eth0]:1234", false}, {"192.0.2.1", false}, {"invalid", false},
	} {
		t.Run(tc.peer, func(t *testing.T) {
			w := publicBoundaryCall(h, "GET", "/health", tc.peer)
			if (w.Code == 204) != tc.ok {
				t.Fatalf("status=%d body=%s", w.Code, w.Body)
			}
		})
	}
	empty, _ := publicBoundaryFixture(t, nil)
	if w := publicBoundaryCall(empty, "GET", "/", "192.0.2.1:1234"); w.Code != 403 {
		t.Fatal("empty policy allowed assets")
	}
}
func TestPublicBoundaryRejectsInvalidConfiguration(t *testing.T) {
	for _, cidr := range []string{"", "example.com", "192.0.2.1/33", "2001:db8::/129", "::ffff:192.0.2.1/120", "fe80::1%eth0"} {
		if _, err := PublicAccessHandler(http.NotFoundHandler(), PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: cidr}}}); err == nil {
			t.Fatalf("accepted %q", cidr)
		}
	}
	if _, err := PublicAccessHandler(nil, PublicAccessOptions{}); err == nil {
		t.Fatal("nil API accepted")
	}
}
func TestPublicBoundaryCapabilitiesNotHTTPVerb(t *testing.T) {
	h, local := publicBoundaryFixture(t, []PublicIPRule{{CIDR: "192.0.2.0/24"}})
	reads := []string{"GET /health", "GET /api/v1/auth/session", "POST /api/v1/auth/login", "POST /api/v1/auth/logout", "POST /api/v1/security/mfa/begin", "POST /api/v1/security/mfa/confirm", "HEAD /api/v1/points", "GET /api/v1/stations", "GET /api/v1/runtime", "GET /api/v1/runtime/events?ids=p1", "GET /api/v1/screens", "GET /api/v1/screens/a", "GET /api/v1/navigation", "GET /api/v1/equipment", "GET /api/v1/equipment/status", "GET /api/v1/equipment/a", "GET /api/v1/equipment/a/photos/b", "GET /api/v1/equipment-navigation", "GET /api/v1/external/screens", "GET /api/v1/external/screens/a/stations", "POST /api/v1/external/screens/a/query"}
	for _, spec := range reads {
		method, url, _ := strings.Cut(spec, " ")
		t.Run(spec, func(t *testing.T) {
			if w := publicBoundaryCall(h, method, url, "192.0.2.1:1234"); w.Code != 204 {
				t.Fatalf("read rejected %d %s", w.Code, w.Body)
			}
		})
	}
	denied := []string{"POST /api/v1/points", "PUT /api/v1/points/a", "POST /api/v1/write", "POST /api/v1/apply", "POST /api/v1/demo", "POST /api/v1/auth/setup", "GET /api/v1/security/users", "POST /api/v1/security/users", "POST /api/v1/security/mfa/reset", "GET /api/v1/sources", "POST /api/v1/sources/a/connect", "POST /api/v1/sources/a/disconnect", "POST /api/v1/import/commit", "POST /api/v1/export", "GET /api/v1/history", "GET /api/v1/jobs", "GET /api/v1/local/deployment", "GET /mcp", "POST /mcp", "GET /mobile", "GET /api", "GET /api/unknown", "GET /api/v1/equipment/a/photos", "GET /api/v1/equipment/a/photos/b/extra", "GET /api/v1/external/screens/a/query", "POST /api/v1/external/screens/a/stations", "POST /api/v1/external/screens/a/query/extra", "POST /index.html"}
	for _, spec := range denied {
		method, url, _ := strings.Cut(spec, " ")
		t.Run(spec, func(t *testing.T) {
			w := publicBoundaryCall(h, method, url, "192.0.2.1:1234")
			if w.Code < 400 || w.Header().Get("X-Reached") != "" {
				t.Fatalf("unapproved capability reached downstream %d", w.Code)
			}
		})
	}
	// Merely constructing a public wrapper does not alter the local handler.
	if w := publicBoundaryCall(local, "POST", "/api/v1/write", "127.0.0.1:1234"); w.Code != 204 {
		t.Fatal("local handler affected")
	}
}
func TestPublicBoundaryStaticIsolationAndCanonicalPaths(t *testing.T) {
	h, _ := publicBoundaryFixture(t, []PublicIPRule{{CIDR: "192.0.2.1"}})
	for _, url := range []string{"/", "/index.html", "/assets/font.woff", "/future-business-route"} {
		w := publicBoundaryCall(h, "GET", url, "192.0.2.1:1234")
		if w.Header().Get("X-Reached") != "static" {
			t.Fatal("static path dispatched to API", url, w.Code)
		}
	}
	for _, url := range []string{"/api//v1/points", "/api/v1/../v1/points", "/api/v1/screens/a%2fb", "/api/v1/screens/%2e%2e", "/api/v1/equipment/a/photos/b%2Fextra", "/api/v1/screens/a%5cb", "/mcp%2fanything"} {
		w := publicBoundaryCall(h, "GET", url, "192.0.2.1:1234")
		if w.Code != 403 || w.Header().Get("X-Reached") != "" {
			t.Fatalf("noncanonical path accepted %s %d", url, w.Code)
		}
	}
}

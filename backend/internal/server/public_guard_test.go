package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestPublicGuardWAFBanLoginAndLocalRecovery(t *testing.T) {
	s, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner, err := s.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	g, err := NewPublicGuard(s)
	if err != nil {
		t.Fatal(err)
	}
	called := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called++
		if r.URL.Path == authLoginPath {
			w.WriteHeader(401)
			return
		}
		if r.URL.Path == "/api/v1/runtime/events" {
			if _, ok := w.(http.Flusher); !ok {
				t.Error("SSE Flusher lost")
			}
		}
		io.Copy(w, r.Body)
	})
	h := g.Handler(next)
	call := func(path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "https://192.0.2.1"+path, strings.NewReader(body))
		r.RemoteAddr = "192.0.2.10:1234"
		r.Header.Set("User-Agent", "HMI-test")
		r.Header.Set("Accept", "application/json")
		if body != "" {
			r.Method = "POST"
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("/api/v1/points?q=%27%20OR%201%3D1%20--", ""); w.Code != 403 || called != 0 {
		t.Fatal(w.Code, called)
	}
	if w := call("/health", ""); w.Code != 403 || called != 0 {
		t.Fatal("ban not enforced", w.Code, called)
	}
	doc, err := s.PublicBans(s.Actor(owner))
	if err != nil || len(doc.Items) != 1 || doc.Items[0].Reason != "waf" {
		t.Fatal(doc, err)
	}
	if err := s.UnbanPublicPeer(s.Actor(owner), doc.Revision, "192.0.2.10"); err != nil {
		t.Fatal(err)
	}
	if w := call("/api/v1/runtime/events", ""); w.Code != 200 {
		t.Fatal("recovery/SSE failed", w.Code)
	}
	for i := 0; i < 5; i++ {
		if w := call(authLoginPath, `{"username":"x","password":"synthetic long password"}`); w.Code != 401 {
			t.Fatal("login failed before threshold", i, w.Code)
		}
	}
	if w := call("/health", ""); w.Code != 403 {
		t.Fatal("brute-force ban missing", w.Code)
	}
	// Constructing/using the public wrapper never changes a local handler.
	w := httptest.NewRecorder()
	next.ServeHTTP(w, httptest.NewRequest("POST", "http://127.0.0.1/api/v1/write", strings.NewReader("local")))
	if w.Code != 200 {
		t.Fatal("public ban affected local management")
	}
}

func TestPublicRateBudgetBoundedAndRecovers(t *testing.T) {
	now := time.Now()
	g := &PublicGuard{peers: map[netip.Addr]peerAttempts{}, now: func() time.Time { return now }}
	ip := netip.MustParseAddr("192.0.2.1")
	for i := 0; i < 240; i++ {
		if ok, _ := g.attempt(ip, false); !ok {
			t.Fatal(i)
		}
	}
	for i := 0; i < 10; i++ {
		ok, ban := g.attempt(ip, false)
		if ok || ban != (i == 9) {
			t.Fatal(i, ok, ban)
		}
	}
	now = now.Add(time.Second)
	if ok, _ := g.attempt(ip, false); !ok {
		t.Fatal("rate did not replenish")
	}
}

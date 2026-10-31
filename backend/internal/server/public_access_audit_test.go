package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func waitPublicEvents(t *testing.T, ids *identity.Service, actor authorization.Actor, match func([]identity.PublicAccessEvent) bool) []identity.PublicAccessEvent {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		p, err := ids.PublicAccessEvents(actor, 0, 200)
		if err != nil {
			t.Fatal(err)
		}
		if match(p.Items) {
			return p.Items
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("audit events not persisted before deadline")
	return nil
}
func TestPublicRequestAuditBoundsAndNoSecrets(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	if err = ids.InitPublicAccessAudit(); err != nil {
		t.Fatal(err)
	}
	approval := PublicIPApproval{Allowed: true, RuleID: "rule_a", OwnerLabel: "Shared NAT", OwnerUserID: owner.ID}
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { publicAuditUser(r, owner.ID); w.WriteHeader(200) })
	guarded, err := PublicAccessHandler(api, PublicAccessOptions{Evaluate: func(netip.Addr) PublicIPApproval { return approval }, Static: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })})
	if err != nil {
		t.Fatal(err)
	}
	h := PublicAccessAuditHandler(guarded, ids)
	call := func(method, path, peer string) {
		r := httptest.NewRequest(method, path, strings.NewReader("secret-password-body"))
		r.RemoteAddr = peer
		r.Header.Set("X-Forwarded-For", "secret-spoof-ip")
		r.Header.Set("X-User-ID", "secret-spoof-user")
		r.Header.Set("Authorization", "Bearer secret-token")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
	}
	call("GET", "/main.dart.js?secret-query", "192.0.2.4:1") // successful assets intentionally omitted
	call("GET", "/api/v1/screens/secret-screen-id?secret-query", "192.0.2.4:1")
	approval.OwnerLabel = "Changed label"
	call("POST", "/api/v1/write?secret-query", "192.0.2.4:1")
	approval.Allowed = false
	call("GET", "/private-secret-asset?secret-query", "192.0.2.4:1")
	events := waitPublicEvents(t, ids, ids.Actor(owner), func(v []identity.PublicAccessEvent) bool { return len(v) == 3 })
	raw, _ := json.Marshal(events)
	if strings.Contains(string(raw), "secret-") {
		t.Fatalf("sensitive input entered audit: %s", raw)
	}
	for _, v := range events {
		if v.IP != "192.0.2.4" || v.Channel != "public:web" {
			t.Fatal(v)
		}
	}
	if events[2].Route != "/api/v1/screens/{id}" || events[2].UserID != owner.ID || events[2].OwnerLabel != "Shared NAT" {
		t.Fatal("read attribution", events[2])
	}
	if events[1].Decision != "public_read_only" || events[1].UserID != "" || events[1].OwnerLabel != "Changed label" {
		t.Fatal("denied request attribution", events[1])
	}
	if events[0].Kind != "static_denied" || events[0].Route != "/static" || events[0].Decision != "public_ip_denied" || events[0].UserID != "" {
		t.Fatal(events[0])
	}
}
func TestPublicAuditRouteDoesNotRetainUnknownInput(t *testing.T) {
	for _, path := range []string{"/api/secret", "/api/v1/screens/a/secret", "/mcp/secret", "/secret?q=secret", "/api/v1/external/screens/secret/query"} {
		if got := publicAuditRoute(path); strings.Contains(got, "secret") {
			t.Fatalf("route retained data %q", got)
		}
	}
}

func TestPublicAuditManagementBounds(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, query, peer, channel string, actor authorization.Actor) int {
		r := httptest.NewRequest(method, "/api/v1/security/public-access/events"+query, nil)
		r.RemoteAddr = peer
		w := httptest.NewRecorder()
		publicAccessEventsAPI(w, r, ids, actor, identity.Session{Channel: channel})
		return w.Code
	}
	actor := ids.Actor(owner)
	if got := call("GET", "", "127.0.0.1:1", "", actor); got != 503 {
		t.Fatal("uninitialized audit", got)
	}
	if err = ids.InitPublicAccessAudit(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		method, query, peer, channel string
		want                         int
	}{
		{"GET", "", "127.0.0.1:1", "", 200}, {"GET", "?limit=0", "127.0.0.1:1", "", 400}, {"GET", "?limit=201", "127.0.0.1:1", "", 400}, {"GET", "?before=-1", "127.0.0.1:1", "", 400},
		{"GET", "", "198.51.100.1:1", "", 403}, {"GET", "", "127.0.0.1:1", "public:web", 403}, {"POST", "", "127.0.0.1:1", "", 405},
	} {
		if got := call(tc.method, tc.query, tc.peer, tc.channel, actor); got != tc.want {
			t.Fatalf("%+v got %d", tc, got)
		}
	}
	if got := call("GET", "", "127.0.0.1:1", "", authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}}}); got != 403 {
		t.Fatal("nonadmin audit", got)
	}
}

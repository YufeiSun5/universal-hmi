package server

import (
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestKPLinkedBearerWithOrdinaryWebCookie(t *testing.T) {
	for _, mode := range []string{"native", "trial"} {
		t.Run(mode, func(t *testing.T) {
			ids, err := identity.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer ids.Close()
			owner, err := ids.Bootstrap("owner", publicFixturePassword)
			if err != nil {
				t.Fatal(err)
			}
			viewer, err := ids.Change(ids.Actor(owner), "", identity.Change{Username: "kp-viewer", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
			if err != nil {
				t.Fatal(err)
			}
			_, _, cookieToken, err := ids.LoginChannel("owner", publicFixturePassword, "test", false, "public:web")
			if err != nil {
				t.Fatal(err)
			}
			_, _, ordinaryBearer, err := ids.LoginChannel("owner", publicFixturePassword, "test", true, "public:web")
			if err != nil {
				t.Fatal(err)
			}
			const kpToken = "fixture-kp-linked-token-1234567890123456789012"
			valid := true
			var link func(string, string, *x509.Certificate, func() bool) error = ids.LinkKPToken
			if mode == "trial" {
				link = ids.LinkKPTrial
			}
			if err := link(viewer.ID, kpToken, nil, func() bool { return valid }); err != nil {
				t.Fatal(err)
			}
			const origin = "https://hmi.test"
			actorID := ""
			h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				actor, ok := authorization.FromContext(r.Context())
				if !ok {
					t.Error("missing actor")
				}
				actorID = actor.ID
				if actor.ID == viewer.ID {
					if _, err := r.Cookie("__Host-hmi_identity"); err == nil {
						t.Error("downstream still sees conflicting Web identity")
					}
				}
				if c, err := r.Cookie("fixture_preference"); err != nil || c.Value != "keep" {
					t.Error("unrelated cookie lost")
				}
				w.WriteHeader(200)
			}))
			if err != nil {
				t.Fatal(err)
			}
			call := func(path, auth, cookie string) *httptest.ResponseRecorder {
				r := httptest.NewRequest("GET", origin+path, nil)
				if auth != "" {
					r.Header.Set("Authorization", auth)
				}
				if cookie != "" {
					r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: cookie})
				}
				r.AddCookie(&http.Cookie{Name: "fixture_preference", Value: "keep"})
				originalCookies := r.Header.Get("Cookie")
				w := httptest.NewRecorder()
				actorID = ""
				h.ServeHTTP(w, r)
				if r.Header.Get("Cookie") != originalCookies {
					t.Fatal("original request cookie mutated")
				}
				return w
			}
			for _, cookie := range []string{"", cookieToken, "stale-web-cookie"} {
				for _, path := range []string{"/api/v1/runtime", "/api/v1/runtime/events?protocol=delta&ids=", "/api/v1/screens"} {
					w := call(path, "Bearer "+kpToken, cookie)
					if w.Code != 200 || actorID != viewer.ID {
						t.Fatalf("KP %s with cookie=%t: HTTP %d %s; wrong identity=%t", path, cookie != "", w.Code, w.Body.String(), actorID != viewer.ID)
					}
					if len(w.Result().Cookies()) != 0 {
						t.Fatal("KP request changed ordinary cookie")
					}
				}
			}
			for _, auth := range []string{"Bearer " + ordinaryBearer, "Bearer forged-token", "Basic " + kpToken} {
				if w := call("/api/v1/runtime", auth, cookieToken); w.Code != 401 || actorID != "" {
					t.Fatal("unverified/ordinary mixed credentials accepted", w.Code)
				}
			}
			if w := call("/api/v1/runtime", "Bearer "+ordinaryBearer, ""); w.Code != 200 || actorID != owner.ID {
				t.Fatal("ordinary bearer changed")
			}
			if w := call("/api/v1/runtime", "", cookieToken); w.Code != 200 || actorID != owner.ID {
				t.Fatal("ordinary cookie changed")
			}
			valid = false
			if w := call("/api/v1/runtime", "Bearer "+kpToken, cookieToken); w.Code != 401 || actorID != "" {
				t.Fatal("revoked KP fell back to cookie")
			}
			if w := call("/api/v1/runtime", "", cookieToken); w.Code != 200 || actorID != owner.ID {
				t.Fatal("KP revocation revoked ordinary cookie")
			}
			if w := call("/api/v1/runtime", "Bearer "+kpToken, ""); w.Code != 401 || !strings.Contains(w.Body.String(), "authentication_required") {
				t.Fatal("revoked KP accepted")
			}
		})
	}
}

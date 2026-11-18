package server

import (
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestWebWorkspaceSessionsShareBrowser(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
		t.Fatal(err)
	}
	for _, separatePorts := range []bool{false, true} {
		name := "same-origin"
		if separatePorts {
			name = "same-host-two-ports"
		}
		t.Run(name, func(t *testing.T) {
			jar, _ := cookiejar.New(nil)
			type entry struct {
				origin    *url.URL
				workspace string
				handler   http.Handler
			}
			newEntry := func(origin, workspace string) entry {
				u, _ := url.Parse(origin)
				h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, LocalSetup: true}, http.NotFoundHandler())
				if err != nil {
					t.Fatal(err)
				}
				return entry{u, workspace, h}
			}
			dev := newEntry("http://127.0.0.1:18001", "developer")
			run := newEntry(dev.origin.String(), "runtime")
			if separatePorts {
				run = newEntry("http://127.0.0.1:18002", "developer") // Same default entry on another listener.
			}
			call := func(e entry, method, path, body, csrf string, want int) map[string]any {
				t.Helper()
				r := httptest.NewRequest(method, e.origin.String()+path, strings.NewReader(body))
				r.RemoteAddr = "127.0.0.1:10000"
				r.Header.Set("Origin", e.origin.String())
				r.Header.Set("Content-Type", "application/json")
				r.Header.Set("X-HMI-Workspace", e.workspace)
				r.Header.Set("X-CSRF-Token", csrf)
				for _, c := range jar.Cookies(e.origin) {
					r.AddCookie(c)
				}
				w := httptest.NewRecorder()
				e.handler.ServeHTTP(w, r)
				if w.Code != want {
					t.Fatalf("%s %s: got %d, want %d", e.workspace, path, w.Code, want)
				}
				jar.SetCookies(e.origin, w.Result().Cookies())
				var out map[string]any
				if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
					t.Fatal(err)
				}
				return out
			}
			body, _ := json.Marshal(map[string]string{"username": "owner", "password": publicFixturePassword})
			for _, pair := range [][2]entry{{dev, run}, {run, dev}} {
				a, b := pair[0], pair[1]
				first := call(a, "POST", authLoginPath, string(body), "", 200)["csrf_token"].(string)
				second := call(b, "POST", authLoginPath, string(body), "", 200)["csrf_token"].(string)
				if first == second {
					t.Fatal("expected separate login sessions")
				}
				if call(a, "GET", authSessionPath, "", "", 200)["csrf_token"] != first {
					t.Fatal("second login displaced the first page")
				}
				if call(b, "GET", authSessionPath, "", "", 200)["csrf_token"] != second {
					t.Fatal("refresh displaced the second page")
				}
				call(a, "POST", authLogoutPath, "{}", second, 403)
				call(a, "POST", authLogoutPath, "{}", first, 200)
				call(a, "GET", "/api/v1/auth/presence", "", "", 401)
				call(b, "GET", "/api/v1/auth/presence", "", "", 200)
				call(b, "POST", authLogoutPath, "{}", second, 200)
			}
		})
	}
}

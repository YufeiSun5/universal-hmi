package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

// Exercise the production guard and identity stack together. A normal LAN HTTP
// login must select the same bounded engineering document inspection as HTTPS.
func TestLANReportOpenAndEngineeringBodyWithGuard(t *testing.T) {
	for _, secure := range []bool{false, true} {
		t.Run(map[bool]string{false: "HTTP", true: "HTTPS"}[secure], func(t *testing.T) {
			ids, err := identity.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer ids.Close()
			if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
				t.Fatal(err)
			}
			origin := "http://192.168.50.5:18443"
			if secure {
				origin = "https://192.168.50.5:18443"
			}
			captchas := newLoginCaptchas()
			calls := 0
			raw, points, _ := platform(t)
			h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true, LANHTTP: !secure, LANDevelopment: true, captchas: captchas}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if strings.HasPrefix(r.URL.Path, "/api/v1/screens/") || r.URL.Path == "/api/v1/demo" {
					raw.ServeHTTP(w, r)
					return
				}
				w.WriteHeader(204)
			}))
			if err != nil {
				t.Fatal(err)
			}
			h, err = PublicAccessHandler(h, PublicAccessOptions{LANDevelopment: true, WebAllowlist: []PublicIPRule{{CIDR: "192.168.50.6"}}, Static: h})
			if err != nil {
				t.Fatal(err)
			}
			guard, err := NewLANDevelopmentGuard(ids)
			if err != nil {
				t.Fatal(err)
			}
			h = guard.Handler(h)
			call := func(method, path, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
				r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
				r.RemoteAddr = "192.168.50.6:1234"
				r.Header.Set("Origin", origin)
				r.Header.Set("User-Agent", "Mozilla/5.0")
				r.Header.Set("Content-Type", "application/json")
				if cookie != nil {
					r.AddCookie(cookie)
				}
				if csrf != "" {
					r.Header.Set("X-CSRF-Token", csrf)
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				return w
			}
			b, _ := json.Marshal(map[string]any{"username": "owner", "password": publicFixturePassword, "captcha_id": seedLoginCaptcha(captchas, "192.168.50.6"), "captcha_answer": "12345"})
			w := call("POST", authLoginPath, string(b), nil, "")
			if w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			cookies := w.Result().Cookies()
			if len(cookies) != 1 {
				t.Fatal("missing cookie")
			}
			var session struct {
				CSRF string `json:"csrf_token"`
			}
			json.Unmarshal(w.Body.Bytes(), &session)
			for _, path := range []string{"/total-reports/?development=true", "/api/v1/total-reports"} {
				if w = call("GET", path, "", cookies[0], ""); w.Code != 204 {
					t.Fatal(path, w.Code, w.Body.String())
				}
			}
			// Valid engineering documents can contain spreadsheet formulas and text
			// resembling programming language syntax; the owning service validates them.
			body := `{"name":"统计页面","data":{"A1":"=IF(B1<5,1,0)"},"original_workbook":"` + strings.Repeat("A", 70000) + `"}`
			if w = call("POST", "/api/v1/total-reports/pages", body, cookies[0], session.CSRF); w.Code != 204 {
				t.Fatal("engineering upload", w.Code, w.Body.String())
			}
			before := calls
			if w = call("POST", "/api/v1/total-reports/pages", body, cookies[0], ""); w.Code != 403 || calls != before {
				t.Fatal("CSRF bypass", w.Code)
			}
			doc := process.Document{SchemaVersion: 1, ID: "lan-process", Name: "内网工艺画面", Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}}
			for i := 0; i < 40; i++ {
				doc.Nodes = append(doc.Nodes, process.Node{ID: fmt.Sprintf("text-%d", i), Kind: "text", Text: strings.Repeat("x", 2000) + " <script>literal</script>", Width: 100, Height: 100, FontSize: 20, StrokeWidth: 4, Color: "#2563eb", Fill: "none"})
			}
			data, _ := json.Marshal(doc)
			if len(data) < 65536 {
				t.Fatal("fixture must exercise large engineering document")
			}
			if w = call("PUT", "/api/v1/screens/lan-process", string(data), cookies[0], session.CSRF); w.Code != 200 {
				t.Fatal("save process", w.Code, w.Body.String())
			}
			if w = call("GET", "/api/v1/screens/lan-process", "", cookies[0], ""); w.Code != 200 {
				t.Fatal("reopen process", w.Code, w.Body.String())
			}
			var saved process.Document
			if err = json.Unmarshal(w.Body.Bytes(), &saved); err != nil || len(saved.Nodes) != 40 || saved.Nodes[0].Text != doc.Nodes[0].Text || saved.Revision != 1 {
				t.Fatal("process content lost", err)
			}
			if w = call("POST", "/api/v1/demo", `{"enabled":true}`, cookies[0], session.CSRF); w.Code != 403 || !strings.Contains(w.Body.String(), "simulation_unavailable") || len(points.List()) != 0 {
				t.Fatal("production simulation available", w.Code, w.Body.String())
			}
			if allowed, err := ids.PublicPeerAllowed(netip.MustParseAddr("192.168.50.6")); err != nil || !allowed {
				t.Fatal("normal report actions banned LAN user", err)
			}
		})
	}
}

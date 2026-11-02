package server

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

type supplierTransport func(*http.Request) (*http.Response, error)

func (f supplierTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestEmbeddedSupplierIsolationCookiesAndRevocation(t *testing.T) {
	s, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	owner, e := s.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	_, session, token, e := s.LoginChannel("owner", publicFixturePassword, "test", false, "public:web")
	if e != nil {
		t.Fatal(e)
	}
	g := NewEmbeddedSites(s)
	call := func(method, path, peer, origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		r.RemoteAddr = peer
		r.TLS = &tls.ConnectionState{HandshakeComplete: true}
		r.Header.Set("Origin", origin)
		r.Header.Set("Authorization", "Bearer must-not-leak")
		r.Header.Set("X-CSRF-Token", "must-not-leak")
		r.Header.Set("X-Forwarded-For", "must-not-leak")
		r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: token})
		r.AddCookie(&http.Cookie{Name: "hmi_ext_qiwei_sid", Value: "supplier-session"})
		r.AddCookie(&http.Cookie{Name: "hmi_ext_boer_sid", Value: "other-supplier"})
		w := httptest.NewRecorder()
		if path == "/api/v1/external-sites" {
			g.Metadata(http.NotFoundHandler()).ServeHTTP(w, r)
		} else {
			g.ServeHTTP(w, r)
		}
		return w
	}
	w := call("GET", "/api/v1/external-sites", "192.0.2.1:1", "")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var config map[string]any
	if json.Unmarshal(w.Body.Bytes(), &config) != nil || config["sandboxed"] != true {
		t.Fatal("missing opaque origin contract")
	}
	route := config["qiwei"].(string)
	cap := strings.Split(route, "/")[3]
	calls := 0
	g.transport = supplierTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Scheme != "http" || r.URL.Host != "www.winxiot.com:8092" || r.URL.Path != "/login" {
			t.Errorf("wrong fixed target %s", r.URL)
		}
		for _, name := range []string{"Authorization", "X-CSRF-Token", "X-Forwarded-For", "Referer"} {
			if r.Header.Get(name) != "" {
				t.Errorf("HMI header leaked: %s", name)
			}
		}
		if got := r.Header.Get("Cookie"); got != "sid=supplier-session" {
			t.Errorf("cookie namespace leaked %q", got)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/html; charset=utf-8"}, "Set-Cookie": {"sid=remembered; Path=/; HttpOnly; Max-Age=2592000"}}, Body: io.NopCloser(strings.NewReader(`<head></head><script src="/js/app.js"></script><form action="http://www.winxiot.com:8092/login"></form>`))}, nil
	})
	w = call("GET", route, "192.0.2.1:2", "")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	csp := w.Header().Get("Content-Security-Policy")
	if !strings.Contains(csp, "sandbox allow-scripts") || strings.Contains(csp, "allow-same-origin") {
		t.Fatal("supplier can inherit HMI origin", csp)
	}
	if w.Header().Get("Access-Control-Allow-Origin") != "null" || w.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatal(w.Header())
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "hmi_ext_qiwei_sid" || cookies[0].Path != "/external-sites/qiwei/" || !cookies[0].Secure || !cookies[0].HttpOnly || !cookies[0].Partitioned || cookies[0].SameSite != http.SameSiteNoneMode || cookies[0].MaxAge != 2592000 {
		t.Fatal("login cookie persistence lost", cookies)
	}
	prefix := strings.TrimSuffix(route, "/login")
	if !strings.Contains(w.Body.String(), `src="`+prefix+`/js/app.js"`) || !strings.Contains(w.Body.String(), `action="`+prefix+`/login"`) || strings.Contains(w.Body.String(), prefix+prefix) {
		t.Fatal("rewrite failed", w.Body.String())
	}
	if strings.Contains(publicAuditRoute(route), cap) {
		t.Fatal("capability exposed in audit")
	}
	if call("GET", route, "192.0.2.2:2", "").Code != 403 || call("GET", route, "192.0.2.1:2", "https://attacker.invalid").Code != 403 {
		t.Fatal("peer/origin binding bypass")
	}
	if call("GET", strings.Replace(route, cap, strings.Repeat("x", 43), 1), "192.0.2.1:2", "").Code != 401 {
		t.Fatal("guessed capability")
	}
	if calls != 1 {
		t.Fatal("rejected request reached supplier", calls)
	}
	if e = s.Revoke(s.Actor(owner), owner.ID, session.ID); e != nil {
		t.Fatal(e)
	}
	if call("GET", route, "192.0.2.1:2", "").Code != 401 || calls != 1 {
		t.Fatal("logout did not revoke supplier capability")
	}
}

func TestEmbeddedRewritesAndFixedPublicTargets(t *testing.T) {
	target, _ := url.Parse("https://www.360tp.net")
	got := string(rewriteEmbeddedBody([]byte(`a{background:url(/img/a.png)} "https://www.360tp.net/a" '//www.360tp.net/b' @import "/c"`), "text/css", target, "/external-sites/boer/cap"))
	if strings.Count(got, "/external-sites/boer/cap") != 4 || strings.Contains(got, "cap/external-sites") {
		t.Fatal(got)
	}
	js := `var r=/['"]/g; var root="/scripts/";`
	if string(rewriteEmbeddedBody([]byte(js), "application/javascript", target, "/external-sites/boer/cap")) != js {
		t.Fatal("rewriting changed JavaScript grammar")
	}
	if _, e := dialEmbeddedSite(context.Background(), "tcp", "127.0.0.1:80"); e == nil {
		t.Fatal("arbitrary upstream allowed")
	}
	if _, e := dialEmbeddedSite(context.Background(), "tcp", "www.winxiot.com:443"); e == nil {
		t.Fatal("arbitrary supplier port allowed")
	}
}

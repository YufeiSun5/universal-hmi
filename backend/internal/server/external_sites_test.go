package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

type supplierTransport func(*http.Request) (*http.Response, error)

func (f supplierTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestEmbeddedKPLinkedSessionsThroughPublicBoundary(t *testing.T) {
	for _, mode := range []string{"native", "trial"} {
		for _, admission := range []string{"ip", "device", "kp"} {
			t.Run(mode+"/"+admission, func(t *testing.T) {
				s, owner, _, certificate := deviceTLSFixture(t)
				var leaf *x509.Certificate
				if admission == "device" {
					leaf = certificate.Leaf
				}
				valid := true
				token := strings.Repeat("k", 48)
				link := s.LinkKPToken
				if mode == "trial" {
					link = s.LinkKPTrial
				}
				if err := link(owner.ID, token, leaf, func() bool { return valid }); err != nil {
					t.Fatal(err)
				}
				g := NewEmbeddedSites(s)
				calls := 0
				g.transport = supplierTransport(func(r *http.Request) (*http.Response, error) {
					calls++
					if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" || strings.Contains(r.URL.String(), token) {
						t.Error("HMI credentials reached supplier")
					}
					return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/html"}}, Body: io.NopCloser(strings.NewReader("<head></head><body>supplier</body>"))}, nil
				})
				iam, err := IdentityHandler(s, IdentityOptions{Origin: "https://hmi.example", PublicReadOnly: true}, g.Metadata(http.NotFoundHandler()))
				if err != nil {
					t.Fatal(err)
				}
				boundary, err := PublicAccessHandler(iam, PublicAccessOptions{
					Policy: func(ip netip.Addr) bool { return admission == "ip" && ip.String() == "192.0.2.1" },
					Device: s.VerifyDeviceCertificate, External: g,
					KP: http.NotFoundHandler(), KPToken: s.KPTokenValid, KPExternalToken: g.KPAdmissionToken,
				})
				if err != nil {
					t.Fatal(err)
				}
				call := func(route, header, cookie, peer string, cert *x509.Certificate) *httptest.ResponseRecorder {
					r := httptest.NewRequest("GET", route, nil)
					r.Host = "hmi.example"
					r.RemoteAddr = peer + ":1234"
					r.TLS = &tls.ConnectionState{HandshakeComplete: true}
					if cert != nil {
						r.TLS.PeerCertificates = []*x509.Certificate{cert}
					}
					r.Header.Set("Authorization", header)
					if cookie != "" {
						r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: cookie})
					}
					w := httptest.NewRecorder()
					boundary.ServeHTTP(w, r)
					return w
				}
				w := call("/api/v1/external-sites", "Bearer "+token, "", "192.0.2.1", leaf)
				var metadata map[string]any
				if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &metadata) != nil || metadata["sandboxed"] != true {
					t.Fatalf("KP must receive inline supplier routes: %d %s", w.Code, w.Body.String())
				}
				for _, id := range []string{"qiwei", "boer"} {
					route, _ := metadata[id].(string)
					if !strings.HasPrefix(route, embeddedPrefix+id+"/") || strings.Contains(route, token) {
						t.Fatal("missing scoped supplier route")
					}
					// An iframe cannot send the HMI bearer header; its capability is sufficient.
					w = call(route, "", "", "192.0.2.1", leaf)
					if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Security-Policy"), "sandbox allow-scripts") || strings.Contains(w.Header().Get("Content-Security-Policy"), "allow-same-origin") {
						t.Fatalf("KP supplier iframe rejected or not isolated: %d", w.Code)
					}
					if call(route, "", "", "192.0.2.2", leaf).Code != 403 {
						t.Fatal("capability survived peer change")
					}
				}
				for _, auth := range []struct{ header, cookie string }{{"", ""}, {"Basic invalid", ""}, {"Bearer invalid", ""}, {"", token}, {"Bearer " + token, token}} {
					want := 401
					if admission == "kp" && auth.header != "Bearer "+token {
						want = 403
					}
					if call("/api/v1/external-sites", auth.header, auth.cookie, "192.0.2.1", leaf).Code != want {
						t.Fatal("invalid or mixed credential accepted")
					}
				}
				if admission == "device" && call(metadata["qiwei"].(string), "", "", "192.0.2.1", nil).Code != 403 {
					t.Fatal("capability bypassed device admission")
				}
				valid = false
				want := 401
				if admission == "kp" {
					want = 403
				}
				if call("/api/v1/external-sites", "Bearer "+token, "", "192.0.2.1", leaf).Code != want {
					t.Fatal("retired KP session obtained new capability")
				}
				for _, id := range []string{"qiwei", "boer"} {
					if call(metadata[id].(string), "", "", "192.0.2.1", leaf).Code != want {
						t.Fatal("retired KP capability survived")
					}
				}
				if calls != 2 {
					t.Fatal("rejected request reached supplier", calls)
				}
			})
		}
	}
}

func TestEmbeddedBoerDirectoryThroughPublicBoundary(t *testing.T) {
	s, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner, err := s.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	_, session, token, err := s.LoginChannel("owner", publicFixturePassword, "test", false, "public:web")
	if err != nil {
		t.Fatal(err)
	}
	g := NewEmbeddedSites(s)
	upstreamCalls := 0
	g.transport = supplierTransport(func(r *http.Request) (*http.Response, error) {
		upstreamCalls++
		if r.URL.Scheme != "https" || r.URL.Host != "www.360tp.net" || (r.URL.Path != "/" && r.URL.Path != "/pages/") {
			t.Errorf("unexpected supplier target: %s", r.URL)
		}
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" {
			t.Error("HMI credentials reached supplier")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/html"}}, Body: io.NopCloser(strings.NewReader("<html><head></head><body>supplier</body></html>"))}, nil
	})
	boundary, err := PublicAccessHandler(g.Metadata(http.NotFoundHandler()), PublicAccessOptions{
		WebAllowlist: []PublicIPRule{{CIDR: "192.0.2.1/32"}}, External: g,
	})
	if err != nil {
		t.Fatal(err)
	}
	call := func(route, peer string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", route, nil)
		r.RemoteAddr = peer
		r.TLS = &tls.ConnectionState{HandshakeComplete: true}
		r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: token})
		w := httptest.NewRecorder()
		boundary.ServeHTTP(w, r)
		return w
	}
	w := call("/api/v1/external-sites", "192.0.2.1:1")
	var metadata map[string]any
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &metadata) != nil {
		t.Fatal(w.Code, w.Body.String())
	}
	root := metadata["boer"].(string)
	for _, route := range []string{root, root + "pages/"} {
		w = call(route, "192.0.2.1:2")
		if w.Code != 200 || !strings.Contains(w.Body.String(), "supplier") {
			t.Fatalf("supplier directory rejected: %d %s", w.Code, w.Body.String())
		}
		if !strings.Contains(w.Header().Get("Content-Security-Policy"), "sandbox allow-scripts") {
			t.Fatal("supplier sandbox missing")
		}
	}
	for _, route := range []string{root + "/", root + "./", root + "pages/../", root + "%2f", root + "%5c", root + "%2e%2e/", root + "../../../api/v1/security/users/", "/api/v1/security/users/"} {
		if w = call(route, "192.0.2.1:2"); w.Code != 403 {
			t.Fatalf("noncanonical or management path accepted: %d", w.Code)
		}
	}
	if call(root, "192.0.2.2:2").Code != 403 {
		t.Fatal("directory bypassed IP policy")
	}
	if err = s.Revoke(s.Actor(owner), owner.ID, session.ID); err != nil {
		t.Fatal(err)
	}
	if call(root, "192.0.2.1:2").Code != 401 || upstreamCalls != 2 {
		t.Fatal("rejected request reached supplier or revoked capability survived", upstreamCalls)
	}
}

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
	if string(rewriteEmbeddedBody([]byte("if (top.location != self.location) top.location = self.location;"+js), "application/javascript", target, "/external-sites/boer/cap")) != js {
		t.Fatal("supplier frame-buster not removed")
	}
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

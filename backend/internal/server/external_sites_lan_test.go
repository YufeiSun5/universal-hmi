package server

import (
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

func TestEmbeddedLANHTTPLoginAndSessionIsolation(t *testing.T) {
	for _, development := range []bool{false, true} {
		t.Run(map[bool]string{false: "web", true: "engineering"}[development], func(t *testing.T) {
			ids, err := identity.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer ids.Close()
			if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
				t.Fatal(err)
			}
			const origin = "http://192.168.50.5:18443"
			captchas := newLoginCaptchas()
			g := NewLANHTTPEmbeddedSites(ids, development)
			iam, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true, LANHTTP: true, LANDevelopment: development, captchas: captchas}, g.Metadata(http.NotFoundHandler()))
			if err != nil {
				t.Fatal(err)
			}
			guard, err := NewLANGuard(ids, development)
			if err != nil {
				t.Fatal(err)
			}
			h, err := PublicAccessHandler(guard.Handler(iam), PublicAccessOptions{LANDevelopment: development, Policy: func(ip netip.Addr) bool { return ip.String() == "192.168.50.6" }, External: guard.Handler(g)})
			if err != nil {
				t.Fatal(err)
			}
			h = LANPeerHandler(h)
			call := func(method, path, body, requestOrigin string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
				r := httptest.NewRequest(method, path, strings.NewReader(body))
				r.Host = "192.168.50.5:18443"
				r.RemoteAddr = "192.168.50.6:1234"
				r.Header.Set("Origin", requestOrigin)
				r.Header.Set("Content-Type", "application/json")
				r.Header.Set("X-CSRF-Token", csrf)
				if cookie != nil {
					r.AddCookie(cookie)
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				return w
			}
			login := func() (*http.Cookie, string) {
				b, _ := json.Marshal(map[string]string{"username": "owner", "password": publicFixturePassword, "captcha_id": seedLoginCaptcha(captchas, "192.168.50.6"), "captcha_answer": "12345"})
				w := call("POST", authLoginPath, string(b), origin, nil, "")
				if w.Code != 200 {
					t.Fatal(w.Code, w.Body.String())
				}
				var state map[string]any
				if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
					t.Fatal(err)
				}
				return w.Result().Cookies()[0], state["csrf_token"].(string)
			}
			metadata := func(cookie *http.Cookie) map[string]string {
				w := call("GET", "/api/v1/external-sites", "", origin, cookie, "")
				var state map[string]any
				if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &state) != nil || state["sandboxed"] != true {
					t.Fatal(w.Code, w.Body.String())
				}
				return map[string]string{"qiwei": state["qiwei"].(string), "boer": state["boer"].(string)}
			}
			cookie, csrf := login()
			routes := metadata(cookie)
			requests := 0
			g.transport = supplierTransport(func(r *http.Request) (*http.Response, error) {
				requests++
				if r.Header.Get("Authorization") != "" || r.Header.Get("X-CSRF-Token") != "" || strings.Contains(r.Header.Get("Cookie"), "hmi_") {
					t.Error("HMI credentials leaked")
				}
				switch r.URL.Path {
				case "/login", "/":
					if r.Header.Get("Cookie") != "" {
						t.Error("different supplier/session inherited a cookie")
					}
					return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/html"}, "Set-Cookie": {"sid=prelogin; Path=/; HttpOnly"}}, Body: io.NopCloser(strings.NewReader(`<head></head><form action="/login/login"></form>`))}, nil
				case "/login/login":
					if r.Method != "POST" || r.Header.Get("Cookie") != "sid=prelogin" || r.Header.Get("Origin") != embeddedTargets["qiwei"] {
						t.Error("login lost its supplier session or origin")
					}
					return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"/index"}, "Set-Cookie": {"sid=loggedin; Path=/; HttpOnly", "pathCookie=private; Path=/private; HttpOnly"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
				case "/index":
					if r.Header.Get("Cookie") != "sid=loggedin" {
						t.Error("authenticated session missing or cookie path ignored")
					}
					return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/html"}}, Body: io.NopCloser(strings.NewReader("<head></head>logged in"))}, nil
				case "/logout":
					return &http.Response{StatusCode: 200, Header: http.Header{"Set-Cookie": {"sid=; Path=/; Max-Age=0"}}, Body: io.NopCloser(strings.NewReader("logout"))}, nil
				}
				t.Fatalf("unexpected upstream path %s", r.URL.Path)
				return nil, nil
			})
			prefix := strings.TrimSuffix(routes["qiwei"], "/login")
			for _, route := range []string{routes["qiwei"], routes["boer"]} {
				// Opaque iframe sends no HMI cookie at all, even on HTTP.
				w := call("GET", route, "", "", nil, "")
				if w.Code != 200 || len(w.Result().Cookies()) != 0 || strings.Contains(w.Header().Get("Content-Security-Policy"), "allow-same-origin") {
					t.Fatal(w.Code, w.Header())
				}
			}
			w := call("POST", prefix+"/login/login", `{}`, "null", nil, "")
			if w.Code != 302 || w.Header().Get("Location") != prefix+"/index" || len(w.Result().Cookies()) != 0 {
				t.Fatal(w.Code, w.Header())
			}
			if w = call("GET", prefix+"/index", "", "", nil, ""); w.Code != 200 {
				t.Fatal(w.Code)
			}
			if metadata(cookie)["qiwei"] != routes["qiwei"] {
				t.Fatal("reopening lost LAN supplier session")
			}
			// A second login by the same user is a separate browser identity.
			second, _ := login()
			other := metadata(second)
			if other["qiwei"] == routes["qiwei"] {
				t.Fatal("different HMI sessions share capabilities")
			}
			if w = call("GET", other["qiwei"], "", "", nil, ""); w.Code != 200 {
				t.Fatal(w.Code)
			}
			if w = call("GET", prefix+"/logout", "", "", nil, ""); w.Code != 200 {
				t.Fatal(w.Code)
			}
			if w = call("GET", routes["qiwei"], "", "", nil, ""); w.Code != 200 {
				t.Fatal(w.Code)
			}
			before := requests
			if w = call("POST", prefix+"/login/login", `{}`, "http://attacker.invalid", nil, ""); w.Code != 403 {
				t.Fatal("foreign origin accepted", w.Code)
			}
			if w = call("POST", authLogoutPath, `{}`, origin, cookie, csrf); w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			for _, route := range routes {
				if w = call("GET", route, "", "", nil, ""); w.Code != 401 {
					t.Fatal("revoked HMI session retained supplier access", w.Code)
				}
			}
			if requests != before {
				t.Fatal("rejected requests reached supplier")
			}
		})
	}
}

func TestEmbeddedLANRejectsOtherTransportsAndChannels(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
		t.Fatal(err)
	}
	for _, channel := range []string{"public:web", "lan:engineering", "lan:http:web", "lan:http:engineering"} {
		_, _, token, err := ids.LoginChannel("owner", publicFixturePassword, "test", false, channel)
		if err != nil {
			t.Fatal(err)
		}
		g := NewLANHTTPEmbeddedSites(ids, true)
		r := httptest.NewRequest("GET", "/api/v1/external-sites", nil)
		r.Host, r.RemoteAddr = "192.168.50.5:18443", "192.168.50.6:1234"
		r.AddCookie(&http.Cookie{Name: "hmi_lan_identity", Value: token})
		w := httptest.NewRecorder()
		g.Metadata(http.NotFoundHandler()).ServeHTTP(w, r)
		want := 401
		if channel == "lan:http:engineering" {
			want = 200
		}
		if w.Code != want {
			t.Fatal(channel, w.Code)
		}
		for _, change := range []func(*http.Request){
			func(r *http.Request) { r.Host = "hmi.example:18443" },
			func(r *http.Request) { r.RemoteAddr = "203.0.113.3:1234" },
			func(r *http.Request) { r.Header.Set("X-Forwarded-For", "192.168.50.6") },
		} {
			copy := r.Clone(r.Context())
			change(copy)
			w = httptest.NewRecorder()
			g.Metadata(http.NotFoundHandler()).ServeHTTP(w, copy)
			if w.Code != 403 {
				t.Fatal("non-private or forwarded request accepted", w.Code)
			}
		}
	}
}

func TestEmbeddedSupplierLoginNavigation(t *testing.T) {
	qiwei, _ := url.Parse(embeddedTargets["qiwei"])
	prefix := "/external-sites/qiwei/cap"
	for _, ctx := range []string{`"\/"`, `"\/;JSESSIONID=test-session"`} {
		body := `<head><script>if(window.top!==window.self){window.top.location=window.location};</script></head><script>var ctx = ` + ctx + `; var captchaType = false;</script>`
		got := string(rewriteEmbeddedBody([]byte(body), "text/html", qiwei, prefix))
		if strings.Contains(got, "window.top.location") || strings.Contains(got, "JSESSIONID") || !strings.Contains(got, `var ctx = "`+prefix+`/";`) {
			t.Fatal(got)
		}
	}
	boer, _ := url.Parse(embeddedTargets["boer"])
	got := string(rewriteEmbeddedBody([]byte(`if (top.location != self.location) top.location = self.location; location.href = res.TargetUrl;`), "application/javascript", boer, "/external-sites/boer/cap"))
	if strings.Contains(got, "top.location") || !strings.Contains(got, "window.__hmiExternalURL(res.TargetUrl)") {
		t.Fatal(got)
	}
	menu := string(rewriteEmbeddedMenu([]byte(`{"menuInfo":[{"href":"/home/default","child":[{"href":"../devicedata/index"}]}],"homeInfo":{"href":"/devicedata/index"},"other":{"href":"https://other.invalid/"},"empty":{"href":""},"count":9007199254740993}`), boer, "/external-sites/boer/cap"))
	for _, want := range []string{`"href":"/external-sites/boer/cap/home/default"`, `"href":"/external-sites/boer/cap/devicedata/index"`, `"href":"https://other.invalid/"`, `"href":""`, `9007199254740993`} {
		if !strings.Contains(menu, want) {
			t.Fatal("menu navigation or payload changed", menu)
		}
	}
}

package server

import (
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestKPWebFrameAndCookieScope(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	if _, err := ids.Bootstrap("owner", publicFixturePassword); err != nil {
		t.Fatal(err)
	}
	const origin = "https://example.test"
	captchas := newLoginCaptchas()
	h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true, KPWebEmbed: true, captchas: captchas}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path, dest string
		code       int
	}{
		{"/?embed=kp", "iframe", 200}, {"/", "iframe", 403}, {"/api/v1/auth/session?embed=kp", "iframe", 403}, {"/?embed=kp", "script", 403},
	} {
		r := httptest.NewRequest("GET", origin+tc.path, nil)
		r.Header.Set("Sec-Fetch-Site", "cross-site")
		r.Header.Set("Sec-Fetch-Mode", "navigate")
		r.Header.Set("Sec-Fetch-Dest", tc.dest)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s %s: %d", tc.path, tc.dest, w.Code)
		}
		if tc.code == 200 && (w.Header().Get("X-Frame-Options") != "" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'self' http://127.0.0.1:11005;")) {
			t.Fatal(w.Header())
		}
	}
	for _, embedded := range []bool{true, false} {
		body, _ := json.Marshal(map[string]string{"username": "owner", "password": publicFixturePassword, "captcha_id": seedLoginCaptcha(captchas, "127.0.0.1"), "captcha_answer": "12345"})
		r := httptest.NewRequest("POST", origin+authLoginPath, strings.NewReader(string(body)))
		r.RemoteAddr = "127.0.0.1:4096"
		r.TLS = &tls.ConnectionState{}
		r.Header.Set("Origin", origin)
		if embedded {
			r.Header.Set("X-HMI-Embed", "kp")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		cookies := w.Result().Cookies()
		if w.Code != 200 || len(cookies) != 1 {
			t.Fatalf("login HTTP %d", w.Code)
		}
		c := cookies[0]
		if !c.HttpOnly || !c.Secure || c.Partitioned != embedded || (c.SameSite == http.SameSiteNoneMode) != embedded {
			t.Fatal("incorrect session cookie scope")
		}
	}
}

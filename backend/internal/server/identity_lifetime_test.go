package server

import (
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestIdentityNoTimeoutContractCookieRefreshAndLogout(t *testing.T) {
	for _, public := range []bool{false, true} {
		t.Run(map[bool]string{false: "local", true: "public"}[public], func(t *testing.T) {
			ids, err := identity.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer ids.Close()
			if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
				t.Fatal(err)
			}
			origin := "http://127.0.0.1:18080"
			if public {
				origin = "https://example.test"
			}
			captchas := newLoginCaptchas()
			h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, LocalSetup: !public, PublicReadOnly: public, captchas: captchas}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
			if err != nil {
				t.Fatal(err)
			}
			call := func(method, path, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
				r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
				r.RemoteAddr = "127.0.0.1:12345"
				r.Header.Set("Origin", origin)
				r.Header.Set("Content-Type", "application/json")
				r.Header.Set("X-CSRF-Token", csrf)
				if public {
					r.TLS = &tls.ConnectionState{}
				}
				if cookie != nil {
					r.AddCookie(cookie)
				}
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				return w
			}
			body, _ := json.Marshal(map[string]any{"username": "owner", "password": publicFixturePassword, "captcha_id": seedLoginCaptcha(captchas, "127.0.0.1"), "captcha_answer": "12345"})
			login := call("POST", authLoginPath, string(body), nil, "")
			if login.Code != 200 || len(login.Result().Cookies()) != 1 {
				t.Fatal(login.Code, login.Body.String())
			}
			cookie := login.Result().Cookies()[0]
			if cookie.MaxAge != identityCookieMaxAge || !cookie.HttpOnly || cookie.Secure != public || cookie.SameSite != http.SameSiteStrictMode {
				t.Fatal("invalid cookie retention or protection", cookie)
			}
			var data map[string]any
			if err = json.Unmarshal(login.Body.Bytes(), &data); err != nil {
				t.Fatal(err)
			}
			if data["session_policy"] != "no_timeout" || data["authenticated"] != true || data["security_model"] != "identity-v1" {
				t.Fatal("invalid no-timeout contract", data)
			}
			legacyHintText, _ := data["expires_at"].(string)
			if legacyHint, err := time.Parse(time.RFC3339, legacyHintText); err != nil || !legacyHint.After(time.Now()) {
				t.Fatal("older clients lost compatible deadline", data["expires_at"], err)
			}
			read := call("GET", authSessionPath, "", cookie, "")
			if read.Code != 200 || len(read.Result().Cookies()) != 1 || read.Result().Cookies()[0].MaxAge != identityCookieMaxAge || read.Result().Cookies()[0].Value != cookie.Value {
				t.Fatal("session read failed to retain same cookie", read.Code, read.Body.String())
			}
			logout := call("POST", authLogoutPath, "{}", cookie, data["csrf_token"].(string))
			if logout.Code != 200 || logout.Result().Cookies()[0].MaxAge != -1 {
				t.Fatal(logout.Code, logout.Body.String())
			}
			if rejected := call("GET", "/api/v1/runtime", "", cookie, ""); rejected.Code != 401 {
				t.Fatal("logout did not revoke cookie", rejected.Code)
			}
		})
	}
}

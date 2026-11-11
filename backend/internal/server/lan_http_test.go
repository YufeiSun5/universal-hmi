package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestLANHTTPLoginCookieAndIsolation(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	if _, err = ids.Bootstrap("owner", publicFixturePassword); err != nil {
		t.Fatal(err)
	}
	const origin = "http://192.168.50.5:18443"
	captcha := newLoginCaptchas()
	h, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true, LANHTTP: true, LANDevelopment: true, captchas: captcha}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body, peer string, cookie *http.Cookie) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = peer + ":1234"
		r.Header.Set("Origin", origin)
		r.Header.Set("Content-Type", "application/json")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	b, _ := json.Marshal(map[string]any{"username": "owner", "password": publicFixturePassword, "captcha_id": seedLoginCaptcha(captcha, "192.168.50.6"), "captcha_answer": "12345"})
	w := call("POST", authLoginPath, string(b), "192.168.50.6", nil)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "hmi_lan_identity" || cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode || w.Header().Get("Strict-Transport-Security") != "" {
		t.Fatal(cookies, w.Header())
	}
	var state map[string]any
	json.Unmarshal(w.Body.Bytes(), &state)
	if state["can_develop"] != true || state["channel"] != "lan:http:engineering" {
		t.Fatal(state)
	}
	for _, channel := range []string{"", "public:web", "lan:engineering", "lan:http:web"} {
		if _, _, err = ids.ResolveChannel(cookies[0].Value, false, channel); err == nil {
			t.Fatal("cross-channel session", channel)
		}
	}
	if w = call("GET", "/api/v1/points", "", "192.168.50.6", cookies[0]); w.Code != 204 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w = call("POST", "/api/v1/points", "{}", "192.168.50.6", cookies[0]); w.Code != 403 {
		t.Fatal("CSRF not enforced", w.Code)
	}
	if w = call("GET", "/api/v1/points", "", "203.0.113.4", cookies[0]); w.Code != 403 {
		t.Fatal("public peer accepted", w.Code)
	}
	if w = call("POST", "/api/v1/auth/setup", "{}", "192.168.50.6", nil); w.Code != 403 {
		t.Fatal("local setup accepted", w.Code)
	}
	for _, options := range []IdentityOptions{
		{Origin: origin, PublicReadOnly: true},
		{Origin: "http://203.0.113.4:18443", PublicReadOnly: true, LANHTTP: true},
		{Origin: origin, PublicReadOnly: true, LANHTTP: true, KPWebEmbed: true},
	} {
		if _, err = IdentityHandler(ids, options, http.NotFoundHandler()); err == nil {
			t.Fatal("invalid HTTP accepted", options)
		}
	}
}

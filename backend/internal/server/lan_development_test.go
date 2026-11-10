package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestLANEngineeringAuthenticationWritesAndChannelIsolation(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	_, err = ids.Change(ids.Actor(owner), "", identity.Change{Username: "viewer", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if err != nil {
		t.Fatal(err)
	}
	raw, _, _ := platform(t)
	type endpoint struct {
		server   *httptest.Server
		captchas *loginCaptchas
	}
	create := func(development bool) endpoint {
		s := httptest.NewUnstartedServer(nil)
		captcha := newLoginCaptchas()
		h, e := IdentityHandler(ids, IdentityOptions{Origin: "https://" + s.Listener.Addr().String(), PublicReadOnly: true, LANDevelopment: development, captchas: captcha}, raw)
		if e != nil {
			t.Fatal(e)
		}
		guard, e := NewPublicGuard(ids)
		if development {
			guard, e = NewLANDevelopmentGuard(ids)
		}
		if e != nil {
			t.Fatal(e)
		}
		h, e = PublicAccessHandler(guard.Handler(h), PublicAccessOptions{LANDevelopment: development, WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}})
		if e != nil {
			t.Fatal(e)
		}
		s.Config.Handler = h
		s.StartTLS()
		t.Cleanup(s.Close)
		return endpoint{s, captcha}
	}
	lan, pub := create(true), create(false)
	call := func(ep endpoint, method, path, body, token, csrf string, cookie bool, origin string) (int, []byte) {
		t.Helper()
		r, _ := http.NewRequest(method, ep.server.URL+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", origin)
		if token != "" {
			if cookie {
				r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: token})
			} else {
				r.Header.Set("Authorization", "Bearer "+token)
			}
		}
		if csrf != "" {
			r.Header.Set("X-CSRF-Token", csrf)
		}
		resp, e := ep.server.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, b
	}
	login := func(ep endpoint, user string) (string, bool) {
		t.Helper()
		b, _ := json.Marshal(map[string]any{"username": user, "password": publicFixturePassword, "issue_token": true, "captcha_id": seedLoginCaptcha(ep.captchas, "127.0.0.1"), "captcha_answer": "12345"})
		status, data := call(ep, "POST", authLoginPath, string(b), "", "", false, ep.server.URL)
		if status != 200 {
			t.Fatalf("login %d %s", status, data)
		}
		var response struct {
			Token   string `json:"bearer_token"`
			Develop bool   `json:"can_develop"`
		}
		json.Unmarshal(data, &response)
		return response.Token, response.Develop
	}
	engineer, develop := login(lan, "owner")
	if !develop {
		t.Fatal("LAN engineer lost development")
	}
	viewer, develop := login(lan, "viewer")
	if develop {
		t.Fatal("viewer gained development")
	}
	publicToken, develop := login(pub, "owner")
	if develop {
		t.Fatal("public engineer gained development")
	}
	point := `{"station":"A","name":"LAN point","source_type":"manual","data_type":"FLOAT"}`
	if code, b := call(lan, "POST", "/api/v1/points", point, engineer, "", false, lan.server.URL); code != 201 {
		t.Fatalf("LAN create %d %s", code, b)
	}
	for _, item := range []struct {
		ep    endpoint
		token string
		want  int
	}{{lan, viewer, 403}, {lan, publicToken, 401}, {pub, engineer, 403}, {pub, publicToken, 403}} {
		if code, _ := call(item.ep, "POST", "/api/v1/points", point, item.token, "", false, item.ep.server.URL); code != item.want {
			t.Fatalf("boundary code %d want %d", code, item.want)
		}
	}
	if code, _ := call(lan, "POST", "/api/v1/points", point, engineer, "", false, "https://untrusted.invalid"); code != 403 {
		t.Fatal("wrong Origin accepted", code)
	}
	_, session, cookieToken, e := ids.LoginChannel("owner", publicFixturePassword, "cookie-fixture", false, "lan:engineering")
	if e != nil {
		t.Fatal(e)
	}
	if code, _ := call(lan, "POST", "/api/v1/points", strings.Replace(point, "LAN point", "Cookie point", 1), cookieToken, "", true, lan.server.URL); code != 403 {
		t.Fatal("CSRF missing accepted", code)
	}
	if code, b := call(lan, "POST", "/api/v1/points", strings.Replace(point, "LAN point", "Cookie point", 1), cookieToken, session.CSRF, true, lan.server.URL); code != 201 {
		t.Fatalf("cookie write %d %s", code, b)
	}
	// Backend schema validation remains active for opaque engineering bodies.
	if code, _ := call(lan, "POST", "/api/v1/points", `{"unknown":"<script>test</script>"}`, engineer, "", false, lan.server.URL); code != 400 {
		t.Fatal("invalid project schema accepted", code)
	}
	if code, _ := call(lan, "GET", "/api/v1/security/network-access", "", engineer, "", false, lan.server.URL); code != 403 {
		t.Fatal("LAN reached local network management", code)
	}
	if code, _ := call(lan, "POST", "/mcp", `{}`, engineer, "", false, lan.server.URL); code != 403 {
		t.Fatal("LAN expanded MCP", code)
	}
	if err = ids.Revoke(ids.Actor(owner), owner.ID, session.ID); err != nil {
		t.Fatal(err)
	}
	if code, _ := call(lan, "POST", "/api/v1/points", point, cookieToken, session.CSRF, true, lan.server.URL); code != 401 {
		t.Fatal("revoked session accepted", code)
	}
}

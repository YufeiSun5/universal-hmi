package server

import (
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const authTestPassword = "isolated-fixture-only-password"

var authHashOnce sync.Once
var authTestHash string
var authHashError error

func newFixtureAuth(t *testing.T, writable bool) *Auth {
	t.Helper()
	authHashOnce.Do(func() {
		var hash []byte
		hash, authHashError = bcrypt.GenerateFromPassword([]byte(authTestPassword), 12)
		authTestHash = string(hash)
	})
	if authHashError != nil {
		t.Fatal(authHashError)
	}
	a, err := NewAuth(AuthConfig{Username: "fixture", PasswordHash: authTestHash, AllowWrite: writable, PublicOrigin: "https://hmi.example:18443"})
	if err != nil {
		t.Fatal(err)
	}
	return a
}
func fixtureAuthRequest(a *Auth, method, path, body string, cookie *http.Cookie, csrf, bearer string) *httptest.ResponseRecorder {
	origin := "https://hmi.example:18443"
	if a == nil {
		origin = "http://127.0.0.1:18080"
	}
	r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:42345"
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if csrf != "" {
		r.Header.Set("X-CSRF-Token", csrf)
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	w := httptest.NewRecorder()
	a.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := PrincipalFromContext(r.Context())
		if !ok {
			http.Error(w, "missing principal", 500)
			return
		}
		writeJSON(w, 200, map[string]any{"username": p.Username, "can_write": p.AllowWrite, "local": p.Local})
	})).ServeHTTP(w, r)
	return w
}
func fixtureLogin(t *testing.T, a *Auth, bearer bool) (*http.Cookie, map[string]any) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"username": "fixture", "password": authTestPassword, "issue_token": bearer})
	w := fixtureAuthRequest(a, "POST", authLoginPath, string(body), nil, "", "")
	if w.Code != 200 {
		t.Fatalf("login: %d %s", w.Code, w.Body.String())
	}
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if bearer {
		if len(w.Result().Cookies()) != 0 || result["bearer_token"] == nil || result["csrf_token"] != nil {
			t.Fatalf("bearer response: %s", w.Body)
		}
		return nil, result
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("cookies: %+v", cookies)
	}
	return cookies[0], result
}

func TestAuthLoginSessionAndCookieSecurity(t *testing.T) {
	a := newFixtureAuth(t, true)
	w := fixtureAuthRequest(a, "GET", authSessionPath, "", nil, "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"authenticated":false`) || strings.Contains(w.Body.String(), "fixture") {
		t.Fatal(w.Body)
	}
	for _, body := range []string{
		`{"username":"fixture","password":"wrong"}`,
		`{"username":"unknown","password":"` + authTestPassword + `"}`,
		`{"username":"fixture","password":"` + authTestPassword + strings.Repeat("x", 80) + `"}`,
	} {
		w = fixtureAuthRequest(a, "POST", authLoginPath, body, nil, "", "")
		if w.Code != 401 || !strings.Contains(w.Body.String(), `"code":"invalid_credentials"`) {
			t.Fatalf("invalid credentials: %d %s", w.Code, w.Body)
		}
	}
	cookie, session := fixtureLogin(t, a, false)
	if !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.Domain != "" || cookie.Name != "__Host-hmi_session" || cookie.MaxAge != 28800 {
		t.Fatalf("unsafe cookie: %+v", cookie)
	}
	if session["username"] != "fixture" || session["can_write"] != true || session["authenticated"] != true || len(session["csrf_token"].(string)) != 43 {
		t.Fatalf("session: %+v", session)
	}
	w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"username":"fixture"`) {
		t.Fatal(w.Code, w.Body)
	}
	w = fixtureAuthRequest(a, "GET", authSessionPath, "", cookie, "", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), authTestHash) || strings.Contains(w.Body.String(), cookie.Value) || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("session exposed credential or is cacheable")
	}
}

func TestAuthCannotBypassViaLoopbackHostOriginOrForwardedHeaders(t *testing.T) {
	a := newFixtureAuth(t, true)
	for _, path := range []string{"/api/v1/runtime", "/api/v1/points", "/mcp"} {
		w := fixtureAuthRequest(a, "POST", path, `{}`, nil, "", "")
		if w.Code != 401 {
			t.Fatalf("unauthenticated %s got %d", path, w.Code)
		}
	}
	cookie, _ := fixtureLogin(t, a, false)
	for _, tc := range []struct{ name, url, host, origin, fetch string }{
		{"foreign host", "https://evil.example/api/v1/runtime", "", "", ""},
		{"loopback is not bypass", "https://127.0.0.1:18443/api/v1/runtime", "", "", ""},
		{"plaintext", "http://hmi.example:18443/api/v1/runtime", "", "", ""},
		{"foreign origin", "https://hmi.example:18443/api/v1/runtime", "", "https://evil.example", ""},
		{"null origin", "https://hmi.example:18443/api/v1/runtime", "", "null", ""},
		{"fetch cross site", "https://hmi.example:18443/api/v1/runtime", "", "", "cross-site"},
		{"sibling site", "https://hmi.example:18443/api/v1/runtime", "", "", "same-site"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", tc.url, nil)
			r.RemoteAddr = "127.0.0.1:45555"
			r.AddCookie(cookie)
			r.Header.Set("Origin", tc.origin)
			r.Header.Set("Sec-Fetch-Site", tc.fetch)
			r.Header.Set("X-Forwarded-Host", "hmi.example:18443")
			r.Header.Set("X-Forwarded-Proto", "https")
			r.Header.Set("X-Forwarded-For", "127.0.0.1")
			w := httptest.NewRecorder()
			a.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("guard bypass") })).ServeHTTP(w, r)
			if w.Code != 403 {
				t.Fatalf("status %d %s", w.Code, w.Body)
			}
		})
	}
}

func TestAuthCSRFAndReadOnlyPermission(t *testing.T) {
	for _, writable := range []bool{false, true} {
		a := newFixtureAuth(t, writable)
		cookie, s := fixtureLogin(t, a, false)
		csrf := s["csrf_token"].(string)
		for _, token := range []string{"", "wrong"} {
			for _, path := range []string{"/api/v1/write", "/mcp", authLogoutPath} {
				w := fixtureAuthRequest(a, "POST", path, `{}`, cookie, token, "")
				if w.Code != 403 || !strings.Contains(w.Body.String(), "csrf_rejected") {
					t.Fatalf("CSRF bypass: %s %d %s", path, w.Code, w.Body)
				}
			}
		}
		w := fixtureAuthRequest(a, "POST", "/api/v1/write", `{}`, cookie, csrf, "")
		want := 403
		if writable {
			want = 200
		}
		if w.Code != want {
			t.Fatalf("writable=%v: %d %s", writable, w.Code, w.Body)
		}
		// The MCP registry, not the HTTP POST envelope, decides whether a tool mutates.
		w = fixtureAuthRequest(a, "POST", "/mcp", `{}`, cookie, csrf, "")
		if w.Code != 200 {
			t.Fatalf("read MCP envelope blocked: %d %s", w.Code, w.Body)
		}
		w = fixtureAuthRequest(a, "POST", authLogoutPath, `{}`, cookie, csrf, "")
		if w.Code != 200 {
			t.Fatalf("read-only logout blocked: %d %s", w.Code, w.Body)
		}
	}
}

func TestAuthExpiryLogoutAndSessionRotation(t *testing.T) {
	a := newFixtureAuth(t, true)
	now := time.Now()
	a.now = func() time.Time { return now }
	cookie, s := fixtureLogin(t, a, false)
	csrf := s["csrf_token"].(string)
	w := fixtureAuthRequest(a, "POST", authLogoutPath, `{}`, cookie, csrf, "")
	if w.Code != 200 || w.Result().Cookies()[0].MaxAge != -1 {
		t.Fatal("logout failed")
	}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", ""); w.Code != 401 {
		t.Fatal("revoked cookie accepted")
	}
	cookie, _ = fixtureLogin(t, a, false)
	now = now.Add(a.config.SessionTTL)
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", ""); w.Code != 401 {
		t.Fatal("expired cookie accepted")
	}
	if len(a.sessions) != 0 {
		t.Fatal("expired session not purged")
	}
	now = now.Add(time.Minute)
	cookie, _ = fixtureLogin(t, a, false)
	body := `{"username":"fixture","password":"` + authTestPassword + `"}`
	w = fixtureAuthRequest(a, "POST", authLoginPath, body, cookie, "", "")
	if w.Code != 200 || w.Result().Cookies()[0].Value == cookie.Value {
		t.Fatal("login did not rotate session")
	}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", ""); w.Code != 401 {
		t.Fatal("old rotated session accepted")
	}
}

func TestAuthBearerIsBoundToTransportModeAndRevoked(t *testing.T) {
	a := newFixtureAuth(t, true)
	_, s := fixtureLogin(t, a, true)
	token := s["bearer_token"].(string)
	w := fixtureAuthRequest(a, "POST", "/mcp", `{}`, nil, "", token)
	if w.Code != 200 {
		t.Fatalf("bearer MCP: %d %s", w.Code, w.Body)
	}
	cookie := &http.Cookie{Name: a.cookieName, Value: token}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", ""); w.Code != 401 {
		t.Fatal("bearer accepted as ambient cookie")
	}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", token); w.Code != 401 {
		t.Fatal("ambiguous credentials accepted")
	}
	if w = fixtureAuthRequest(a, "POST", authLogoutPath, `{}`, nil, "", token); w.Code != 200 {
		t.Fatal("bearer logout failed")
	}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", nil, "", token); w.Code != 401 {
		t.Fatal("revoked bearer accepted")
	}
	cookie, _ = fixtureLogin(t, a, false)
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", nil, "", cookie.Value); w.Code != 401 {
		t.Fatal("cookie accepted as bearer bypassing CSRF")
	}
}

func TestAuthRateLimitsBoundedAndNoForwardedIPTrust(t *testing.T) {
	a := newFixtureAuth(t, true)
	now := time.Now()
	a.now = func() time.Time { return now }
	for i := 0; i < authAttemptsPerIP; i++ {
		if !a.allowAttempt("127.0.0.1:54321") {
			t.Fatalf("rejected attempt %d", i)
		}
	}
	if a.allowAttempt("127.0.0.1:60000") {
		t.Fatal("port change bypassed rate limit")
	}
	r := httptest.NewRequest("POST", "https://hmi.example:18443"+authLoginPath, strings.NewReader(`{}`))
	r.RemoteAddr = "127.0.0.1:55555"
	r.Header.Set("X-Forwarded-For", "192.0.2.1")
	w := httptest.NewRecorder()
	a.Handler(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatal("forwarded IP bypassed rate limit")
	}
	now = now.Add(authWindow)
	if !a.allowAttempt("127.0.0.1:55555") {
		t.Fatal("window did not expire")
	}
	for i := 0; i < maxAuthClients; i++ {
		a.attempts[time.Unix(int64(i), 0).String()] = authAttempts{Started: now}
	}
	if a.allowAttempt("192.0.2.1:40000") {
		t.Fatal("client map grew past bound")
	}
	if len(a.attempts) > maxAuthClients+1 {
		t.Fatal("unbounded rate map")
	}
	a.attempts = map[string]authAttempts{}
	a.global = authAttempts{Started: now, Count: authAttemptsGlobal}
	if a.allowAttempt("192.0.2.2:40000") {
		t.Fatal("global limit bypassed")
	}
}

func TestAuthLoginFormCSRFAndSafeReturn(t *testing.T) {
	a := newFixtureAuth(t, true)
	w := fixtureAuthRequest(a, "GET", "/", "", nil, "", "")
	if w.Code != 303 || w.Header().Get("Location") != "/login" {
		t.Fatal("missing login route")
	}
	w = fixtureAuthRequest(a, "GET", "/login?next=https://evil.example", "", nil, "", "")
	if w.Code != 200 || w.Header().Get("Content-Security-Policy") == "" || !strings.Contains(w.Body.String(), `type="password"`) {
		t.Fatal("insecure login page")
	}
	loginCookie := w.Result().Cookies()[0]
	values := url.Values{"username": {"fixture"}, "password": {authTestPassword}, "csrf_token": {loginCookie.Value}}
	for _, valid := range []bool{false, true} {
		r := httptest.NewRequest("POST", "https://hmi.example:18443/login?next=https://evil.example", strings.NewReader(values.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if valid {
			r.AddCookie(loginCookie)
		}
		w = httptest.NewRecorder()
		a.Handler(http.NotFoundHandler()).ServeHTTP(w, r)
		if !valid && w.Code != 403 {
			t.Fatal("form login accepted without CSRF cookie")
		}
		if valid && (w.Code != 303 || w.Header().Get("Location") != "/") {
			t.Fatalf("unsafe return: %d %s", w.Code, w.Body)
		}
	}
}

func TestAuthRejectsMalformedLoginAndHasBoundedSessions(t *testing.T) {
	a := newFixtureAuth(t, true)
	for _, body := range []string{`{`, `{"username":"x","password":"x","unknown":1}`, `{}` + `{}`, strings.Repeat("x", 4097)} {
		if w := fixtureAuthRequest(a, "POST", authLoginPath, body, nil, "", ""); w.Code != 400 {
			t.Fatalf("malformed body got %d", w.Code)
		}
	}
	r := httptest.NewRequest("POST", "https://hmi.example:18443"+authLoginPath, strings.NewReader(`{"username":"fixture","password":"`+authTestPassword+`"}`))
	r.Header.Set("Content-Type", "text/plain")
	w := httptest.NewRecorder()
	a.Handler(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != 415 {
		t.Fatal("simple cross-origin login content type accepted")
	}
	for i := 0; i < maxAuthSessions; i++ {
		a.sessions[sha256.Sum256([]byte(time.Unix(int64(i), 0).String()))] = authSession{Expires: a.now().Add(time.Hour)}
	}
	w = fixtureAuthRequest(a, "POST", authLoginPath, `{"username":"fixture","password":"`+authTestPassword+`"}`, nil, "", "")
	if w.Code != 503 || len(a.sessions) != maxAuthSessions {
		t.Fatal("session limit not enforced")
	}
}

func TestAuthDisabledLocalIsExplicit(t *testing.T) {
	var a *Auth
	w := fixtureAuthRequest(a, "GET", authSessionPath, "", nil, "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"enabled":false`) || !strings.Contains(w.Body.String(), `"can_write":true`) {
		t.Fatal(w.Body)
	}
	w = fixtureAuthRequest(a, "POST", "/api/v1/write", `{}`, nil, "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"local":true`) {
		t.Fatal(w.Body)
	}
}

func TestAuthConfigValidationAndFilePermissions(t *testing.T) {
	a := newFixtureAuth(t, false)
	for _, change := range []func(*AuthConfig){
		func(c *AuthConfig) { c.Username = "" },
		func(c *AuthConfig) { c.Username = " fixture" },
		func(c *AuthConfig) { c.Username = "fix\tture" },
		func(c *AuthConfig) { c.PasswordHash = strings.Replace(c.PasswordHash, "$2a$", "$2x$", 1) },
		func(c *AuthConfig) { c.PasswordHash = c.PasswordHash[:59] + "!" },
		func(c *AuthConfig) { c.PasswordHash = "plaintext" },
		func(c *AuthConfig) { c.PasswordHash = strings.Replace(c.PasswordHash, "$12$", "$04$", 1) },
		func(c *AuthConfig) { c.PasswordHash = strings.Replace(c.PasswordHash, "$12$", "$31$", 1) },
		func(c *AuthConfig) { c.PublicOrigin = "http://127.0.0.1:18080" },
		func(c *AuthConfig) { c.PublicOrigin = "https://user@hmi.example" },
		func(c *AuthConfig) { c.PublicOrigin = "https://hmi.example/path" },
		func(c *AuthConfig) { c.PublicOrigin = "https://hmi.example?x=1" },
		func(c *AuthConfig) { c.SessionTTL = time.Second },
		func(c *AuthConfig) { c.SessionTTL = 25 * time.Hour },
	} {
		c := a.config
		change(&c)
		if _, err := NewAuth(c); err == nil {
			t.Fatalf("invalid config accepted: %+v", c)
		}
	}
	path := filepath.Join(t.TempDir(), "account.json")
	data, _ := json.Marshal(a.config)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadAuthFile(path, a.config.PublicOrigin)
	if err != nil || loaded.config.AllowWrite {
		t.Fatalf("load config: %v", err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(path, 0644); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadAuthFile(path, a.config.PublicOrigin); err == nil {
			t.Fatal("world-readable credentials accepted")
		}
		if err := os.Chmod(path, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, bad := range []string{string(data) + `{}`, `{"username":"x","password":"plaintext"}`, strings.Repeat("x", 4097)} {
		if err := os.WriteFile(path, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadAuthFile(path, a.config.PublicOrigin); err == nil {
			t.Fatal("invalid file accepted")
		}
	}
}

func TestAuthRealTLSHTTPFlow(t *testing.T) {
	a := newFixtureAuth(t, true)
	s := httptest.NewUnstartedServer(a.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "protected") })))
	s.StartTLS()
	defer s.Close()
	u, _ := url.Parse(s.URL)
	a.origin = u
	a.config.PublicOrigin = s.URL
	client := s.Client()
	resp, err := client.Post(s.URL+authLoginPath, "application/json", strings.NewReader(`{"username":"fixture","password":"`+authTestPassword+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var session map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 {
		t.Fatal(session)
	}
	r, _ := http.NewRequest("POST", s.URL+"/api/v1/write", strings.NewReader(`{}`))
	r.AddCookie(resp.Cookies()[0])
	r.Header.Set("X-CSRF-Token", session["csrf_token"].(string))
	r.Header.Set("Origin", s.URL)
	got, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer got.Body.Close()
	if got.StatusCode != 200 {
		t.Fatalf("real TLS guarded request: %d", got.StatusCode)
	}
}

func TestAuthBearerIssuanceClearsAndRevokesExistingCookie(t *testing.T) {
	a := newFixtureAuth(t, true)
	cookie, _ := fixtureLogin(t, a, false)
	w := fixtureAuthRequest(a, "POST", authLoginPath, `{"username":"fixture","password":"`+authTestPassword+`","issue_token":true}`, cookie, "", "")
	if w.Code != 200 {
		t.Fatalf("token issue: %d %s", w.Code, w.Body)
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != a.cookieName || cookies[0].MaxAge != -1 {
		t.Fatal("ambient cookie was not cleared")
	}
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	token := result["bearer_token"].(string)
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", nil, "", token); w.Code != 200 {
		t.Fatal("new bearer rejected")
	}
	if w = fixtureAuthRequest(a, "GET", "/api/v1/runtime", "", cookie, "", ""); w.Code != 401 {
		t.Fatal("previous cookie not revoked")
	}
}

func TestAuthReadOnlyPreviewsRemainAuthenticatedAndCSRFProtected(t *testing.T) {
	a := newFixtureAuth(t, false)
	cookie, session := fixtureLogin(t, a, false)
	csrf := session["csrf_token"].(string)
	for _, path := range []string{"/api/v1/rules/preview", "/api/v1/import/preview"} {
		if w := fixtureAuthRequest(a, "POST", path, `{}`, nil, "", ""); w.Code != 401 {
			t.Fatal("anonymous preview accepted")
		}
		if w := fixtureAuthRequest(a, "POST", path, `{}`, cookie, "", ""); w.Code != 403 {
			t.Fatal("preview bypassed CSRF")
		}
		if w := fixtureAuthRequest(a, "POST", path, `{}`, cookie, csrf, ""); w.Code != 200 {
			t.Fatalf("readonly preview denied: %d %s", w.Code, w.Body)
		}
		if w := fixtureAuthRequest(a, "DELETE", path, `{}`, cookie, csrf, ""); w.Code != 403 {
			t.Fatal("preview method bypass")
		}
		if w := fixtureAuthRequest(a, "POST", path+"/", `{}`, cookie, csrf, ""); w.Code != 403 {
			t.Fatal("nonexact preview path bypass")
		}
	}
	for _, path := range []string{"/api/v1/import/commit", "/api/v1/rules", "/api/v1/import/upload", "/api/v1/write/preview"} {
		if w := fixtureAuthRequest(a, "POST", path, `{}`, cookie, csrf, ""); w.Code != 403 {
			t.Fatalf("write path accepted: %s", path)
		}
	}
}

func TestAuthBearerExpiryAndReadonlyAccount(t *testing.T) {
	a := newFixtureAuth(t, false)
	now := time.Now()
	a.now = func() time.Time { return now }
	_, s := fixtureLogin(t, a, true)
	token := s["bearer_token"].(string)
	if w := fixtureAuthRequest(a, "POST", "/api/v1/write", `{}`, nil, "", token); w.Code != 403 {
		t.Fatal("readonly bearer write accepted")
	}
	if w := fixtureAuthRequest(a, "POST", "/api/v1/rules/preview", `{}`, nil, "", token); w.Code != 200 {
		t.Fatal("readonly bearer preview rejected")
	}
	now = now.Add(a.config.SessionTTL)
	if w := fixtureAuthRequest(a, "POST", "/mcp", `{}`, nil, "", token); w.Code != 401 {
		t.Fatal("expired bearer accepted")
	}
}

func TestAuthLocalRejectsDNSRebindingAndPreservesDevOrigin(t *testing.T) {
	var a *Auth
	for _, authority := range []string{"attacker.example:18080", "localhost.evil:18080", "127.0.0.1.evil:18080", "0.0.0.0:18080", "192.0.2.1:18080", "[::]:18080", "localhost:bad", "localhost:", "localhost:+80", "localhost:0", "localhost:65536", "::1"} {
		for _, path := range []string{authSessionPath, "/mcp", "/api/v1/runtime", "/health", "/"} {
			r := httptest.NewRequest("GET", "http://127.0.0.1:18080"+path, nil)
			r.Host = authority
			r.Header.Set("Origin", "http://"+authority)
			r.Header.Set("X-Forwarded-Host", "127.0.0.1:18080")
			w := httptest.NewRecorder()
			a.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("rebound host passed") })).ServeHTTP(w, r)
			if w.Code != 403 {
				t.Fatalf("authority %q path %q status %d", authority, path, w.Code)
			}
		}
	}
	for _, authority := range []string{"localhost:18080", "LOCALHOST:18080", "127.0.0.1:18080", "[::1]:18080", "localhost", "127.0.0.1", "[::1]"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:18080"+authSessionPath, nil)
		r.Host = authority
		w := httptest.NewRecorder()
		a.Handler(http.NotFoundHandler()).ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("local authority %q rejected: %d", authority, w.Code)
		}
	}
	for _, origin := range []string{"http://localhost:5173", "http://evil.example"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:18080"+authSessionPath, nil)
		r.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		LocalAuthHandler(http.NotFoundHandler(), "http://localhost:5173").ServeHTTP(w, r)
		want := ""
		if origin == "http://localhost:5173" {
			want = origin
		}
		if w.Code != 200 || w.Header().Get("Access-Control-Allow-Origin") != want {
			t.Fatalf("dev origin bootstrap failed: %d %+v", w.Code, w.Header())
		}
	}
}

func TestAuthLocalPreflightCannotBypassHostGuard(t *testing.T) {
	r := httptest.NewRequest("OPTIONS", "http://attacker.example/api/v1/auth/session", nil)
	r.Header.Set("Origin", "http://localhost:5173")
	w := httptest.NewRecorder()
	LocalAuthHandler(http.NotFoundHandler(), "http://localhost:5173").ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("preflight bypassed loopback host guard: %d", w.Code)
	}
}

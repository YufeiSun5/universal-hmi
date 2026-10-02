package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"golang.org/x/crypto/bcrypt"
)

const (
	authSessionPath    = "/api/v1/auth/session"
	authLoginPath      = "/api/v1/auth/login"
	authLogoutPath     = "/api/v1/auth/logout"
	maxAuthSessions    = 256
	maxAuthClients     = 1024
	authWindow         = time.Minute
	authAttemptsPerIP  = 10
	authAttemptsGlobal = 60
)

// AuthConfig is an explicitly provisioned single-user account. There are no default credentials.
// AllowWrite must be opted in; it grants HTTP mutations, while MCP also has its own write gate.
// PasswordHash must be a bcrypt hash with cost 12 through 14. Sessions never survive restart.
type AuthConfig struct {
	Username     string        `json:"username"`
	PasswordHash string        `json:"password_hash"`
	AllowWrite   bool          `json:"allow_write"`
	PublicOrigin string        `json:"-"`
	SessionTTL   time.Duration `json:"-"`
}

// Principal is attached by Auth.Handler and is shared by HTTP and MCP transports.
type Principal struct {
	Username   string
	AllowWrite bool
	Local      bool
}
type principalKey struct{}

func PrincipalFromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey{}).(Principal)
	return p, ok
}

type authSession struct {
	CSRF    string
	Expires time.Time
	Bearer  bool
}
type authAttempts struct {
	Started time.Time
	Count   int
}

type Auth struct {
	config     AuthConfig
	origin     *url.URL
	cookieName string
	mu         sync.Mutex
	sessions   map[[32]byte]authSession
	attempts   map[string]authAttempts
	global     authAttempts
	loginSlots chan struct{}
	now        func() time.Time
}

var authBcryptPattern = regexp.MustCompile(`^\$2[aby]\$(12|13|14)\$[./A-Za-z0-9]{53}$`)

func NewAuth(config AuthConfig) (*Auth, error) {
	if config.Username == "" || len(config.Username) > 128 || strings.TrimSpace(config.Username) != config.Username || strings.IndexFunc(config.Username, unicode.IsControl) >= 0 {
		return nil, fmt.Errorf("auth username must be 1..128 bytes without surrounding whitespace or control characters")
	}
	cost, err := bcrypt.Cost([]byte(config.PasswordHash))
	if err != nil || cost < 12 || cost > 14 || !authBcryptPattern.MatchString(config.PasswordHash) {
		return nil, fmt.Errorf("auth password_hash must be a bcrypt hash with cost 12..14")
	}
	u, err := url.Parse(config.PublicOrigin)
	if err != nil || u == nil || u.Hostname() == "" || u.User != nil || u.ForceQuery || u.RawQuery != "" || u.Fragment != "" || u.Path != "" || u.Opaque != "" || u.Scheme != "https" {
		return nil, fmt.Errorf("public origin must be an exact HTTPS origin without path, credentials, query or fragment")
	}
	if config.SessionTTL == 0 {
		config.SessionTTL = 8 * time.Hour
	}
	if config.SessionTTL < time.Minute || config.SessionTTL > 24*time.Hour {
		return nil, fmt.Errorf("session duration must be between 1 minute and 24 hours")
	}
	cookie := "__Host-hmi_session"
	return &Auth{config: config, origin: u, cookieName: cookie,
		sessions: make(map[[32]byte]authSession), attempts: make(map[string]authAttempts),
		loginSlots: make(chan struct{}, 2), now: time.Now}, nil
}

// IsLoopbackHost accepts literal loopback addresses or localhost, never arbitrary DNS names.
func IsLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	return strings.EqualFold(host, "localhost") || (ip != nil && ip.IsLoopback())
}

// isLoopbackAuthority prevents DNS-rebinding access to an unauthenticated local
// listener. It never resolves arbitrary hostnames or trusts forwarding headers.
func isLoopbackAuthority(authority string) bool {
	host, port, err := net.SplitHostPort(authority)
	if err != nil {
		if strings.HasPrefix(authority, "[") && strings.HasSuffix(authority, "]") {
			ip := net.ParseIP(authority[1 : len(authority)-1])
			return ip != nil && ip.IsLoopback()
		}
		return !strings.ContainsAny(authority, ":/[]@?#") && IsLoopbackHost(authority)
	}
	if !IsLoopbackHost(host) || port == "" {
		return false
	}
	for _, ch := range port {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	number, err := strconv.Atoi(port)
	return err == nil && number >= 1 && number <= 65535
}

// LocalAuthHandler preserves the explicit development-origin policy for the
// unauthenticated session bootstrap too. Authenticated deployments disallow it.
func LocalAuthHandler(next http.Handler, devOrigin string) http.Handler {
	guarded := originGuard((*Auth)(nil).Handler(next), devOrigin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check before originGuard can terminate a development preflight.
		if !isLoopbackAuthority(r.Host) {
			writeError(w, http.StatusForbidden, "host_rejected", "Local mode requires a loopback request host")
			return
		}
		guarded.ServeHTTP(w, r)
	})
}

// Handler must wrap the entire application, including /mcp, exactly once. A nil Auth
// preserves the explicitly local mode and publishes enabled:false for client bootstrapping.
func (a *Auth) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if a == nil {
			if !isLoopbackAuthority(r.Host) {
				writeError(w, http.StatusForbidden, "host_rejected", "Local mode requires a loopback request host")
				return
			}
			if r.URL.Path == authSessionPath {
				if r.Method != http.MethodGet {
					authMethodError(w)
					return
				}
				w.Header().Set("Cache-Control", "no-store")
				writeJSON(w, 200, map[string]any{"enabled": false, "authenticated": false, "can_write": true})
				return
			}
			p := Principal{Username: "local", AllowWrite: true, Local: true}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, p)))
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		if !a.requestOriginAllowed(r) {
			writeError(w, http.StatusForbidden, "origin_rejected", "Request host, transport or origin is not allowed")
			return
		}
		if r.URL.Path == "/health" && (r.Method == http.MethodGet || r.Method == http.MethodHead) {
			writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi", "authentication_required": true})
			return
		}
		if r.URL.Path == authLoginPath || r.URL.Path == "/login" {
			a.login(w, r)
			return
		}
		session, key, authenticated := a.session(r)
		if r.URL.Path == authSessionPath {
			if r.Method != http.MethodGet {
				authMethodError(w)
				return
			}
			a.sessionResponse(w, session, authenticated, "")
			return
		}
		if !authenticated {
			if r.Method == http.MethodGet && !strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/mcp" {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
				return
			}
			w.Header().Set("WWW-Authenticate", `Bearer realm="universal-hmi"`)
			writeError(w, http.StatusUnauthorized, "authentication_required", "Sign in to continue")
			return
		}
		unsafe := r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions
		if unsafe && !session.Bearer && !constantTimeEqual(r.Header.Get("X-CSRF-Token"), session.CSRF) {
			writeError(w, http.StatusForbidden, "csrf_rejected", "A current session CSRF token is required")
			return
		}
		if r.URL.Path == authLogoutPath {
			if r.Method != http.MethodPost {
				authMethodError(w)
				return
			}
			a.mu.Lock()
			delete(a.sessions, key)
			a.mu.Unlock()
			a.clearCookie(w)
			writeJSON(w, 200, map[string]any{"logged_out": true})
			return
		}
		// MCP's POST envelope contains both read and write methods. Its tool registry
		// authorizes each dispatch using the principal and separate MCP write flag.
		if unsafe && r.URL.Path != "/mcp" && !readOnlyHTTPPreview(r.Method, r.URL.Path) && !a.config.AllowWrite {
			writeError(w, http.StatusForbidden, "write_forbidden", "This account is read-only")
			return
		}
		p := Principal{Username: a.config.Username, AllowWrite: a.config.AllowWrite}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, p)))
	})
}

// readOnlyHTTPPreview names the only non-mutating POST operations. Keep this
// fixed allowlist aligned with the MCP registry; never infer safety from a suffix.
func readOnlyHTTPPreview(method, path string) bool {
	return method == http.MethodPost && (path == "/api/v1/rules/preview" || path == "/api/v1/import/preview")
}

func (a *Auth) requestOriginAllowed(r *http.Request) bool {
	if !strings.EqualFold(r.Host, a.origin.Host) || (r.TLS != nil) != (a.origin.Scheme == "https") {
		return false
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != a.config.PublicOrigin {
		return false
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site == "cross-site" || site == "same-site" {
		return false
	}
	return true
}

func (a *Auth) session(r *http.Request) (authSession, [32]byte, bool) {
	var token string
	bearer := false
	cookie, err := r.Cookie(a.cookieName)
	if auth := r.Header.Get("Authorization"); auth != "" {
		parts := strings.Split(auth, " ")
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || err == nil {
			return authSession{}, [32]byte{}, false
		}
		token, bearer = parts[1], true
	} else if err == nil {
		token = cookie.Value
	}
	if len(token) != 43 {
		return authSession{}, [32]byte{}, false
	}
	key := sha256.Sum256([]byte(token))
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[key]
	if !ok || s.Bearer != bearer {
		return authSession{}, key, false
	}
	if !a.now().Before(s.Expires) {
		delete(a.sessions, key)
		return authSession{}, key, false
	}
	return s, key, true
}

func (a *Auth) sessionResponse(w http.ResponseWriter, s authSession, authenticated bool, bearerToken string) {
	result := map[string]any{"enabled": true, "authenticated": authenticated, "can_write": false}
	if authenticated {
		result["username"], result["can_write"], result["expires_at"] = a.config.Username, a.config.AllowWrite, s.Expires.UTC().Format(time.RFC3339)
		if !s.Bearer {
			result["csrf_token"] = s.CSRF
		}
		if bearerToken != "" {
			result["bearer_token"] = bearerToken
			result["token_type"] = "Bearer"
		}
	}
	writeJSON(w, 200, result)
}

func constantTimeEqual(a, b string) bool {
	x, y := sha256.Sum256([]byte(a)), sha256.Sum256([]byte(b))
	return subtle.ConstantTimeCompare(x[:], y[:]) == 1
}
func authMethodError(w http.ResponseWriter) {
	writeError(w, 405, "method_not_allowed", "Method is not allowed")
}
func authRandomToken() (string, error) {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value[:]), nil
}
func (a *Auth) setCookie(w http.ResponseWriter, name, value string, ttl time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", HttpOnly: true,
		Secure: a.origin.Scheme == "https", SameSite: http.SameSiteStrictMode,
		MaxAge: int(ttl.Seconds()), Expires: a.now().Add(ttl).UTC()})
}
func (a *Auth) clearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: a.cookieName, Path: "/", HttpOnly: true,
		Secure: a.origin.Scheme == "https", SameSite: http.SameSiteStrictMode,
		MaxAge: -1, Expires: time.Unix(1, 0)})
}

func (a *Auth) allowAttempt(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	for key, value := range a.attempts {
		if now.Sub(value.Started) >= authWindow {
			delete(a.attempts, key)
		}
	}
	if now.Sub(a.global.Started) >= authWindow {
		a.global = authAttempts{Started: now}
	}
	entry, exists := a.attempts[host]
	if !exists {
		entry = authAttempts{Started: now}
	}
	if a.global.Count >= authAttemptsGlobal || entry.Count >= authAttemptsPerIP || (!exists && len(a.attempts) >= maxAuthClients) {
		return false
	}
	entry.Count++
	a.attempts[host] = entry
	a.global.Count++
	return true
}

func (a *Auth) login(w http.ResponseWriter, r *http.Request) {
	form := r.URL.Path == "/login"
	if form && r.Method == http.MethodGet {
		a.loginPage(w, "", 200)
		return
	}
	if r.Method != http.MethodPost {
		authMethodError(w)
		return
	}
	if !a.allowAttempt(r.RemoteAddr) {
		w.Header().Set("Retry-After", "60")
		writeError(w, 429, "login_rate_limited", "Too many login attempts; try again later")
		return
	}
	select {
	case a.loginSlots <- struct{}{}:
		defer func() { <-a.loginSlots }()
	default:
		w.Header().Set("Retry-After", "5")
		writeError(w, 429, "login_rate_limited", "Login is busy; try again later")
		return
	}
	var input struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		IssueToken bool   `json:"issue_token"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if form {
		if err != nil || media != "application/x-www-form-urlencoded" || r.ParseForm() != nil {
			writeError(w, 400, "invalid_request", "Invalid login form")
			return
		}
		cookie, err := r.Cookie(a.cookieName + "_login")
		if err != nil || !constantTimeEqual(cookie.Value, r.PostForm.Get("csrf_token")) || len(cookie.Value) != 43 {
			writeError(w, 403, "csrf_rejected", "Reload the login page and try again")
			return
		}
		input.Username, input.Password = r.PostForm.Get("username"), r.PostForm.Get("password")
	} else {
		if err != nil || media != "application/json" {
			writeError(w, 415, "invalid_request", "Login requires application/json")
			return
		}
		d := json.NewDecoder(r.Body)
		d.DisallowUnknownFields()
		if d.Decode(&input) != nil || d.Decode(new(any)) != io.EOF {
			writeError(w, 400, "invalid_request", "Expected one login object")
			return
		}
	}
	// Always run bcrypt, including unknown usernames, so the account cannot be enumerated.
	validSize := len(input.Password) > 0 && len(input.Password) <= 72 && len(input.Username) <= 128
	password := input.Password
	if !validSize {
		password = "invalid oversized credential"
	}
	passwordOK := bcrypt.CompareHashAndPassword([]byte(a.config.PasswordHash), []byte(password)) == nil
	userOK := constantTimeEqual(input.Username, a.config.Username)
	if !validSize || !passwordOK || !userOK {
		if form {
			a.loginPage(w, "用户名或密码不正确", 401)
		} else {
			writeError(w, 401, "invalid_credentials", "Incorrect username or password")
		}
		return
	}
	token, err := authRandomToken()
	if err != nil {
		writeError(w, 500, "session_failed", "Could not create session")
		return
	}
	csrf, err := authRandomToken()
	if err != nil {
		writeError(w, 500, "session_failed", "Could not create session")
		return
	}
	now := a.now()
	session := authSession{CSRF: csrf, Expires: now.Add(a.config.SessionTTL), Bearer: input.IssueToken}
	_, oldKey, hadSession := a.session(r)
	a.mu.Lock()
	for k, s := range a.sessions {
		if !now.Before(s.Expires) {
			delete(a.sessions, k)
		}
	}
	if hadSession {
		delete(a.sessions, oldKey)
	}
	if len(a.sessions) >= maxAuthSessions {
		a.mu.Unlock()
		writeError(w, 503, "session_limit", "Session limit reached; sign out elsewhere or wait for expiry")
		return
	}
	a.sessions[sha256.Sum256([]byte(token))] = session
	a.mu.Unlock()
	if input.IssueToken {
		// Rotating a browser session into a bearer session must remove its ambient cookie.
		if _, err := r.Cookie(a.cookieName); err == nil {
			a.clearCookie(w)
		}
		a.sessionResponse(w, session, true, token)
		return
	}
	a.setCookie(w, a.cookieName, token, a.config.SessionTTL)
	if form {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	a.sessionResponse(w, session, true, "")
}

var loginTemplate = template.Must(template.New("login").Parse(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>登录 · Universal HMI</title><style>body{font:15px system-ui;background:#151b25;color:#e8edf7;display:grid;min-height:94vh;place-items:center}main{width:min(340px,85vw);padding:28px;background:#202938;border:1px solid #46556c;border-radius:8px}h1{font-size:22px}label{display:block;margin-top:18px}input,button{box-sizing:border-box;width:100%;padding:10px;margin-top:8px;font:inherit;border-radius:4px;border:1px solid #67778e}button{margin-top:22px;background:#3076cf;color:white;cursor:pointer}.error{color:#ffb3ae}small{color:#b7c5d8}</style></head><body><main><h1>Universal HMI</h1><p>登录工程工作空间</p>{{if .Error}}<p class="error" role="alert">{{.Error}}</p>{{end}}<form method="post" action="/login"><input type="hidden" name="csrf_token" value="{{.CSRF}}"><label for="username">用户名</label><input id="username" name="username" autocomplete="username" maxlength="128" required autofocus><label for="password">密码</label><input id="password" name="password" type="password" autocomplete="current-password" maxlength="72" required><button type="submit">登录</button></form><p><small>会话到期后需重新登录。请联系管理员获取访问权限。</small></p></main></body></html>`))

func (a *Auth) loginPage(w http.ResponseWriter, message string, status int) {
	token, err := authRandomToken()
	if err != nil {
		writeError(w, 500, "session_failed", "Could not prepare login")
		return
	}
	a.setCookie(w, a.cookieName+"_login", token, 10*time.Minute)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	w.WriteHeader(status)
	_ = loginTemplate.Execute(w, struct{ Error, CSRF string }{message, token})
}

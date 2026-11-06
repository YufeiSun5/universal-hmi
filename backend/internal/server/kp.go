package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

type KPOptions struct {
	PublicReadOnly       bool
	Identity             *identity.Service
	PublicOrigin, WebDir string
	KPOrigins            []string
	LocalTrial           bool
}

// KPHandler supplies a public embedded shell and two separate authenticated
// channels. It never invokes unauthenticated local business mode as a fallback.
func KPHandler(bridge *kpbridge.Service, o KPOptions, legacy, business http.Handler) (http.Handler, error) {
	if bridge.ManagedReadOnlyMode() && (!o.PublicReadOnly || o.Identity == nil || o.LocalTrial) {
		return nil, fmt.Errorf("native KP token login requires managed public read-only identity")
	}
	if o.Identity != nil && (legacy == nil || o.LocalTrial) {
		return nil, fmt.Errorf("managed KP requires TLS identity handler and trusted verifier")
	}
	u, allowed, frames, e := validateKPOptions(o)
	if e != nil {
		return nil, e
	}
	static := http.StripPrefix("/kp/", http.FileServer(http.Dir(o.WebDir)))
	var rateMu sync.Mutex
	var rateStart time.Time
	var rateCount int
	limited := func() bool {
		rateMu.Lock()
		defer rateMu.Unlock()
		now := time.Now()
		if now.Sub(rateStart) >= time.Minute {
			rateStart = now
			rateCount = 0
		}
		rateCount++
		return rateCount > 120
	}
	return kpHTTPHandler(bridge, o, legacy, business, u, allowed, frames, static, limited), nil
}

// ValidateKPOptions permits startup validation before business data is opened.
func ValidateKPOptions(o KPOptions) error {
	_, _, _, e := validateKPOptions(o)
	return e
}

func validateKPOptions(o KPOptions) (*url.URL, map[string]bool, []string, error) {
	u, e := url.Parse(o.PublicOrigin)
	if e != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return nil, nil, nil, fmt.Errorf("KP requires an exact public origin")
	}
	if o.LocalTrial {
		if u.Scheme != "http" || !IsLoopbackHost(u.Hostname()) {
			return nil, nil, nil, fmt.Errorf("KP local trial requires a loopback HTTP origin")
		}
	} else if u.Scheme != "https" {
		return nil, nil, nil, fmt.Errorf("KP requires HTTPS")
	}
	if len(o.KPOrigins) == 0 || len(o.KPOrigins) > 8 {
		return nil, nil, nil, fmt.Errorf("configure one to eight exact KP origins")
	}
	allowed := map[string]bool{o.PublicOrigin: true}
	frames := []string{"'self'"}
	for _, v := range o.KPOrigins {
		p, err := url.Parse(v)
		if err != nil || p.Hostname() == "" || p.User != nil || p.Path != "" || p.RawQuery != "" || p.Fragment != "" || p.ForceQuery || (p.Scheme != "https" && !(p.Scheme == "http" && (o.PublicReadOnly || (o.LocalTrial && IsLoopbackHost(p.Hostname()))))) {
			return nil, nil, nil, fmt.Errorf("invalid KP origin")
		}
		allowed[v] = true
		frames = append(frames, v)
	}
	return u, allowed, frames, nil
}

func kpHTTPHandler(bridge *kpbridge.Service, o KPOptions, legacy, business http.Handler, u *url.URL, allowed map[string]bool, frames []string, static http.Handler, limited func() bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		if !strings.EqualFold(r.Host, u.Host) || (r.TLS != nil) != (u.Scheme == "https") {
			writeError(w, 403, "origin_rejected", "Request host or transport is not allowed")
			return
		}
		p := r.URL.Path
		if p == "/blank.html" {
			serveBlankPage(w, r, strings.Join(frames, " "))
			return
		}
		if p == "/kp" {
			http.Redirect(w, r, "/kp/", http.StatusTemporaryRedirect)
			return
		}
		if strings.HasPrefix(p, "/kp/") {
			w.Header().Set("Content-Security-Policy", "frame-ancestors "+strings.Join(frames, " ")+"; base-uri 'self'; object-src 'none'")
			if r.Method != "GET" && r.Method != "HEAD" {
				authMethodError(w)
				return
			}
			if o.WebDir == "" {
				writeError(w, 503, "web_not_available", "Web build is not configured")
				return
			}
			name := strings.TrimPrefix(p, "/kp/")
			if name == "" || name == "index.html" {
				b, err := os.ReadFile(filepath.Join(o.WebDir, "index.html"))
				if err != nil {
					writeError(w, 503, "web_not_available", "Web build is not available")
					return
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				if r.Method != "HEAD" {
					_, _ = w.Write([]byte(strings.Replace(string(b), `<base href="/">`, `<base href="/kp/">`, 1)))
				}
				return
			}
			if path.Clean(name) != name || strings.Contains(name, "\\") || strings.HasPrefix(name, ".") {
				http.NotFound(w, r)
				return
			}
			info, err := os.Stat(filepath.Join(o.WebDir, filepath.FromSlash(name)))
			if err != nil || !info.Mode().IsRegular() {
				http.NotFound(w, r)
				return
			}
			// These build resources contain no session or business data. Keep
			// their bodies in the browser cache, but revalidate every reuse so
			// deploying a new build never relies on a long freshness lifetime.
			if name == "main.dart.js" || strings.HasPrefix(name, "canvaskit/") || strings.HasPrefix(name, "assets/") {
				w.Header().Set("Cache-Control", "private, no-cache")
			}
			static.ServeHTTP(w, r)
			return
		}
		kpPath := strings.HasPrefix(p, "/api/v1/kp/")
		webPath := strings.HasPrefix(p, "/api/v1/web/")
		if kpPath || webPath {
			origin := r.Header.Get("Origin")
			if origin != "" && ((kpPath && !allowed[origin]) || (webPath && origin != o.PublicOrigin)) {
				writeError(w, 403, "origin_rejected", "Origin is not allowed")
				return
			}
			if kpPath && origin != "" {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Add("Vary", "Origin")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
				w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
			}
			if r.Method == "OPTIONS" {
				w.WriteHeader(204)
				return
			}
			if (p == "/api/v1/kp/bootstrap" || p == "/api/v1/web/redeem") && limited() {
				writeError(w, 429, "bridge_rate_limited", "Too many session establishment attempts")
				return
			}
			kpOperationWithOptions(w, r, bridge, o)
			return
		}
		if p == "/health" && (r.Method == "GET" || r.Method == "HEAD") {
			writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi", "authentication_required": true, "kp_bridge": true, "local_trial": o.LocalTrial})
			return
		}
		if secret := bearer(r); secret != "" {
			v, err := bridge.Me(secret)
			if err == nil {
				if o.Identity != nil {
					legacy.ServeHTTP(w, r)
					return
				}
				if r.Header.Get("Origin") != "" && r.Header.Get("Origin") != o.PublicOrigin {
					writeError(w, 403, "origin_rejected", "Origin is not allowed")
					return
				}
				if r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS" && p != "/mcp" && !readOnlyHTTPPreview(r.Method, p) && !v.CanWrite {
					writeError(w, 403, "write_forbidden", "This user is read-only")
					return
				}
				principal := Principal{Username: v.Username, AllowWrite: v.CanWrite, UserID: v.User.ID, Provider: v.SourceID, WorkspaceID: v.User.WorkspaceID, Role: v.User.Role}
				r = withStreamAccess(r, func() bool { _, err := bridge.Me(secret); return err == nil })
				business.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, principal)))
				return
			}
		}
		if legacy != nil {
			legacy.ServeHTTP(w, r)
			return
		}
		if p == authSessionPath && r.Method == "GET" {
			writeJSON(w, 200, map[string]any{"enabled": true, "authenticated": false, "can_write": false, "login_mode": "kp"})
			return
		}
		writeError(w, 401, "authentication_required", "Enter through KP to continue")
	})
}
func bearer(r *http.Request) string {
	p := strings.Split(r.Header.Get("Authorization"), " ")
	if len(p) == 2 && strings.EqualFold(p[0], "Bearer") {
		return p[1]
	}
	return ""
}
func kpError(w http.ResponseWriter, e error) {
	var v *kpbridge.Error
	if errors.As(e, &v) {
		message := map[string]string{
			"user_not_provisioned":           "KP 账号尚未映射，请在开发态的 KP 接入中配置账号映射",
			"identity_not_verified":          "KP 登录令牌无效或已失效，请重新登录 KP",
			"identity_proof_required":        "未取得 KP 登录令牌，请先登录 KP",
			"identity_mismatch":              "KP 当前账号已改变，请重新打开画面",
			"identity_verifier_unavailable":  "监控后台无法访问 KP 核验接口，请检查 KP 后台服务地址及证书",
			"identity_verifier_bad_response": "KP 核验接口返回了不支持的数据，请检查工程名和接口版本",
			"bridge_reconfigured":            "KP 配置已更新，请重新打开画面",
		}[v.Code]
		if message == "" {
			message = v.Code
		}
		writeError(w, v.Status, v.Code, message)
	} else {
		writeError(w, 503, "bridge_unavailable", "Linked session service is unavailable")
	}
}
func kpDecode(w http.ResponseWriter, r *http.Request, v any) bool {
	if r.Method != "POST" {
		authMethodError(w)
		return false
	}
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32*1024))
	if err != nil || !strings.HasPrefix(strings.TrimSpace(string(b)), "{") {
		writeError(w, 400, "invalid_request", "Expected one valid JSON object")
		return false
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		writeError(w, 400, "invalid_request", "Expected one valid JSON object")
		return false
	}
	return true
}
func observedIP(r *http.Request) string {
	h, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		return ""
	}
	return h
}
func kpOperation(w http.ResponseWriter, r *http.Request, s *kpbridge.Service, managed ...*identity.Service) {
	var ids *identity.Service
	if len(managed) > 0 {
		ids = managed[0]
	}
	kpOperationWithOptions(w, r, s, KPOptions{Identity: ids})
}
func kpOperationWithOptions(w http.ResponseWriter, r *http.Request, s *kpbridge.Service, options KPOptions) {
	var result any
	var err error
	switch r.URL.Path {
	case "/api/v1/kp/bootstrap":
		var b kpbridge.Bootstrap
		if !kpDecode(w, r, &b) {
			return
		}
		result, err = s.Bootstrap(r.Context(), b, observedIP(r))
	case "/api/v1/kp/poll", "/api/v1/kp/close":
		var c struct {
			kpbridge.Channel
			IdentityProof string `json:"identityProof,omitempty"`
		}
		if !kpDecode(w, r, &c) {
			return
		}
		if strings.HasSuffix(r.URL.Path, "/poll") {
			result, err = s.PollVerified(r.Context(), c.Channel, c.IdentityProof)
		} else {
			result, err = s.Close(c.Channel)
		}
	case "/api/v1/kp/logoff-result":
		var c kpbridge.LogoffResult
		if !kpDecode(w, r, &c) {
			return
		}
		result, err = s.LogoffResult(c)
	case "/api/v1/web/redeem":
		var b struct {
			Ticket string `json:"ticket"`
		}
		if !kpDecode(w, r, &b) {
			return
		}
		result, err = s.Redeem(b.Ticket, observedIP(r))
	case "/api/v1/web/me", "/api/v1/web/status":
		if r.Method != "GET" {
			authMethodError(w)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/me") {
			result, err = s.Me(bearer(r))
		} else {
			result, err = s.Status(bearer(r))
		}
	case "/api/v1/web/logout":
		var b struct{}
		if !kpDecode(w, r, &b) {
			return
		}
		result, err = s.Logout(bearer(r))
	default:
		writeError(w, 404, "not_found", "Bridge operation is not available")
		return
	}
	if err != nil {
		kpError(w, err)
		return
	}
	ids := options.Identity
	resolve := func(token string) (identity.User, identity.Session, error) {
		if options.PublicReadOnly {
			if leaf := publicDeviceLeaf(r); leaf != nil {
				return ids.ResolveDevice(token, false, leaf)
			}
			return ids.ResolveChannel(token, false, "public:web")
		}
		return ids.Resolve(token, false)
	}
	var linkedUser identity.User
	if ids != nil {
		if reply, ok := result.(kpbridge.WebReply); ok && reply.Authenticated {
			token := bearer(r)
			if reply.WebToken != "" {
				token = reply.WebToken
				valid := func() bool { _, e := s.Me(token); return e == nil }
				if s.TrialMode() && options.PublicReadOnly {
					err = ids.LinkKPTrial(reply.User.ID, token, publicDeviceLeaf(r), valid)
				} else if s.NativeTokenMode() && options.PublicReadOnly {
					err = ids.LinkKPToken(reply.User.ID, token, publicDeviceLeaf(r), valid)
				} else {
					err = ids.LinkFederated(reply.User.ID, token, reply.MFA, reply.AuthenticatedAt, valid)
				}
			}
			if err == nil {
				linkedUser, _, err = resolve(token)
			}
			if err != nil {
				writeError(w, 401, "identity_required", "KP账号映射或登录授权不可用，请使用普通登录或联系管理员")
				return
			}
		}
	}
	// Keep a uniform success marker for KP versions whose callback does not
	// expose the HTTP status separately.
	encoded, _ := json.Marshal(result)
	var response map[string]any
	_ = json.Unmarshal(encoded, &response)
	if ids != nil {
		if options.PublicReadOnly {
			linkedUser.Grants = publicReadGrants(linkedUser.Grants)
		}
		response["security_model"] = "identity-v1"
		response["can_write"] = linkedUser.Grants.Control
		response["can_develop"] = linkedUser.Grants.Develop()
		response["can_manage_users"] = linkedUser.Grants.Manage()
		response["grants"] = linkedUser.Grants
	}
	response["ok"] = true
	if s.TrialMode() {
		response["authentication_mode"] = "kp-trial"
	}
	writeJSON(w, 200, response)
}

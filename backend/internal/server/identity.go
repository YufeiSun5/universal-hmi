package server

import (
	"context"
	"errors"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/networkaccess"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

type IdentityOptions struct {
	KPSettings     *KPSettings
	NetworkAccess  *networkaccess.Service
	Origin         string
	LocalSetup     bool
	PublicReadOnly bool
	// LANDevelopment is explicit listener configuration, never a client hint.
	LANDevelopment bool
	// LANHTTP is set only by the private LAN listener's composition root.
	LANHTTP    bool
	KPWebEmbed bool
	captchas   *loginCaptchas
}

// Cookie retention supports browser/Android reopening. It is not a server-side
// session deadline; a successful session read renews this client-side retention.
const identityCookieMaxAge = 365 * 24 * 60 * 60

// IdentityHandler establishes one Actor for HTTP, SSE and MCP. LocalSetup is an
// explicit single-machine evaluation mode, never inferred from proxy headers.
func IdentityHandler(service *identity.Service, options IdentityOptions, next http.Handler) (http.Handler, error) {
	if options.LANDevelopment && (!options.PublicReadOnly || options.LocalSetup || options.KPWebEmbed) {
		return nil, fmt.Errorf("LAN engineering requires an independent remote identity listener")
	}
	if options.PublicReadOnly && options.LocalSetup {
		return nil, fmt.Errorf("public readonly identity cannot use local setup")
	}
	captchas := options.captchas
	if captchas == nil {
		captchas = newLoginCaptchas()
	}
	channel := ""
	if options.PublicReadOnly {
		channel = "public:web"
	}
	if options.LANDevelopment {
		channel = "lan:engineering"
	}
	u, err := url.Parse(options.Origin)
	if err != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return nil, fmt.Errorf("invalid identity origin")
	}
	if options.LANHTTP {
		if options.LocalSetup || !options.PublicReadOnly || options.KPWebEmbed || u.Scheme != "http" || !networkaccess.IsPrivateIPv4(u.Hostname()) {
			return nil, fmt.Errorf("LAN HTTP requires a private IPv4 remote identity listener")
		}
		channel = "lan:http:web"
		if options.LANDevelopment {
			channel = "lan:http:engineering"
		}
	}
	if options.LocalSetup {
		if u.Scheme != "http" || !IsLoopbackHost(u.Hostname()) {
			return nil, fmt.Errorf("local identity setup requires loopback HTTP")
		}
	} else if u.Scheme != "https" && !options.LANHTTP {
		return nil, fmt.Errorf("identity requires HTTPS")
	}
	if !options.LocalSetup && service.PasswordMinimum() < 7 {
		return nil, fmt.Errorf("local password policy requires loopback identity mode")
	}
	cookieName := "__Host-hmi_identity"
	if options.LocalSetup {
		cookieName = "hmi_local_identity"
	}
	if options.LANHTTP {
		cookieName = "hmi_lan_identity"
	}
	response := func(w http.ResponseWriter, user identity.User, s identity.Session, token string) {
		v := map[string]any{"enabled": true, "authenticated": user.ID != "", "can_write": false, "can_develop": false, "can_manage_users": false, "security_model": "identity-v1", "setup_required": service.NeedsSetup(), "password_min_length": service.PasswordMinimum()}
		v["captcha_required"] = options.PublicReadOnly
		if user.ID != "" {
			v["mfa_required"] = !options.LocalSetup && !options.PublicReadOnly && !s.MFA
			v["mfa_verified"] = s.MFA
			v["username"] = user.Username
			v["user_id"] = user.ID
			if user.Grants.ManageUsers() {
				v["grant_limits"] = user.Grants
			}
			if options.PublicReadOnly && !(options.LANDevelopment && user.Grants.Develop()) {
				user.Grants = publicReadGrants(user.Grants)
			}
			v["channel"] = s.Channel
			v["can_write"] = user.Grants.Control
			v["can_develop"] = user.Grants.Develop()
			v["can_manage_users"] = user.Grants.ManageUsers()
			v["can_manage_security"] = !options.PublicReadOnly && user.Grants.Manage()
			v["can_approve_devices"] = user.Grants.ApproveDevices()
			v["can_manage_certificates"] = user.Grants.ManageCertificates()
			v["can_edit_equipment"] = user.Grants.EditEquipment()
			v["can_edit_equipment_navigation"] = user.Grants.EditEquipment() && user.Grants.AllStations
			v["grants"] = user.Grants
			if s.Expires.IsZero() {
				v["session_policy"] = "no_timeout"
				// Older installed clients require this field. Updated clients use
				// session_policy; this compatibility hint is not a server deadline.
				v["expires_at"] = time.Now().UTC().Add(8 * time.Hour).Format(time.RFC3339)
			} else {
				v["expires_at"] = s.Expires.UTC().Format(time.RFC3339)
			}
			if !s.Bearer {
				v["csrf_token"] = s.CSRF
			}
			if token != "" && s.Bearer {
				v["bearer_token"] = token
				v["token_type"] = "Bearer"
			}
		}
		writeJSON(w, 200, v)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if options.LANHTTP {
			host, _, e := net.SplitHostPort(r.RemoteAddr)
			if e != nil || !networkaccess.IsPrivateIPv4(host) || r.Header.Get("Forwarded") != "" || r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("X-Forwarded-Host") != "" || r.Header.Get("X-Forwarded-Proto") != "" {
				identityReject(w, r, 403, "public_peer_denied", "此入口仅接受内网客户端直连")
				return
			}
		}
		leaf := publicDeviceLeaf(r)
		resolve := func(token string, touch bool) (identity.User, identity.Session, error) {
			if options.PublicReadOnly && leaf != nil {
				return service.ResolveDevice(token, touch, leaf)
			}
			return service.ResolveChannel(token, touch, channel)
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		embed := options.PublicReadOnly && options.KPWebEmbed && !options.LocalSetup
		// Public read-only pages may be embedded by any platform, including a
		// certificate-authenticated browser and nested GIS frames. Omitting the
		// ancestor restriction also supports containers with opaque/file origins.
		policy := "base-uri 'self'; object-src 'none'"
		if !embed {
			w.Header().Set("X-Frame-Options", "DENY")
			policy = "frame-ancestors 'self'; " + policy
		} else {
			w.Header().Del("X-Frame-Options")
		}
		w.Header().Set("Content-Security-Policy", policy)
		if u.Scheme == "https" {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		site := r.Header.Get("Sec-Fetch-Site")
		kpNavigation := embed && r.URL.Path == "/" && r.Method == http.MethodGet && r.Header.Get("Sec-Fetch-Mode") == "navigate" && (r.Header.Get("Sec-Fetch-Dest") == "iframe" || r.Header.Get("Sec-Fetch-Dest") == "frame")
		if !strings.EqualFold(r.Host, u.Host) || (r.TLS != nil) != (u.Scheme == "https") || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != options.Origin) || ((site == "cross-site" || site == "same-site") && !kpNavigation) {
			identityReject(w, r, 403, "origin_rejected", "请求来源不受信任")
			return
		}
		if options.LocalSetup {
			if r.Header.Get("Forwarded") != "" || r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("X-Forwarded-Host") != "" {
				identityReject(w, r, 403, "local_only", "本机模式不接受代理转发")
				return
			}
			host, _, e := net.SplitHostPort(r.RemoteAddr)
			if e != nil || !IsLoopbackHost(host) {
				identityReject(w, r, 403, "local_only", "本机初始化仅允许回环连接")
				return
			}
		}
		if r.URL.Path == "/health" {
			writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi", "authentication_required": true})
			return
		}
		if r.URL.Path == "/api/v1/auth/setup" {
			if r.Method != "POST" || !options.LocalSetup || r.Header.Get("Origin") != options.Origin || !service.NeedsSetup() {
				identityReject(w, r, 403, "setup_denied", "初始化不可用")
				return
			}
			var in struct {
				Username string `json:"username"`
				Password string `json:"password"`
			}
			if !decode(w, r, &in) {
				return
			}
			_, err := service.Bootstrap(in.Username, in.Password)
			outcome(w, map[string]bool{"created": err == nil}, err)
			return
		}
		if r.URL.Path == loginCaptchaPath {
			if r.Method != "GET" || !options.PublicReadOnly {
				authMethodError(w)
				return
			}
			challenge, ok := captchas.issue(r)
			if !ok {
				w.Header().Set("Retry-After", "1")
				identityReject(w, r, 429, "captcha_rate_limited", "刷新过于频繁，请稍后重试")
				return
			}
			writeJSON(w, 200, challenge)
			return
		}
		setSessionCookie := func(token string, maxAge int) {
			c := &http.Cookie{Name: cookieName, Value: token, Path: "/", HttpOnly: true, Secure: u.Scheme == "https", SameSite: http.SameSiteStrictMode, MaxAge: maxAge}
			if embed && r.Header.Get("X-HMI-Embed") == "kp" && r.Header.Get("Origin") == options.Origin {
				c.SameSite = http.SameSiteNoneMode
				c.Partitioned = true
			}
			http.SetCookie(w, c)
		}
		if r.URL.Path == authLoginPath {
			r.Body = http.MaxBytesReader(w, r.Body, 4096)
			if r.Method != "POST" {
				authMethodError(w)
				return
			}
			var in struct {
				Username      string `json:"username"`
				Password      string `json:"password"`
				Bearer        bool   `json:"issue_token"`
				Code          string `json:"code"`
				CaptchaID     string `json:"captcha_id"`
				CaptchaAnswer string `json:"captcha_answer"`
			}
			if !decode(w, r, &in) {
				return
			}
			if options.PublicReadOnly && !captchas.consume(r, in.CaptchaID, in.CaptchaAnswer) {
				identityReject(w, r, 401, "captcha_invalid", "图形验证码错误或已过期，请刷新后重试")
				return
			}
			if !options.LocalSetup && utf8.RuneCountInString(in.Password) < service.PasswordMinimum() {
				identityReject(w, r, 401, "login_failed", "用户名或密码不正确")
				return
			}
			host, _, _ := net.SplitHostPort(r.RemoteAddr)
			var user identity.User
			var sess identity.Session
			var token string
			var err error
			if options.PublicReadOnly && leaf != nil {
				user, sess, token, err = service.LoginDevice(in.Username, in.Password, host, in.Bearer, leaf, in.Code)
			} else {
				user, sess, token, err = service.LoginChannel(in.Username, in.Password, host, in.Bearer, channel, in.Code)
			}
			if err != nil {
				if errors.Is(err, identity.ErrAccountDisabled) {
					identityReject(w, r, 403, "account_disabled", "账号已停用，请联系管理员")
					return
				}
				if errors.Is(err, identity.ErrDeviceCertificateInvalid) {
					identityReject(w, r, 403, "device_authorization_invalid", "设备授权已停用、撤销或证书过期，请联系管理员检查设备审批和证书")
					return
				}
				if errors.Is(err, identity.ErrLoginRateLimited) {
					identityReject(w, r, 429, "login_rate_limited", "登录尝试过于频繁，请稍后重试")
					return
				}
				if errors.Is(err, identity.ErrLoginBusy) {
					identityReject(w, r, 503, "login_capacity", "登录服务繁忙或会话数量已达上限，请稍后重试或联系管理员清理会话")
					return
				}
				if errors.Is(err, identity.ErrDeviceApprovalPending) {
					identityReject(w, r, 403, "device_approval_pending", "设备正在审批，请等待管理员批准")
					return
				}
				identityReject(w, r, 401, "login_failed", "用户名、密码或验证码错误，或请求过于频繁")
				return
			}
			if !sess.Bearer {
				setSessionCookie(token, identityCookieMaxAge)
			}
			publicAuditUser(r, user.ID)
			response(w, user, sess, token)
			return
		}
		token := ""
		bearer := false
		cookie, ce := r.Cookie(cookieName)
		if h := r.Header.Get("Authorization"); h != "" {
			if ce == nil || !strings.HasPrefix(h, "Bearer ") {
				identityReject(w, r, 401, "authentication_required", "凭据无效")
				return
			}
			token = strings.TrimPrefix(h, "Bearer ")
			bearer = true
		} else if ce == nil {
			token = cookie.Value
		}
		user, sess, authErr := resolve(token, identityActivity(r.URL.Path))
		if sess.Bearer != bearer {
			authErr = identity.ErrLogin
		}
		if authErr == nil {
			publicAuditUser(r, user.ID)
		}
		if r.URL.Path == authSessionPath {
			if r.Method != "GET" {
				authMethodError(w)
				return
			}
			if authErr != nil {
				user = identity.User{}
			} else if !sess.Bearer {
				setSessionCookie(token, identityCookieMaxAge)
			}
			response(w, user, sess, "")
			return
		}
		// Public assets contain no project data; the app renders its sign-in page.
		if !strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/mcp" && (r.Method == "GET" || r.Method == "HEAD") {
			next.ServeHTTP(w, r)
			return
		}
		if authErr != nil {
			identityReject(w, r, 401, "authentication_required", "请登录后继续")
			return
		}
		unsafe := r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS"
		if unsafe && !sess.Bearer && !constantTimeEqual(r.Header.Get("X-CSRF-Token"), sess.CSRF) {
			identityReject(w, r, 403, "csrf_rejected", "请刷新登录状态后重试")
			return
		}
		actor := service.Actor(user)
		actor.Valid = func() bool {
			_, _, e := resolve(token, false)
			return e == nil && publicIPAccessValid(r)
		}
		if options.PublicReadOnly && !(options.LANDevelopment && user.Grants.Develop()) {
			actor.ReadOnly = true
			limits := actor.Grants
			actor.GrantLimits = &limits
			actor.ReadAllExternalScreens = actor.Grants.Develop()
			actor.ReadPublicAudit = actor.Grants.Manage() || actor.Grants.Has("auditor") && actor.Grants.AllStations
			actor.Grants = publicReadGrants(actor.Grants)
		}
		r = r.WithContext(authorization.WithActor(r.Context(), actor))
		p := Principal{Username: user.Username, UserID: user.ID, Provider: "identity", AllowWrite: (!options.PublicReadOnly || options.LANDevelopment && user.Grants.Develop()) && (user.Grants.Develop() || user.Grants.Control || user.Grants.Export || user.Grants.Manage())}
		r = r.WithContext(context.WithValue(r.Context(), principalKey{}, p))
		r = withStreamAccess(r, actor.Valid)
		if state := publicAuditStateFor(r); state != nil {
			state.valid = actor.Valid
		}
		if r.URL.Path == authLogoutPath {
			if r.Method != "POST" {
				authMethodError(w)
				return
			}
			err := service.Revoke(actor, user.ID, sess.ID)
			if err == nil {
				setSessionCookie("", -1)
			}
			outcome(w, map[string]bool{"logged_out": err == nil}, err)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/v1/security/") {
			if r.URL.Path == "/api/v1/security/kp-settings" {
				kpSettingsAPI(w, r, options.KPSettings, service, actor, sess, options.LocalSetup)
				return
			}
			if r.URL.Path == "/api/v1/security/network-access" {
				networkAccessAPI(w, r, options.NetworkAccess, service, actor, sess, options.LocalSetup)
				return
			}
			if !options.LocalSetup && !options.PublicReadOnly && !sess.MFA && r.URL.Path != "/api/v1/security/mfa/begin" && r.URL.Path != "/api/v1/security/mfa/confirm" {
				identityReject(w, r, 403, "mfa_required", "请先绑定双因素验证器")
				return
			}
			securityAPI(w, r, service, actor, sess)
			return
		}
		if !options.LocalSetup && !options.PublicReadOnly && !sess.MFA {
			identityReject(w, r, 403, "mfa_required", "请先绑定双因素验证器")
			return
		}
		next.ServeHTTP(w, r)
	}), nil
}

// Consume a bounded small rejected body before flushing the error. Closing TLS
// while the client is still sending otherwise risks losing the error to TCP RST.
// Large/streamed bodies never cause unbounded reads or extend the server deadline.
func identityReject(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	w.Header().Set("Cache-Control", "no-store")
	publicAuditReason(r, code)
	const limit int64 = 64 * 1024
	if r.Body != nil && r.ContentLength != 0 {
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(time.Now().Add(time.Second))
		count := r.ContentLength
		if count < 0 || count > limit {
			count = limit
			w.Header().Set("Connection", "close")
		}
		read, err := io.CopyN(io.Discard, r.Body, count)
		if r.ContentLength > 0 && r.ContentLength <= limit && err == nil && read == r.ContentLength {
			_ = controller.SetReadDeadline(time.Time{})
		} else {
			w.Header().Set("Connection", "close")
			// Do not let net/http's subsequent Body.Close drain extend the
			// bounded rejection after a partial read or a read timeout.
			_ = controller.SetReadDeadline(time.Now())
		}
	}
	writeError(w, status, code, message)
}

// Background reads do not count as user activity in the session management UI.
// Account sessions stay signed in independently of this activity timestamp.
func identityActivity(path string) bool {
	return path != authSessionPath && path != "/api/v1/runtime" && path != "/api/v1/runtime/events" && path != "/api/v1/jobs" && !strings.HasPrefix(path, "/api/v1/jobs/") && path != "/api/v1/web/status"
}
func securityAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, a authorization.Actor, sess identity.Session) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/security/")
	switch {
	case path == "public-bans" || path == "public-bans/unban" || path == "public-bans/ban":
		publicBansAPI(w, r, s, a, sess)
	case path == "device-certificates" || strings.HasPrefix(path, "device-certificates/"):
		deviceCertificatesAPI(w, r, s, a, sess)
	case path == "devices" || strings.HasPrefix(path, "devices/"):
		deviceRegistrationsAPI(w, r, s, a, sess)
	case path == "public-access/events":
		publicAccessEventsAPI(w, r, s, a, sess)
	case path == "public-access":
		publicIPPolicyAPI(w, r, s, a, sess)
	case path == "mfa/begin" && r.Method == "POST":
		var in struct {
			Password string `json:"password"`
		}
		if !decode(w, r, &in) {
			return
		}
		secret, e := s.BeginMFA(a, in.Password)
		outcome(w, map[string]any{"secret": secret, "issuer": "Universal HMI", "period": 30, "digits": 6}, e)
	case path == "mfa/confirm" && r.Method == "POST":
		var in struct {
			Code string `json:"code"`
		}
		if !decode(w, r, &in) {
			return
		}
		codes, e := s.ConfirmMFA(a, in.Code, sess.ID)
		outcome(w, map[string]any{"recovery_codes": codes}, e)
	case path == "mfa/reset" && r.Method == "POST":
		var in struct {
			UserID string `json:"user_id"`
		}
		if !decode(w, r, &in) {
			return
		}
		e := s.ResetMFA(a, in.UserID)
		outcome(w, map[string]bool{"reset": e == nil}, e)
	case path == "password" && r.Method == "POST":
		var in struct {
			Current string `json:"current_password"`
			Next    string `json:"new_password"`
		}
		if !decode(w, r, &in) {
			return
		}
		e := s.ChangePassword(a, in.Current, in.Next)
		outcome(w, map[string]bool{"changed": e == nil}, e)
	case path == "users" && r.Method == "GET":
		v, e := s.Users(a)
		outcome(w, map[string]any{"items": v, "grant_limits": a.GrantPolicy(), "actor_id": a.ID}, e)
	case path == "device-owners" && r.Method == "GET":
		v, e := s.DeviceOwners(a)
		outcome(w, map[string]any{"items": v}, e)
	case (path == "users" && r.Method == "POST") || (strings.HasPrefix(path, "users/") && r.Method == "PUT"):
		var in identity.Change
		if !decode(w, r, &in) {
			return
		}
		id := ""
		if r.Method == "PUT" {
			id = strings.TrimPrefix(path, "users/")
		}
		v, e := s.Change(a, id, in)
		outcome(w, v, e)
	case path == "roles" && r.Method == "GET":
		v, e := s.Roles(a)
		outcome(w, map[string]any{"items": v, "grant_limits": a.GrantPolicy()}, e)
	case path == "roles" && r.Method == "POST":
		var in identity.Role
		if !decode(w, r, &in) {
			return
		}
		v, e := s.ChangeRole(a, "", in, nil, false)
		outcome(w, v, e)
	case strings.HasPrefix(path, "roles/") && (r.Method == "PUT" || r.Method == "DELETE" || r.Method == "POST"):
		id := strings.TrimPrefix(path, "roles/")
		if strings.HasSuffix(id, "/members") && r.Method == "POST" {
			id = strings.TrimSuffix(id, "/members")
			var in struct {
				Version int64                       `json:"version"`
				Changes []identity.RoleMemberChange `json:"changes"`
			}
			if !decode(w, r, &in) {
				return
			}
			if in.Changes == nil {
				in.Changes = []identity.RoleMemberChange{}
			}
			v, e := s.ChangeRole(a, id, identity.Role{Version: in.Version}, in.Changes, false)
			outcome(w, v, e)
		} else if r.Method == "PUT" || r.Method == "DELETE" {
			var in identity.Role
			if !decode(w, r, &in) {
				return
			}
			v, e := s.ChangeRole(a, id, in, nil, r.Method == "DELETE")
			outcome(w, v, e)
		} else {
			writeError(w, 404, "not_found", "没有此角色操作")
		}
	case path == "stations" && r.Method == "GET":
		v, e := s.Stations(a)
		outcome(w, map[string]any{"items": v}, e)
	case path == "sessions" && r.Method == "GET":
		v, e := s.Sessions(a)
		outcome(w, map[string]any{"items": v}, e)
	case path == "sessions/revoke" && r.Method == "POST":
		var in struct {
			UserID    string `json:"user_id"`
			SessionID string `json:"session_id"`
		}
		if !decode(w, r, &in) {
			return
		}
		e := s.Revoke(a, in.UserID, in.SessionID)
		outcome(w, map[string]bool{"revoked": e == nil}, e)
	case path == "audit" && r.Method == "GET":
		v, e := s.Audits(a)
		outcome(w, map[string]any{"items": v}, e)
	default:
		writeError(w, 404, "not_found", "没有此安全管理操作")
	}
}

// Preserve read scopes and named online maintenance capabilities. Engineering,
// control and generic writes remain unavailable on this request-local copy.
func publicReadGrants(g authorization.Grants) authorization.Grants {
	g.UserManagement = g.ManageUsers()
	g.DeviceApproval = g.ApproveDevices()
	g.CertificateManagement = g.ManageCertificates()
	g.EquipmentEdit = g.EditEquipment()
	g.Roles = []string{"viewer"}
	g.Export, g.Control, g.GrantControl = false, false, false
	return g
}

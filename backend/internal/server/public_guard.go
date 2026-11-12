package server

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/publicguard"
)

type peerAttempts struct {
	last, failedAt     time.Time
	tokens             float64
	failures, overflow int
	wafHits            int
	wafAt              time.Time
}
type PublicGuard struct {
	service        *identity.Service
	engine         *publicguard.Engine
	mu             sync.Mutex
	peers          map[netip.Addr]peerAttempts
	slots          chan struct{}
	now            func() time.Time
	lanDevelopment bool
	lanAccess      bool
}
type publicGuardKey struct{}

func NewPublicGuard(service *identity.Service) (*PublicGuard, error) {
	if service == nil {
		return nil, errors.New("public identity required")
	}
	engine, err := publicguard.New()
	if err != nil {
		return nil, errors.New("public WAF initialization failed")
	}
	return &PublicGuard{service: service, engine: engine, peers: map[netip.Addr]peerAttempts{}, slots: make(chan struct{}, 32), now: time.Now}, nil
}

func NewLANDevelopmentGuard(service *identity.Service) (*PublicGuard, error) {
	return NewLANGuard(service, true)
}

func NewLANGuard(service *identity.Service, development bool) (*PublicGuard, error) {
	g, err := NewPublicGuard(service)
	if err == nil {
		g.lanDevelopment = development
		g.lanAccess = true
	}
	return g, err
}

// This selects inspection only. IdentityHandler still enforces Origin, CSRF,
// channel, session validity and the authoritative Actor for every operation.
func (g *PublicGuard) developmentBody(r *http.Request) bool {
	if !g.lanDevelopment || !strings.HasPrefix(r.URL.Path, "/api/v1/") || strings.HasPrefix(r.URL.Path, "/api/v1/auth/") || strings.HasPrefix(r.URL.Path, "/api/v1/security/") || (r.Method != "POST" && r.Method != "PUT" && r.Method != "DELETE") {
		return false
	}
	token, isBearer := "", false
	cookieName, channel := "__Host-hmi_identity", "lan:engineering"
	if r.TLS == nil {
		cookieName, channel = "hmi_lan_identity", "lan:http:engineering"
	}
	cookie, cookieErr := r.Cookie(cookieName)
	if value := r.Header.Get("Authorization"); value != "" {
		if cookieErr == nil || !strings.HasPrefix(value, "Bearer ") {
			return false
		}
		token, isBearer = strings.TrimPrefix(value, "Bearer "), true
	} else if cookieErr == nil {
		token = cookie.Value
	}
	user, session, err := g.service.ResolveChannel(token, false, channel)
	return err == nil && session.Bearer == isBearer && user.Grants.Develop()
}

// Shared NAT traffic gets a bounded burst budget. Sustained failures have
// separate five-minute counters; a single WAF rejection does not ban the peer.
func (g *PublicGuard) attempt(ip netip.Addr, failed bool) (allowed, ban bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	a, exists := g.peers[ip]
	if !exists {
		if len(g.peers) >= 4096 {
			for peer, value := range g.peers {
				if now.Sub(value.last) > 10*time.Minute {
					delete(g.peers, peer)
				}
			}
			if len(g.peers) >= 4096 {
				return false, false
			}
		}
		a = peerAttempts{tokens: 480, last: now}
	}
	if now.Sub(a.failedAt) > 5*time.Minute {
		a.failures = 0
		a.overflow = 0
		a.failedAt = now
	}
	if failed {
		a.failures++
		ban = a.failures >= 10
		if ban {
			a.failures = 0
		}
		g.peers[ip] = a
		return true, ban
	}
	a.tokens += now.Sub(a.last).Seconds() * 120
	if a.tokens > 480 {
		a.tokens = 480
	}
	a.last = now
	allowed = a.tokens >= 1
	if allowed {
		a.tokens--
	} else {
		a.overflow++
		ban = a.overflow >= 60
		if ban {
			a.overflow = 0
		}
	}
	g.peers[ip] = a
	return allowed, ban
}

func (g *PublicGuard) wafBan(ip netip.Addr) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	a := g.peers[ip]
	if g.now().Sub(a.wafAt) >= 5*time.Minute {
		a.wafHits = 0
		a.wafAt = g.now()
	}
	a.wafHits++
	ban := a.wafHits >= 3
	if ban {
		a.wafHits = 0
	}
	g.peers[ip] = a
	return ban
}

func (g *PublicGuard) banDetails(r *http.Request, summary string, findings []publicguard.Finding) *identity.PublicBanDetails {
	entry := "公网入口"
	if g.lanAccess {
		entry = "内网入口"
	}
	path := r.URL.EscapedPath()
	if strings.HasPrefix(path, "/external-sites/") {
		path = "/external-sites/{入口}/{授权码}/…"
	}
	if len(path) > 512 {
		path = path[:512]
	}
	d := &identity.PublicBanDetails{Summary: summary, Method: r.Method, Path: path, Entry: entry}
	for _, f := range findings {
		d.Rules = append(d.Rules, identity.PublicBanRule{ID: f.ID, Description: f.Description})
	}
	return d
}

func (g *PublicGuard) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		ip, parseErr := netip.ParseAddr(host)
		if err != nil || parseErr != nil || ip.Zone() != "" {
			g.reject(w, r, 403, "public_peer_denied", "来源地址无效")
			return
		}
		ip = ip.Unmap()
		allowed, err := g.service.PublicPeerAllowed(ip)
		if err != nil {
			g.reject(w, r, 503, "public_guard_unavailable", "公网防护状态不可用")
			return
		}
		if !allowed {
			g.reject(w, r, 403, "public_peer_banned", "来源已临时封禁，请联系本机管理员或稍后重试")
			return
		}
		allowed, ban := g.attempt(ip, false)
		if !allowed {
			if ban {
				if err := g.service.BanPublicPeerWithDetails(ip, "request_rate", g.banDetails(r, "5 分钟内累计 60 次请求超限；来源 IP 共享每秒 120 次、突发 480 次的请求额度", nil)); err != nil {
					g.reject(w, r, 503, "public_guard_unavailable", "公网防护状态无法保存")
					return
				}
			}
			w.Header().Set("Retry-After", "60")
			g.reject(w, r, 429, "public_rate_limited", "请求过于频繁")
			return
		}
		select {
		case g.slots <- struct{}{}:
		default:
			g.reject(w, r, 429, "public_rate_limited", "公网检查繁忙，请稍后重试")
			return
		}
		body, decision, findings := g.engine.InspectDetailed(r, g.developmentBody(r))
		<-g.slots
		r.Body = io.NopCloser(bytes.NewReader(body))
		if decision != "allowed" {
			status := 403
			if decision == "body_limit" || decision == "request_limit" {
				status = 413
			}
			if (decision == "blocked_headers" || decision == "blocked_body") && g.wafBan(ip) {
				if err := g.service.BanPublicPeerWithDetails(ip, "waf", g.banDetails(r, "5 分钟内累计 3 次请求被防护拒绝；下列规则为本次触发封禁的请求命中项。规则命中不等同于确认存在攻击", findings)); err != nil {
					status = 503
				}
			}
			g.reject(w, r, status, "public_waf_denied", "公网请求被防护规则拒绝")
			return
		}
		valid := func() bool { allowed, err := g.service.PublicPeerAllowed(ip); return err == nil && allowed }
		r = r.WithContext(context.WithValue(r.Context(), publicGuardKey{}, valid))
		if r.URL.Path == authLoginPath && r.Method == "POST" {
			observed := &guardLoginWriter{header: make(http.Header)}
			next.ServeHTTP(observed, r)
			if observed.status == 401 {
				if _, ban := g.attempt(ip, true); ban {
					if err := g.service.BanPublicPeerWithDetails(ip, "login_failures", g.banDetails(r, "5 分钟内累计 10 次登录认证失败（可能包括密码、验证码或动态码错误）；成功登录会清除登录失败计数", nil)); err != nil {
						g.reject(w, r, 503, "public_guard_unavailable", "公网防护状态无法保存")
						return
					}
				}
			} else if observed.status >= 200 && observed.status < 300 {
				g.mu.Lock()
				value := g.peers[ip]
				value.failures = 0
				g.peers[ip] = value
				g.mu.Unlock()
			}
			if observed.failed {
				g.reject(w, r, 503, "public_guard_unavailable", "登录响应不可用")
				return
			}
			for name, values := range observed.header {
				w.Header()[name] = values
			}
			if observed.status == 0 {
				observed.status = http.StatusOK
			}
			w.WriteHeader(observed.status)
			_, _ = w.Write(observed.body.Bytes())
			return
		}
		next.ServeHTTP(w, r)
	})
}

type guardLoginWriter struct {
	header http.Header
	body   bytes.Buffer
	status int
	failed bool
}

func (w *guardLoginWriter) Header() http.Header { return w.header }

func (w *guardLoginWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *guardLoginWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	if w.body.Len()+len(data) > 65536 {
		w.failed = true
		return 0, io.ErrShortBuffer
	}
	return w.body.Write(data)
}

func (g *PublicGuard) reject(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	if g.lanAccess {
		message = strings.ReplaceAll(message, "公网", "内网")
	}
	identityReject(w, r, status, code, message)
}

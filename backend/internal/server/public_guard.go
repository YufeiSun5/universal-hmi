package server

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/publicguard"
)

type peerAttempts struct {
	last, failedAt     time.Time
	tokens             float64
	failures, overflow int
}
type PublicGuard struct {
	service *identity.Service
	engine  *publicguard.Engine
	mu      sync.Mutex
	peers   map[netip.Addr]peerAttempts
	slots   chan struct{}
	now     func() time.Time
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

// A generous request bucket covers parallel GIS assets and polling behind NAT;
// authentication failures have a separate much tighter five-attempt threshold.
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
		a = peerAttempts{tokens: 240, last: now}
	}
	if now.Sub(a.failedAt) > 5*time.Minute {
		a.failures = 0
		a.overflow = 0
		a.failedAt = now
	}
	if failed {
		a.failures++
		ban = a.failures >= 5
		if ban {
			a.failures = 0
		}
		g.peers[ip] = a
		return true, ban
	}
	a.tokens += now.Sub(a.last).Seconds() * 60
	if a.tokens > 240 {
		a.tokens = 240
	}
	a.last = now
	allowed = a.tokens >= 1
	if allowed {
		a.tokens--
	} else {
		a.overflow++
		ban = a.overflow >= 10
		if ban {
			a.overflow = 0
		}
	}
	g.peers[ip] = a
	return allowed, ban
}

func (g *PublicGuard) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		ip, parseErr := netip.ParseAddr(host)
		if err != nil || parseErr != nil || ip.Zone() != "" {
			identityReject(w, r, 403, "public_peer_denied", "来源地址无效")
			return
		}
		ip = ip.Unmap()
		allowed, err := g.service.PublicPeerAllowed(ip)
		if err != nil {
			identityReject(w, r, 503, "public_guard_unavailable", "公网防护状态不可用")
			return
		}
		if !allowed {
			identityReject(w, r, 403, "public_peer_banned", "来源已临时封禁，请联系本机管理员或稍后重试")
			return
		}
		allowed, ban := g.attempt(ip, false)
		if !allowed {
			if ban {
				if err := g.service.BanPublicPeer(ip, "request_rate"); err != nil {
					identityReject(w, r, 503, "public_guard_unavailable", "公网防护状态无法保存")
					return
				}
			}
			w.Header().Set("Retry-After", "60")
			identityReject(w, r, 429, "public_rate_limited", "请求过于频繁")
			return
		}
		select {
		case g.slots <- struct{}{}:
		default:
			identityReject(w, r, 429, "public_rate_limited", "公网检查繁忙，请稍后重试")
			return
		}
		body, decision := g.engine.Inspect(r)
		<-g.slots
		r.Body = io.NopCloser(bytes.NewReader(body))
		if decision != "allowed" {
			status := 403
			if decision == "body_limit" || decision == "request_limit" {
				status = 413
			}
			if decision == "blocked_headers" || decision == "blocked_body" {
				if err := g.service.BanPublicPeer(ip, "waf"); err != nil {
					status = 503
				}
			}
			identityReject(w, r, status, "public_waf_denied", "公网请求被防护规则拒绝")
			return
		}
		valid := func() bool { allowed, err := g.service.PublicPeerAllowed(ip); return err == nil && allowed }
		r = r.WithContext(context.WithValue(r.Context(), publicGuardKey{}, valid))
		if r.URL.Path == authLoginPath && r.Method == "POST" {
			observed := &guardLoginWriter{header: make(http.Header)}
			next.ServeHTTP(observed, r)
			if observed.status == 401 {
				if _, ban := g.attempt(ip, true); ban {
					if err := g.service.BanPublicPeer(ip, "login_failures"); err != nil {
						identityReject(w, r, 503, "public_guard_unavailable", "公网防护状态无法保存")
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
				identityReject(w, r, 503, "public_guard_unavailable", "登录响应不可用")
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

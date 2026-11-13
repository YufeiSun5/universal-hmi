package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

const embeddedPrefix = "/external-sites/"

var embeddedTargets = map[string]string{"qiwei": "http://www.winxiot.com:8092", "boer": "https://www.360tp.net"}

type embeddedGrant struct {
	token, channel, user, host, site string
	peer                             netip.Addr
	leaf                             [32]byte
	expires                          time.Time
}

// EmbeddedSites owns presentation-only capabilities. Supplier code runs in an
// opaque-origin sandbox, never in the authenticated HMI JavaScript origin.
// Its capability cannot call HMI APIs and is invalid after the HMI session ends.
type EmbeddedSites struct {
	service   *identity.Service
	mu        sync.Mutex
	grants    map[string]embeddedGrant
	transport http.RoundTripper
	slots     chan struct{}
}

func NewEmbeddedSites(service *identity.Service) *EmbeddedSites {
	return &EmbeddedSites{service: service, grants: map[string]embeddedGrant{}, slots: make(chan struct{}, 32), transport: &http.Transport{Proxy: nil, DialContext: dialEmbeddedSite, MaxConnsPerHost: 32, MaxIdleConnsPerHost: 8, ResponseHeaderTimeout: 20 * time.Second, IdleConnTimeout: 30 * time.Second}}
}

// KPAdmissionToken exposes no token to the client. The public boundary uses it
// only to validate a KP-linked session for an already issued supplier capability.
// ServeHTTP independently enforces all capability and current identity checks.
func (g *EmbeddedSites) KPAdmissionToken(r *http.Request) string {
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, embeddedPrefix), "/", 3)
	if !strings.HasPrefix(r.URL.Path, embeddedPrefix) || len(parts) != 3 || len(parts[1]) != 43 || r.TLS == nil {
		return ""
	}
	g.mu.Lock()
	grant, ok := g.grants[parts[1]]
	g.mu.Unlock()
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	ip, parseErr := netip.ParseAddr(host)
	if !ok || grant.site != parts[0] || time.Now().After(grant.expires) || err != nil || parseErr != nil || ip.Unmap() != grant.peer || !strings.EqualFold(r.Host, grant.host) {
		return ""
	}
	return grant.token
}
func dialEmbeddedSite(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, e := net.SplitHostPort(address)
	if e != nil || !(host == "www.winxiot.com" && port == "8092" || host == "www.360tp.net" && port == "443") {
		return nil, fmt.Errorf("invalid supplier")
	}
	ips, e := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if e != nil {
		return nil, e
	}
	for _, ip := range ips {
		ip = ip.Unmap()
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || netip.MustParsePrefix("198.18.0.0/15").Contains(ip) {
			continue
		}
		conn, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if err == nil {
			return conn, nil
		}
	}
	return nil, fmt.Errorf("supplier public address unavailable")
}

func (g *EmbeddedSites) Metadata(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/external-sites" {
			next.ServeHTTP(w, r)
			return
		}
		if r.Method != "GET" && r.Method != "HEAD" {
			authMethodError(w)
			return
		}
		out := map[string]any{"qiwei": "http://www.winxiot.com:8092/login", "boer": "https://www.360tp.net/", "sandboxed": false}
		// KP links its bearer token to the same public identity service. The
		// supplier iframe receives only a scoped capability, never this token.
		token, isBearer := "", false
		if c, err := r.Cookie("__Host-hmi_identity"); err == nil {
			token = c.Value
		} else if r.Header.Get("Authorization") != "" {
			token, isBearer = bearer(r), true
			if token == "" {
				http.Error(w, "请重新登录", 401)
				return
			}
		}
		if token != "" && g.service != nil && r.TLS != nil {
			grant := embeddedGrant{token: token, channel: "public:web", host: r.Host, expires: time.Now().Add(12 * time.Hour)}
			host, _, e := net.SplitHostPort(r.RemoteAddr)
			grant.peer, _ = netip.ParseAddr(host)
			var u identity.User
			var session identity.Session
			var err error
			if leaf := publicDeviceLeaf(r); leaf != nil {
				grant.channel = "public:device"
				grant.leaf = sha256.Sum256(leaf.Raw)
				u, session, err = g.service.ResolveDevice(token, false, leaf)
			} else {
				u, session, err = g.service.ResolveChannel(token, false, grant.channel)
			}
			if e != nil || !grant.peer.IsValid() || err != nil || session.Bearer != isBearer {
				http.Error(w, "请重新登录", 401)
				return
			}
			grant.peer = grant.peer.Unmap()
			grant.user = u.ID
			g.mu.Lock()
			for k, v := range g.grants {
				if time.Now().After(v.expires) {
					delete(g.grants, k)
				}
			}
			if len(g.grants) > 4094 {
				g.mu.Unlock()
				http.Error(w, "外站会话繁忙", 429)
				return
			}
			for id := range embeddedTargets {
				var raw [32]byte
				if _, e = rand.Read(raw[:]); e != nil {
					g.mu.Unlock()
					http.Error(w, "外站会话不可用", 503)
					return
				}
				cap := base64.RawURLEncoding.EncodeToString(raw[:])
				grant.site = id
				g.grants[cap] = grant
				path := "/"
				if id == "qiwei" {
					path = "/login"
				}
				out[id] = embeddedPrefix + id + "/" + cap + path
			}
			g.mu.Unlock()
			out["sandboxed"] = true
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, 200, out)
	})
}

func (g *EmbeddedSites) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Never log the capability component in audit/error messages.
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, embeddedPrefix), "/", 3)
	if g.service == nil || !strings.HasPrefix(r.URL.Path, embeddedPrefix) || len(parts) != 3 || len(parts[1]) != 43 || embeddedTargets[parts[0]] == "" || r.TLS == nil || r.URL.RawPath != "" || r.URL.IsAbs() || r.Method == "CONNECT" || r.Method == "TRACE" || r.Header.Get("Upgrade") != "" {
		http.Error(w, "forbidden", 403)
		return
	}
	id, cap := parts[0], parts[1]
	g.mu.Lock()
	grant, ok := g.grants[cap]
	g.mu.Unlock()
	if !ok || grant.site != id || time.Now().After(grant.expires) {
		http.Error(w, "请重新打开外站画面", 401)
		return
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	ip, ie := netip.ParseAddr(host)
	if err != nil || ie != nil || ip.Unmap() != grant.peer || !strings.EqualFold(r.Host, grant.host) || !publicIPAccessValid(r) {
		http.Error(w, "forbidden", 403)
		return
	}
	var user identity.User
	if grant.channel == "public:device" {
		leaf := publicDeviceLeaf(r)
		if leaf == nil || sha256.Sum256(leaf.Raw) != grant.leaf {
			http.Error(w, "forbidden", 403)
			return
		}
		user, _, err = g.service.ResolveDevice(grant.token, false, leaf)
	} else {
		if publicDeviceLeaf(r) != nil {
			http.Error(w, "forbidden", 403)
			return
		}
		user, _, err = g.service.ResolveChannel(grant.token, false, "public:web")
	}
	if err != nil || user.ID != grant.user {
		g.mu.Lock()
		delete(g.grants, cap)
		g.mu.Unlock()
		http.Error(w, "请重新登录本系统", 401)
		return
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
	default:
		http.Error(w, "busy", 429)
		return
	}
	prefix := embeddedPrefix + id + "/" + cap
	target, _ := url.Parse(embeddedTargets[id])
	g.cors(w)
	if r.Method == "OPTIONS" {
		w.WriteHeader(204)
		return
	}
	if r.Header.Get("Origin") != "" && r.Header.Get("Origin") != "null" {
		http.Error(w, "forbidden", 403)
		return
	}
	if r.Body != nil && r.Body != http.NoBody {
		body, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 65536))
		r.Body.Close()
		if e != nil {
			http.Error(w, "request body too large or incomplete", 413)
			return
		}
		body = bytes.ReplaceAll(body, []byte(url.QueryEscape(prefix)), []byte(url.QueryEscape(target.String())))
		body = bytes.ReplaceAll(body, []byte(prefix), []byte(target.String()))
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
	}
	proxy := &httputil.ReverseProxy{
		Transport: g.transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = target.Host
			pr.Out.URL.Path = "/" + parts[2]
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = strings.ReplaceAll(strings.ReplaceAll(pr.Out.URL.RawQuery, url.QueryEscape(prefix), url.QueryEscape(target.String())), prefix, target.String())
			pr.Out.Header.Del("Cookie")
			for _, c := range pr.In.Cookies() {
				cookiePrefix := "hmi_ext_" + id + "_"
				if strings.HasPrefix(c.Name, cookiePrefix) {
					c.Name = strings.TrimPrefix(c.Name, cookiePrefix)
					pr.Out.AddCookie(c)
				}
			}
			for _, h := range []string{"Authorization", "Proxy-Authorization", "Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-CSRF-Token", "Referer", "Accept-Encoding"} {
				pr.Out.Header.Del(h)
			}
			if pr.In.Header.Get("Origin") != "" {
				pr.Out.Header.Set("Origin", target.String())
			}
		},
		ModifyResponse: func(res *http.Response) error {
			if loc := res.Header.Get("Location"); loc != "" {
				base := *target
				base.Path = "/" + parts[2]
				dest, e := base.Parse(loc)
				if e != nil || dest.Scheme != target.Scheme || dest.Host != target.Host {
					return fmt.Errorf("external redirect rejected")
				}
				res.Header.Set("Location", prefix+dest.RequestURI())
			}
			cookies := res.Cookies()
			res.Header.Del("Set-Cookie")
			for _, c := range cookies {
				c.Name = "hmi_ext_" + id + "_" + c.Name
				c.Domain = ""
				c.Path = embeddedPrefix + id + "/"
				c.Secure = true
				c.SameSite = http.SameSiteNoneMode
				c.Partitioned = true
				res.Header.Add("Set-Cookie", c.String())
			}
			kind := res.Header.Get("Content-Type")
			if strings.HasPrefix(kind, "text/") || strings.Contains(kind, "javascript") || strings.Contains(kind, "json") {
				body, e := io.ReadAll(io.LimitReader(res.Body, (8<<20)+1))
				res.Body.Close()
				if e != nil || len(body) > 8<<20 {
					return fmt.Errorf("external page unavailable")
				}
				body = rewriteEmbeddedBody(body, kind, target, prefix)
				res.Body = io.NopCloser(bytes.NewReader(body))
				res.ContentLength = int64(len(body))
				res.Header.Set("Content-Length", fmt.Sprint(len(body)))
				res.Header.Del("Content-Encoding")
				res.Header.Del("ETag")
			}
			for _, h := range []string{"Clear-Site-Data", "Service-Worker-Allowed", "X-Frame-Options", "Access-Control-Allow-Origin", "Access-Control-Allow-Credentials", "Content-Security-Policy-Report-Only", "Content-Security-Policy"} {
				res.Header.Del(h)
			}
			res.Header.Set("Content-Security-Policy", "sandbox allow-scripts allow-forms allow-modals; worker-src 'none'; object-src 'none'")
			res.Header.Set("Referrer-Policy", "no-referrer")
			res.Header.Set("Cache-Control", "no-store")
			res.Header.Set("X-Content-Type-Options", "nosniff")
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, e error) {
			http.Error(w, "外站暂时无法连接，请稍后重试", 502)
		},
	}
	r.Body = http.MaxBytesReader(w, r.Body, 65536)
	proxy.ServeHTTP(w, r)
}
func (g *EmbeddedSites) cors(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "null")
	w.Header().Set("Access-Control-Allow-Credentials", "true")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Requested-With")
	w.Header().Set("Vary", "Origin")
}

var embeddedRoot = regexp.MustCompile(`(?i)(\b(?:src|href|action|poster|data-src)\s*=\s*["'])/([^/])`)
var embeddedCSSRoot = regexp.MustCompile(`(?i)url\(\s*/([^/])`)
var embeddedCSSImport = regexp.MustCompile(`(?i)(@import\s+["'])/([^/])`)
var embeddedHead = regexp.MustCompile(`(?i)<head[^>]*>`)

func rewriteEmbeddedBody(body []byte, kind string, target *url.URL, prefix string) []byte {
	if strings.Contains(kind, "html") || strings.Contains(kind, "javascript") {
		// Keep known supplier frame-busters inside their opaque view.
		body = bytes.ReplaceAll(body, []byte("if(window.top!==window.self){window.top.location=window.location};"), nil)
		body = bytes.ReplaceAll(body, []byte("if (top.location != self.location) top.location = self.location;"), nil)
	}
	if strings.Contains(kind, "html") {
		body = embeddedRoot.ReplaceAll(body, []byte("${1}"+prefix+"/${2}"))
	}
	if strings.Contains(kind, "html") || strings.Contains(kind, "css") {
		body = embeddedCSSRoot.ReplaceAll(body, []byte("url("+prefix+"/${1}"))
		body = embeddedCSSImport.ReplaceAll(body, []byte("${1}"+prefix+"/${2}"))
	}
	body = bytes.ReplaceAll(body, []byte(target.String()), []byte(prefix))
	body = bytes.ReplaceAll(body, []byte("//"+target.Host), []byte(prefix))
	if strings.Contains(kind, "html") {
		shim := []byte(`<script>(function(){'use strict';const base=` + fmt.Sprintf("%q", prefix) + `, upstream=` + fmt.Sprintf("%q", target.String()) + `;
function url(v){let s=String(v);if(s.startsWith(base+'/'))return s;if(s.startsWith(upstream))return base+s.slice(upstream.length);if(s.startsWith('/')&&!s.startsWith('//'))return base+s;return s;}
const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(m,u){arguments[1]=url(u);return open.apply(this,arguments)};XMLHttpRequest.prototype.send=function(){this.withCredentials=true;return send.apply(this,arguments)};
const fetcher=window.fetch;window.fetch=function(u,o){o=Object.assign({},o,{credentials:'include'});if(typeof u==='string')u=url(u);return fetcher.call(this,u,o)};
const attr=Element.prototype.setAttribute;Element.prototype.setAttribute=function(k,v){if(/^(src|href|action|poster)$/i.test(k))v=url(v);return attr.call(this,k,v)};
for(const [type,property] of [[HTMLScriptElement,'src'],[HTMLImageElement,'src'],[HTMLLinkElement,'href'],[HTMLIFrameElement,'src'],[HTMLFormElement,'action']]){const d=Object.getOwnPropertyDescriptor(type.prototype,property);if(d&&d.set)Object.defineProperty(type.prototype,property,Object.assign({},d,{set:function(v){d.set.call(this,url(v))}}));}
for(const name of ['localStorage','sessionStorage']){try{window[name].length}catch(_){let data={};const store={getItem:k=>Object.prototype.hasOwnProperty.call(data,k)?data[k]:null,setItem:(k,v)=>data[k]=String(v),removeItem:k=>delete data[k],clear:()=>{data={}},key:i=>Object.keys(data)[i]||null};Object.defineProperty(store,'length',{get:()=>Object.keys(data).length});try{Object.defineProperty(window,name,{value:store})}catch(_){}}}
})();</script>`)
		if loc := embeddedHead.FindIndex(body); loc != nil {
			at := loc[1]
			body = append(append(append([]byte{}, body[:at]...), shim...), body[at:]...)
		} else {
			body = append(shim, body...)
		}
	}
	return body
}

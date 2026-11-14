package server

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// Opt-in browser fixture. Synthetic supplier login never contacts a vendor.
// Live mode allows reads and the known login/list endpoints only. It uses the
// host's normal transport for two fixed suppliers through local TUN DNS;
// production dialing is unchanged. Vendor credentials are never fixtures.
func TestManualEmbeddedLANBrowser(t *testing.T) {
	out, ip := os.Getenv("HMI_EXTERNAL_BROWSER_DIR"), os.Getenv("HMI_EXTERNAL_BROWSER_IP")
	if out == "" || ip == "" {
		t.Skip("opt-in external-site browser fixture")
	}
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	if _, err = ids.Bootstrap("fixture-owner", publicFixturePassword); err != nil {
		t.Fatal(err)
	}
	ready := map[string]any{"username": "fixture-owner", "password": publicFixturePassword}
	for _, live := range []bool{false, true} {
		name := map[bool]string{false: "fixture", true: "live"}[live]
		listener, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
		if err != nil {
			t.Fatal(err)
		}
		origin := "http://" + listener.Addr().String()
		captchas := newLoginCaptchas()
		g := NewLANHTTPEmbeddedSites(ids, false)
		if live {
			g.transport = supplierTransport(func(r *http.Request) (*http.Response, error) {
				loginPost := r.Method == "POST" && (r.URL.Path == "/login/login" && r.URL.Host == "www.winxiot.com:8092" || (r.URL.Path == "/account/login" || r.URL.Path == "/api/configuration/maininit" || r.URL.Path == "/api/devicedata/pagelist") && r.URL.Host == "www.360tp.net")
				if r.Method != "GET" && r.Method != "HEAD" && !loginPost {
					return nil, fmt.Errorf("live supplier fixture permits only reads and login")
				}
				return http.DefaultTransport.RoundTrip(r)
			})
		} else {
			g.transport = supplierTransport(embeddedBrowserSupplier)
		}
		static := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/fixture-captcha" {
				writeJSON(w, 200, map[string]string{"captcha_id": seedLoginCaptcha(captchas, ip)})
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			io.WriteString(w, `<!doctype html><meta charset="utf-8"><title>内网 HTTP 外站隔离验收</title><style>body{margin:0;font:14px sans-serif}header{height:42px;background:#e9ecef;padding:8px;box-sizing:border-box}iframe{border:0;width:100%;height:calc(100vh - 42px)}</style><header>隔离验收 <button onclick="show('qiwei')">七维</button> <button onclick="show('boer')">波尔</button> <button onclick="show(current)">重新打开</button></header><div id="view"></div><script>let current;async function show(id){current=id;const c=await(await fetch('/api/v1/external-sites')).json();const frame=document.createElement('iframe');frame.setAttribute('sandbox','allow-scripts allow-forms allow-modals');frame.srcdoc='<style>html,body,iframe{margin:0;width:100%;height:100%;border:0}</style><iframe sandbox="allow-scripts allow-forms allow-modals" referrerpolicy="no-referrer" src="'+c[id]+'"></iframe>';document.querySelector('#view').replaceChildren(frame)}</script>`)
		})
		iam, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true, LANHTTP: true, captchas: captchas}, g.Metadata(http.NotFoundHandler()))
		if err != nil {
			t.Fatal(err)
		}
		guard, err := NewLANGuard(ids, false)
		if err != nil {
			t.Fatal(err)
		}
		h, err := PublicAccessHandler(guard.Handler(iam), PublicAccessOptions{Policy: func(peer netip.Addr) bool { return peer.String() == ip }, External: guard.Handler(g), Static: static})
		if err != nil {
			t.Fatal(err)
		}
		srv := &http.Server{Handler: LANPeerHandler(h), ReadHeaderTimeout: 5 * time.Second}
		go srv.Serve(listener)
		defer srv.Close()
		ready[name] = origin
	}
	if err = os.MkdirAll(out, 0700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ready)
	if err = os.WriteFile(filepath.Join(out, "browser-private.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
	t.Log("Private HTTP fixtures ready; stop using the stop-browser file")
	deadline := time.Now().Add(45 * time.Minute)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(out, "stop-browser")); err == nil {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("browser fixture deadline elapsed")
}

func embeddedBrowserSupplier(r *http.Request) (*http.Response, error) {
	id, label := "qiwei", "七维模拟供应商"
	if r.URL.Host == "www.360tp.net" {
		id, label = "boer", "波尔模拟供应商"
	}
	header := http.Header{"Content-Type": {"text/html; charset=utf-8"}}
	status, body := 200, ""
	cookie, _ := r.Cookie("sid")
	logged := cookie != nil && cookie.Value == id+"-logged-in"
	switch r.URL.Path {
	case "/", "/login", "/account/login":
		if logged {
			header.Set("Location", "/index")
			status = 302
			break
		}
		header.Add("Set-Cookie", "sid="+id+"-prelogin; Path=/; HttpOnly")
		buster := `if(window.top!==window.self){window.top.location=window.location};`
		if id == "boer" {
			buster = `if (top.location != self.location) top.location = self.location;`
		}
		body = `<head><meta charset="utf-8"><script>` + buster + `</script></head><body><h2>` + label + `</h2><p>仅供隔离验收，不是真实供应商账号</p><form id="login"><label>用户名<input name="username" required></label><label>密码<input name="password" type="password" required></label><button>登录</button></form><p id="result"></p><script>var ctx = "\/;JSESSIONID=fixture-session";document.querySelector('form').onsubmit=async function(e){e.preventDefault();let r=await fetch(`
		if id == "qiwei" {
			body += `ctx+'login/login'`
		} else {
			body += `'../account/login'`
		}
		body += `,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(new FormData(this))});let res=await r.json();if(!res.Success){document.querySelector('#result').textContent='登录失败，可重试';return;}`
		if id == "qiwei" {
			body += `location.href=ctx+'index';`
		} else {
			body += `location.href = res.TargetUrl;`
		}
		body += `}</script></body>`
		if r.Method != "POST" {
			break
		}
		fallthrough
	case "/login/login":
		if r.Method != "POST" {
			status = 405
			break
		}
		header.Set("Content-Type", "application/json")
		_ = r.ParseForm()
		if cookie == nil || cookie.Value != id+"-prelogin" || r.Form.Get("username") != "demo" || r.Form.Get("password") != "fixture-pass" {
			body = `{"Success":false}`
			break
		}
		header.Set("Set-Cookie", "sid="+id+"-logged-in; Path=/; HttpOnly")
		body = `{"Success":true,"TargetUrl":"/index"}`
	case "/index":
		if !logged {
			header.Set("Location", "/login")
			status = 302
			break
		}
		body = `<head><meta charset="utf-8"></head><h2>` + label + `登录成功</h2><a href="/logout">退出供应商</a>`
	case "/logout":
		header.Set("Set-Cookie", "sid=; Path=/; Max-Age=0")
		header.Set("Location", "/login")
		status = 302
	default:
		status = 404
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body))}, nil
}

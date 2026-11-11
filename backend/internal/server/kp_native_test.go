package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

func TestNativeKPThroughPublicAdmissionAndIdentity(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	valid := true
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if valid {
			fmt.Fprint(w, `{"userId":2,"userName":"admin001"}`)
		} else {
			fmt.Fprint(w, `{"code":1024,"msg":"expired"}`)
		}
	}))
	defer upstream.Close()
	bridge, e := NewKPService(KPConfig{SourceID: "kp", WorkspaceID: "project", KPServer: upstream.URL, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID, DisplayName: "mapped", Role: "operator"}}}, false, nil)
	if e != nil {
		t.Fatal(e)
	}
	const origin = "https://hmi.test"
	var streamValid func() bool
	ordinary, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		streamValid = func() bool { return publicIPAccessValid(r) }
		w.WriteHeader(200)
	}))
	if e != nil {
		t.Fatal(e)
	}
	webDir := t.TempDir()
	if e := os.WriteFile(filepath.Join(webDir, "kp_bridge.js"), []byte("window.bridgeLoaded=true;"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(webDir, "index.html"), []byte(`<base href="/">KP shell`), 0600); e != nil {
		t.Fatal(e)
	}
	kp, e := KPHandler(bridge, KPOptions{Identity: ids, PublicReadOnly: true, PublicOrigin: origin, WebDir: webDir, KPOrigins: []string{"http://kp.test:11005"}}, ordinary, nil)
	if e != nil {
		t.Fatal(e)
	}
	allowed := false
	h, e := PublicAccessHandler(ordinary, PublicAccessOptions{Policy: func(netip.Addr) bool { return allowed }, KP: kp, KPToken: ids.KPTokenValid})
	if e != nil {
		t.Fatal(e)
	}
	asset := httptest.NewRequest("GET", origin+"/kp/kp_bridge.js", nil)
	asset.RemoteAddr = "192.0.2.10:1234"
	asset.Header.Set("Sec-Fetch-Site", "cross-site")
	asset.Header.Set("Sec-Fetch-Mode", "no-cors")
	asset.Header.Set("Sec-Fetch-Dest", "script")
	assetResponse := httptest.NewRecorder()
	h.ServeHTTP(assetResponse, asset)
	if assetResponse.Code != 200 || !strings.Contains(assetResponse.Body.String(), "bridgeLoaded") {
		t.Fatal("KP helper blocked by ordinary origin policy", assetResponse.Code)
	}
	asset.URL.Path = "/kp/"
	asset.Header.Set("Sec-Fetch-Mode", "navigate")
	asset.Header.Set("Sec-Fetch-Dest", "iframe")
	assetResponse = httptest.NewRecorder()
	h.ServeHTTP(assetResponse, asset)
	if assetResponse.Code != 200 || !strings.Contains(assetResponse.Body.String(), `<base href="/kp/">`) {
		t.Fatal("KP frame root rejected", assetResponse.Code)
	}
	ordinaryCookie := ""
	call := func(method, path, body, token, requestOrigin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = "192.0.2.10:1234"
		if ordinaryCookie != "" {
			r.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: ordinaryCookie})
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		if requestOrigin != "" {
			r.Header.Set("Origin", requestOrigin)
		}
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	payload := `{"contextId":"window","loginVersion":"login","userName":"admin001","identityProof":"fixture"}`
	for _, route := range []string{"/api/v1/auth/session", "/api/v1/points", "/"} {
		if w := call("GET", route, "", "", origin); w.Code != 403 || !strings.Contains(w.Body.String(), "public_ip_denied") {
			t.Fatal("ordinary Web escaped IP admission", route, w.Code)
		}
	}
	if w := call("POST", "/api/v1/kp/bootstrap", payload, "", "https://wrong.test"); w.Code != 403 || w.Header().Get("Access-Control-Allow-Credentials") != "" {
		t.Fatal(w.Code)
	}
	preflight := call("OPTIONS", "/api/v1/kp/bootstrap", "", "", "http://kp.test:11005")
	if preflight.Code != 204 || preflight.Header().Get("Access-Control-Allow-Origin") != "http://kp.test:11005" || preflight.Header().Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatal("credentialed browser preflight rejected", preflight.Code, preflight.Header())
	}
	if w := call("OPTIONS", "/api/v1/kp/bootstrap", "", "", "https://wrong.test"); w.Code != 403 || w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("unconfigured origin allowed preflight", w.Code, w.Header())
	}
	w := call("POST", "/api/v1/kp/bootstrap", payload, "", "http://kp.test:11005")
	if w.Code != 200 || w.Header().Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatal(w.Code, w.Body.String())
	}
	var b kpbridge.BootstrapReply
	_ = json.Unmarshal(w.Body.Bytes(), &b)
	w = call("POST", "/api/v1/web/redeem", fmt.Sprintf(`{"ticket":%q}`, b.Ticket), "", origin)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var web kpbridge.WebReply
	_ = json.Unmarshal(w.Body.Bytes(), &web)
	if web.CanWrite || web.MFA || strings.Contains(w.Body.String(), `"can_develop":true`) {
		t.Fatal("native session elevated", w.Body.String())
	}
	if _, _, e := ids.Resolve(web.WebToken, false); e == nil {
		t.Fatal("public token accepted by local identity")
	}
	// Browsers send the ordinary same-origin login cookie alongside KP's
	// bearer. Exercise the full admission/bridge/identity stack with both.
	ordinaryCookie = "stale-ordinary-web-session"
	if w = call("GET", "/api/v1/points", "", web.WebToken, origin); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if streamValid == nil || !streamValid() {
		t.Fatal("KP live read still depends on denied IP policy")
	}
	for _, path := range []string{"/kp/../api/v1/points", "/kp/%2f../api/v1/points", "/api/v1/kp/bootstrap/../points", "/api/v1/local/deployment", "/mcp"} {
		if w = call("GET", path, "", web.WebToken, origin); w.Code != 403 {
			t.Fatal("KP escaped route/canonical boundary", path, w.Code)
		}
	}
	for _, token := range []string{"forged", ""} {
		if w = call("GET", "/api/v1/points", "", token, origin); w.Code != 403 {
			t.Fatal("unverified request used KP admission", w.Code)
		}
	}
	_, _, passwordToken, err := ids.LoginChannel("owner", publicFixturePassword, "test", true, "public:web")
	if err != nil {
		t.Fatal(err)
	}
	if w = call("GET", "/api/v1/points", "", passwordToken, origin); w.Code != 403 {
		t.Fatal("ordinary bearer used KP admission", w.Code)
	}
	if w = call("POST", "/api/v1/points", "{}", web.WebToken, origin); w.Code != 403 {
		t.Fatal("write escaped public boundary", w.Code)
	}
	if w = call("POST", "/api/v1/web/redeem", fmt.Sprintf(`{"ticket":%q}`, b.Ticket), "", origin); w.Code != 403 {
		t.Fatal("replayed ticket", w.Code)
	}
	valid = false
	raw, _ := json.Marshal(struct {
		kpbridge.Channel
		IdentityProof string `json:"identityProof"`
	}{b.Channel, "expired"})
	if w = call("POST", "/api/v1/kp/poll", string(raw), "", "http://kp.test:11005"); w.Code != 401 {
		t.Fatal(w.Code, w.Body.String())
	}
	if streamValid() {
		t.Fatal("KP live read survived bridge revocation")
	}
	if w = call("GET", "/api/v1/points", "", web.WebToken, origin); w.Code != 403 {
		t.Fatal("revoked token read business", w.Code)
	}
	allowed = true
	if w = call("GET", "/api/v1/points", "", web.WebToken, origin); w.Code != 401 {
		t.Fatal("IP approval restored revoked identity", w.Code)
	}
}

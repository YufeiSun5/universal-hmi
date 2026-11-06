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
	ordinary, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
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
	allowed := true
	h, e := PublicAccessHandler(ordinary, PublicAccessOptions{Policy: func(netip.Addr) bool { return allowed }, KP: kp})
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
	call := func(method, path, body, token, requestOrigin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = "192.0.2.10:1234"
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
	allowed = false
	if w := call("POST", "/api/v1/kp/bootstrap", payload, "", "http://kp.test:11005"); w.Code != 403 {
		t.Fatal(w.Code)
	}
	allowed = true
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
	if w = call("GET", "/api/v1/points", "", web.WebToken, origin); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
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
	if w = call("GET", "/api/v1/points", "", web.WebToken, origin); w.Code != 401 {
		t.Fatal("revoked token read business", w.Code)
	}
}

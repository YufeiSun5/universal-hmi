package server

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSharedLocalRemoteIdentityBoundary(t *testing.T) {
	dir := t.TempDir()
	ids, e := identity.OpenDatabase(dir, "", identity.Options{LocalPasswords: true})
	if e != nil {
		t.Fatal(e)
	}
	owner, e := ids.Bootstrap("owner", "admin")
	if e != nil {
		t.Fatal(e)
	}
	ids.Close()
	ids, e = identity.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	local, e := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:18080", LocalSetup: true}, next)
	if e != nil {
		t.Fatal(e)
	}
	callLocal := func(path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "http://127.0.0.1:18080"+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("Origin", "http://127.0.0.1:18080")
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		local.ServeHTTP(w, r)
		return w
	}
	if w := callLocal(authLoginPath, `{"username":"owner","password":"admin","issue_token":true}`, ""); w.Code != 200 {
		t.Fatalf("local migration login %d %s", w.Code, w.Body)
	}
	srv := httptest.NewUnstartedServer(nil)
	origin := "https://" + srv.Listener.Addr().String()
	remote, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, next)
	if e != nil {
		t.Fatal(e)
	}
	srv.Config.Handler, e = PublicAccessHandler(remote, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}})
	if e != nil {
		t.Fatal(e)
	}
	srv.StartTLS()
	defer srv.Close()
	remoteCall := func(method, path, body, token string) (int, []byte) {
		req, _ := http.NewRequest(method, origin+path, strings.NewReader(body))
		req.Header.Set("Origin", origin)
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, e := srv.Client().Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, b
	}

	code, _ := remoteCall("POST", authLoginPath, `{"username":"owner","password":"admin","issue_token":true}`, "")
	if code != 401 {
		t.Fatalf("short remote login %d", code)
	}
	if e = ids.ChangePassword(ids.Actor(owner), "admin", "updated-seven"); e != nil {
		t.Fatal(e)
	}
	w := callLocal(authLoginPath, `{"username":"owner","password":"updated-seven","issue_token":true}`, "")
	var state map[string]any
	json.Unmarshal(w.Body.Bytes(), &state)
	token := state["bearer_token"].(string)
	for _, path := range []string{"/api/v1/runtime", "/api/v1/runtime/events"} {
		code, _ = remoteCall("GET", path, "", token)
		if code != 401 {
			t.Fatalf("local bearer crossed public channel %s %d", path, code)
		}
	}
	owner, _, e = ids.Resolve(token, false)
	if e != nil {
		t.Fatal(e)
	}
	secret, e := ids.BeginMFA(ids.Actor(owner), "updated-seven")
	if e != nil {
		t.Fatal(e)
	}
	key, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(time.Now().Unix()/30))
	mac := hmac.New(sha1.New, key)
	mac.Write(b[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 15
	otp := fmt.Sprintf("%06d", (binary.BigEndian.Uint32(sum[offset:offset+4])&0x7fffffff)%1000000)
	_, session, e := ids.Resolve(token, false)
	if e != nil {
		t.Fatal(e)
	}
	recovery, e := ids.ConfirmMFA(ids.Actor(owner), otp, session.ID)
	if e != nil {
		t.Fatal(e)
	}
	code, _ = remoteCall("GET", "/api/v1/runtime", "", token)
	if code != 401 {
		t.Fatalf("MFA local session crossed public channel %d", code)
	}
	body, _ := json.Marshal(map[string]any{"username": "owner", "password": "updated-seven", "issue_token": true, "code": recovery[0]})
	code, response := remoteCall("POST", authLoginPath, string(body), "")
	if code != 200 {
		t.Fatalf("public login %d %s", code, response)
	}
	var public map[string]any
	if e = json.Unmarshal(response, &public); e != nil {
		t.Fatal(e)
	}
	publicToken := public["bearer_token"].(string)
	if public["can_write"] != false || public["can_develop"] != false || public["can_manage_users"] != false || public["channel"] != "public:web" {
		t.Fatalf("public admin capabilities %+v", public)
	}
	if code, _ = remoteCall("GET", "/api/v1/runtime", "", publicToken); code != 204 {
		t.Fatalf("public read %d", code)
	}
	if w := callLocal(authLogoutPath, "", publicToken); w.Code != 401 {
		t.Fatalf("public bearer crossed local channel %d", w.Code)
	}
	for _, path := range []string{"/api/v1/write", "/api/v1/apply", "/api/v1/security/users", "/mcp"} {
		if code, _ = remoteCall("POST", path, "{}", publicToken); code != 403 {
			t.Fatalf("public admin mutation %s %d", path, code)
		}
	}
	if _, _, e = ids.Resolve(token, false); e != nil {
		t.Fatal("public rejection revoked local session", e)
	}
	if _, _, e = ids.ResolveChannel(publicToken, false, "public:web"); e != nil {
		t.Fatal("local rejection revoked public session", e)
	}
	code, _ = remoteCall("POST", "/api/v1/auth/setup", `{"username":"other","password":"updated-seven"}`, "")
	if code != 403 {
		t.Fatalf("remote setup exposed %d", code)
	}
}

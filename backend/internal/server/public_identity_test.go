package server

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

const publicFixturePassword = "synthetic public boundary password"

func publicFixtureCode(t *testing.T, secret string) string {
	t.Helper()
	key, e := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if e != nil {
		t.Fatal(e)
	}
	var counter [8]byte
	binary.BigEndian.PutUint64(counter[:], uint64(time.Now().Unix()/30))
	m := hmac.New(sha1.New, key)
	m.Write(counter[:])
	sum := m.Sum(nil)
	offset := sum[len(sum)-1] & 15
	return fmt.Sprintf("%06d", (binary.BigEndian.Uint32(sum[offset:offset+4])&0x7fffffff)%1000000)
}
func TestPublicIdentityMFAReadScopesAndSSE(t *testing.T) {
	testPublicIdentityReadScopesAndSSE(t, false)
}
func TestPublicIPPolicyRevokesExistingSSE(t *testing.T) {
	testPublicIdentityReadScopesAndSSE(t, true)
}
func testPublicIdentityReadScopesAndSSE(t *testing.T, revokeIP bool) {
	raw, _, engine := platform(t)
	ext, e := externaldata.Open(engine.Store, t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	secret := "synthetic external SQL password"
	source, e := ext.SaveSource(context.Background(), externaldata.SourceChange{Source: externaldata.Source{Name: "test", Host: "127.0.0.1", Port: 1, Database: "synthetic", Username: "test", Encrypt: true, UTCOffsetMinutes: 480}, Password: &secret})
	if e != nil {
		t.Fatal(e)
	}
	screen, e := ext.SaveScreen(context.Background(), externaldata.Screen{Name: "readable", SourceID: source.ID, Kind: "hourly"})
	if e != nil {
		t.Fatal(e)
	}
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	reader, e := ids.Change(ids.Actor(owner), "", identity.Change{Username: "limited", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: false}})
	if e != nil {
		t.Fatal(e)
	}
	srv := httptest.NewUnstartedServer(nil)
	options := IdentityOptions{Origin: "https://" + srv.Listener.Addr().String(), PublicReadOnly: true}
	api, e := IdentityHandler(ids, options, ExternalDataHandler(raw, ext, ""))
	if e != nil {
		t.Fatal(e)
	}
	assets, e := IdentityHandler(ids, options, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "synthetic static asset") }))
	if e != nil {
		t.Fatal(e)
	}
	access := PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}, Static: assets}
	if revokeIP {
		if e := ids.InitPublicIPPolicy([]identity.PublicIPRule{{CIDR: "127.0.0.1", Enabled: true}}); e != nil {
			t.Fatal(e)
		}
		access.Policy = ids.PublicIPAllowed
	}
	srv.Config.Handler, e = PublicAccessHandler(api, access)
	if e != nil {
		t.Fatal(e)
	}
	srv.StartTLS()
	defer srv.Close()
	call := func(method, path, body, token string) (int, []byte) {
		t.Helper()
		r, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", srv.URL)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		res, e := srv.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		defer res.Body.Close()
		b, e := io.ReadAll(res.Body)
		if e != nil {
			t.Fatal(e)
		}
		return res.StatusCode, b
	}
	enroll := func(username string) string {
		t.Helper()
		b, _ := json.Marshal(map[string]any{"username": username, "password": publicFixturePassword, "issue_token": true})
		status, data := call("POST", authLoginPath, string(b), "")
		if status != 200 {
			t.Fatalf("login %d %s", status, data)
		}
		var login struct {
			Token      string               `json:"bearer_token"`
			CanWrite   bool                 `json:"can_write"`
			CanDevelop bool                 `json:"can_develop"`
			CanManage  bool                 `json:"can_manage_users"`
			Grants     authorization.Grants `json:"grants"`
		}
		if e = json.Unmarshal(data, &login); e != nil {
			t.Fatal(e)
		}
		if login.CanWrite || login.CanDevelop || login.CanManage || login.Grants.Manage() || login.Grants.Develop() || login.Grants.Control || login.Grants.Export || login.Grants.GrantControl {
			t.Fatal("public capabilities not reduced")
		}
		if status, _ = call("GET", "/api/v1/runtime", "", login.Token); status != 403 {
			t.Fatalf("MFA not required %d", status)
		}
		b, _ = json.Marshal(map[string]string{"password": publicFixturePassword})
		status, data = call("POST", "/api/v1/security/mfa/begin", string(b), login.Token)
		if status != 200 {
			t.Fatalf("MFA begin %d %s", status, data)
		}
		var enrollment struct {
			Secret string `json:"secret"`
		}
		if e = json.Unmarshal(data, &enrollment); e != nil {
			t.Fatal(e)
		}
		b, _ = json.Marshal(map[string]string{"code": publicFixtureCode(t, enrollment.Secret)})
		status, data = call("POST", "/api/v1/security/mfa/confirm", string(b), login.Token)
		if status != 200 {
			t.Fatalf("MFA confirm %d %s", status, data)
		}
		return login.Token
	}
	token := enroll(owner.Username)
	if status, data := call("GET", "/api/v1/external/screens", "", token); status != 200 || !strings.Contains(string(data), screen.ID) {
		t.Fatalf("engineer read scope lost %d %s", status, data)
	}
	if status, data := call("POST", "/api/v1/external/screens/"+screen.ID+"/query", `{"station":"A","date":"invalid"}`, token); status != 422 {
		t.Fatalf("POST query did not reach read validation %d %s", status, data)
	}
	for _, path := range []string{"/api/v1/write", "/api/v1/apply", "/api/v1/security/users", "/api/v1/security/password", "/api/v1/external/sources", "/api/v1/external/screens", "/mcp"} {
		if status, _ := call("POST", path, "{}", token); status != 403 {
			t.Fatalf("public owner write %s %d", path, status)
		}
	}
	limited := enroll(reader.Username)
	if status, data := call("GET", "/api/v1/external/screens", "", limited); status != 200 || strings.Contains(string(data), screen.ID) {
		t.Fatalf("limited read broadened %d %s", status, data)
	}
	if status, _ := call("POST", "/api/v1/external/screens/"+screen.ID+"/query", `{"date":"invalid"}`, limited); status != 403 {
		t.Fatalf("limited query gained global read %d", status)
	}
	// Assets retain the existing identity origin/security-header policy, but no login requirement.
	r, _ := http.NewRequest("GET", srv.URL+"/index.html", nil)
	res, e := srv.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("X-Content-Type-Options") != "nosniff" || res.Header.Get("Content-Security-Policy") == "" {
		t.Fatal("static security headers absent")
	}
	r, _ = http.NewRequest("GET", srv.URL+"/index.html", nil)
	r.Host = "wrong.example"
	res, e = srv.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	res.Body.Close()
	if res.StatusCode != 403 {
		t.Fatal("static Host unchecked")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, _ = http.NewRequestWithContext(ctx, "GET", srv.URL+"/api/v1/runtime/events", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	res, e = srv.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("SSE %d", res.StatusCode)
	}
	stream := bufio.NewReader(res.Body)
	line, e := stream.ReadString('\n')
	if e != nil || !strings.Contains(line, "event: runtime") {
		t.Fatalf("SSE start %q %v", line, e)
	}
	_, session, e := ids.ResolveChannel(token, false, "public:web")
	if e != nil {
		t.Fatal(e)
	}
	if revokeIP {
		policy, err := ids.PublicIPPolicy(ids.Actor(owner))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = ids.SavePublicIPPolicy(ids.Actor(owner), policy.Revision, nil); err != nil {
			t.Fatal(err)
		}
	} else if e = ids.Revoke(ids.Actor(owner), owner.ID, session.ID); e != nil {
		t.Fatal(e)
	}
	for {
		line, e = stream.ReadString('\n')
		if strings.Contains(line, "session-expired") {
			break
		}
		if e != nil {
			t.Fatalf("SSE did not recheck revocation: %v", e)
		}
	}
	want := 401
	if revokeIP {
		want = 403
	}
	if status, _ := call("GET", "/api/v1/runtime", "", token); status != want {
		t.Fatalf("revoked public access retained: got %d want %d", status, want)
	}
	if revokeIP {
		if _, _, err := ids.ResolveChannel(token, false, "public:web"); err != nil {
			t.Fatal("IP change must not revoke account/session identity", err)
		}
	}
}

func TestPublicReadGrantsPreservesOnlyReadScopes(t *testing.T) {
	original := authorization.Grants{Roles: []string{"engineer", "admin", "auditor"}, AllStations: false, StationIDs: []string{"station-a"}, ScreenIDs: []string{"screen-a"}, ExternalScreenIDs: []string{"external-a"}, Control: true, Export: true, GrantControl: true}
	capped := publicReadGrants(original)
	if capped.Manage() || capped.Develop() || capped.Control || capped.Export || capped.GrantControl || capped.AllStations || !capped.Station("station-a") || capped.Station("station-b") || !capped.Screen("screen-a", "") || capped.ExternalScreenIDs[0] != "external-a" {
		t.Fatal("scope changed", capped)
	}
	if original.Roles[0] != "engineer" || !original.Control {
		t.Fatal("stored grant value mutated")
	}
	if _, e := IdentityHandler(nil, IdentityOptions{LocalSetup: true, PublicReadOnly: true}, http.NotFoundHandler()); e == nil {
		t.Fatal("public local setup accepted")
	}
}

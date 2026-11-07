package server

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

func TestNativeKPDeviceAdmissionAcrossIPsAndRevocation(t *testing.T) {
	ids, owner, doc, certificate := deviceTLSFixture(t)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"userId":2,"userName":"kpuser"}`) }))
	defer upstream.Close()
	s := NewKPSettings(t.TempDir(), "project", ids)
	saved, e := s.Save(KPSettingsInput{Revision: "absent", Enabled: true, Server: upstream.URL, Origins: []string{"https://kp.example"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID}}})
	if e != nil {
		t.Fatal(e)
	}
	const origin = "https://hmi.example"
	iam, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if e != nil {
		t.Fatal(e)
	}
	h, e := PublicAccessHandler(iam, PublicAccessOptions{KP: s.Attach(origin, t.TempDir(), iam), Policy: func(netip.Addr) bool { return false }, Device: ids.VerifyDeviceCertificate})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Apply(saved.Revision); e != nil {
		t.Fatal(e)
	}
	call := func(method, path, body, peer, token string, cert bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = peer + ":1234"
		r.Header.Set("Content-Type", "application/json")
		if strings.HasPrefix(path, "/api/v1/kp/") {
			r.Header.Set("Origin", "https://kp.example")
		} else {
			r.Header.Set("Origin", origin)
		}
		if cert {
			r.TLS.HandshakeComplete = true
			r.TLS.PeerCertificates = []*x509.Certificate{certificate.Leaf}
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	w := call("POST", "/api/v1/kp/bootstrap", `{"contextId":"mobile","loginVersion":"1","userName":"kpuser","identityProof":"fixture"}`, "192.0.2.8", "", true)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var boot kpbridge.BootstrapReply
	json.Unmarshal(w.Body.Bytes(), &boot)
	w = call("POST", "/api/v1/web/redeem", fmt.Sprintf(`{"ticket":%q}`, boot.Ticket), "192.0.2.8", "", true)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var web kpbridge.WebReply
	json.Unmarshal(w.Body.Bytes(), &web)
	for _, peer := range []string{"192.0.2.8", "198.51.100.80"} {
		if w = call("GET", "/api/v1/points", "", peer, web.WebToken, true); w.Code != 204 {
			t.Fatal("approved device could not roam", w.Code, w.Body.String())
		}
		if w = call("GET", "/api/v1/points", "", peer, web.WebToken, false); w.Code != 403 {
			t.Fatal("device token bypassed admission", w.Code)
		}
	}
	if _, e = ids.RevokeDeviceCertificate(ids.Actor(owner), doc.Revision, doc.Items[0].RegistrationID); e != nil {
		t.Fatal(e)
	}
	if w = call("GET", "/api/v1/points", "", "198.51.100.80", web.WebToken, true); w.Code != 403 {
		t.Fatal("revoked device survived", w.Code)
	}
}

func TestKPSettingsSaveApplyAcrossPublicClientsAndRetire(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Header.Get("Authorization") {
		case "Bearer proof":
			fmt.Fprint(w, `{"userId":2,"userName":"kpuser"}`)
		default:
			fmt.Fprint(w, `{"code":1024,"msg":"invalid token"}`)
		}
	}))
	defer upstream.Close()
	dir := t.TempDir()
	web := t.TempDir()
	for _, name := range []string{"kp_bridge.js", "kp-fallback.html", "kp-loading.html"} {
		if e = os.WriteFile(filepath.Join(web, name), []byte("public helper"), 0600); e != nil {
			t.Fatal(e)
		}
	}
	s := NewKPSettings(dir, "project-id", ids)
	const origin = "https://hmi.example:9090"
	ordinary, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if e != nil {
		t.Fatal(e)
	}
	h, e := PublicAccessHandler(ordinary, PublicAccessOptions{KP: s.Attach(origin, web, ordinary), Policy: func(ip netip.Addr) bool { return ip.String() != "203.0.113.90" }})
	if e != nil {
		t.Fatal(e)
	}
	s.SetListening(true)
	call := func(method, path, body, peer, requestOrigin, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.RemoteAddr = peer + ":1234"
		r.Header.Set("Origin", requestOrigin)
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("GET", "/kp/kp_bridge.js", "", "192.0.2.8", "", ""); w.Code != 200 {
		t.Fatal("disabled helper", w.Code)
	}
	payload := func(id string) string {
		return fmt.Sprintf(`{"contextId":%q,"loginVersion":"1","userName":"kpuser","identityProof":"proof"}`, id)
	}
	if w := call("POST", "/api/v1/kp/bootstrap", payload("disabled"), "192.0.2.8", "https://kp.example", ""); w.Code != 503 || !strings.Contains(w.Body.String(), "kp_disabled") {
		t.Fatal(w.Code, w.Body.String())
	}
	in := KPSettingsInput{Revision: s.Snapshot().Revision, Enabled: true, Server: upstream.URL, Origins: []string{"https://kp.example", "https://kp2.example:10443"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID}}}
	saved, e := s.Save(in)
	if e != nil {
		t.Fatal(e)
	}
	if saved.Running || !saved.Pending {
		t.Fatal(saved)
	}
	if _, e = s.Save(in); e != errKPConflict {
		t.Fatal("stale save", e)
	}
	if _, e = s.Check(context.Background(), saved.Revision); e != nil {
		t.Fatal(e)
	}
	c, e := LoadKPFile(filepath.Join(dir, "kp-bridge.json"))
	if e != nil || c.WorkspaceID != "project-id" || c.SourceID == "" || c.Users[0].Role != "viewer" {
		t.Fatal(c, e)
	}
	applied, e := s.Apply(saved.Revision)
	if e != nil || !applied.Running || applied.Pending {
		t.Fatal(applied, e)
	}
	var tokens []string
	for i, peer := range []string{"192.0.2.8", "198.51.100.18"} {
		kpOrigin := in.Origins[i]
		w := call("POST", "/api/v1/kp/bootstrap", payload(fmt.Sprint(i)), peer, kpOrigin, "")
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var boot kpbridge.BootstrapReply
		json.Unmarshal(w.Body.Bytes(), &boot)
		w = call("POST", "/api/v1/web/redeem", fmt.Sprintf(`{"ticket":%q}`, boot.Ticket), peer, origin, "")
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var reply kpbridge.WebReply
		json.Unmarshal(w.Body.Bytes(), &reply)
		tokens = append(tokens, reply.WebToken)
		if w = call("GET", "/api/v1/points", "", peer, origin, reply.WebToken); w.Code != 204 {
			t.Fatal(w.Code, w.Body.String())
		}
		if w = call("PUT", "/api/v1/security/kp-settings", "{}", peer, origin, reply.WebToken); w.Code != 403 {
			t.Fatal("public managed", w.Code)
		}
	}
	if w := call("POST", "/api/v1/kp/bootstrap", payload("wrong"), "192.0.2.8", "https://wrong.example", ""); w.Code != 403 {
		t.Fatal("wrong origin", w.Code)
	}
	if w := call("GET", "/kp/kp-fallback.html", "", "203.0.113.90", "", ""); w.Code != 403 {
		t.Fatal("IP admission bypass", w.Code)
	}
	// Saving an incomplete replacement must neither retire the working
	// verifier nor let an unverified draft create a new identity source.
	oldRevision := saved.Revision
	oldBridge := s.bridge
	in.Revision = oldRevision
	in.Server = ""
	saved, e = s.Save(in)
	if e != nil || saved.Ready || !saved.Running || !saved.Pending || saved.ActiveServer != upstream.URL || saved.ActiveRevision != oldRevision {
		t.Fatal("draft replaced active status", saved, e)
	}
	if _, e = s.Check(context.Background(), saved.Revision); e == nil {
		t.Fatal("checked draft as ready")
	}
	failed, e := s.Apply(saved.Revision)
	if e == nil || s.bridge != oldBridge || !failed.Running || failed.StatusError == "" || failed.ActiveServer != upstream.URL {
		t.Fatal("incomplete apply changed active verifier", failed, e)
	}
	if w := call("GET", "/api/v1/points", "", "192.0.2.8", origin, tokens[0]); w.Code != 204 {
		t.Fatal("failed apply retired previous identity", w.Code)
	}
	restartedDraft := NewKPSettings(dir, "project-id", ids)
	restartedDraft.Attach(origin, web, ordinary)
	restartedDraft.SetListening(true)
	if restartedDraft.Snapshot().Running || restartedDraft.Snapshot().Ready || !strings.Contains(restartedDraft.Snapshot().ValidationError, "待完善") {
		t.Fatal("restart enabled incomplete draft", restartedDraft.Snapshot())
	}
	in.Revision = saved.Revision
	in.Enabled = false
	saved, e = s.Save(in)
	if e != nil || !saved.Running || !saved.Pending {
		t.Fatal(saved, e)
	}
	if w := call("GET", "/api/v1/points", "", "192.0.2.8", origin, tokens[0]); w.Code != 204 {
		t.Fatal("save changed runtime", w.Code)
	}
	if _, e = s.Apply(saved.Revision); e != nil {
		t.Fatal(e)
	}
	for _, token := range tokens {
		if _, _, e = ids.ResolveChannel(token, false, "public:web"); e == nil {
			t.Fatal("old linked identity survived apply")
		}
	}
	if _, e = oldBridge.Bootstrap(context.Background(), kpbridge.Bootstrap{ContextID: "late", LoginVersion: "1", UserName: "kpuser", IdentityProof: "proof"}, "192.0.2.8"); e == nil {
		t.Fatal("retired bridge accepted late login")
	}
	if w := call("GET", "/kp/kp-fallback.html", "", "192.0.2.8", "", ""); w.Code != 200 {
		t.Fatal("disabled diagnostic page", w.Code)
	}
	restarted := NewKPSettings(dir, "project-id", ids)
	restarted.Attach(origin, web, ordinary)
	restarted.SetListening(true)
	if restarted.Snapshot().Running || restarted.Snapshot().Pending {
		t.Fatal("disabled state not persisted", restarted.Snapshot())
	}
}

func TestKPSettingsHTTPDraftSaveCompleteAndApply(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	_, sess, token, e := ids.Login("owner", publicFixturePassword, "test", false)
	if e != nil {
		t.Fatal(e)
	}
	s := NewKPSettings(t.TempDir(), "project", ids)
	s.Attach("https://hmi.example", t.TempDir(), http.NotFoundHandler())
	s.SetListening(true)
	const origin = "http://127.0.0.1:12345"
	h, e := IdentityHandler(ids, IdentityOptions{Origin: origin, LocalSetup: true, KPSettings: s}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	call := func(method string, body any, want int) KPSettingsView {
		t.Helper()
		raw, _ := json.Marshal(body)
		r := httptest.NewRequest(method, origin+"/api/v1/security/kp-settings", strings.NewReader(string(raw)))
		r.RemoteAddr = "127.0.0.1:2345"
		r.Header.Set("Origin", origin)
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", sess.CSRF)
		r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: token})
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s: %d %s", method, w.Code, w.Body.String())
		}
		var result KPSettingsView
		if want == 200 && method != "POST" {
			if e := json.Unmarshal(w.Body.Bytes(), &result); e != nil {
				t.Fatal(e)
			}
		}
		return result
	}
	// Even a newly enabled, empty draft is saveable through the real API.
	draft := call("PUT", KPSettingsInput{Revision: "absent", Enabled: true}, 200)
	if draft.Ready || draft.Running || !draft.Pending || draft.ValidationError == "" {
		t.Fatal(draft)
	}
	call("POST", map[string]string{"revision": draft.Revision, "action": "apply"}, 422)
	if s.bridge != nil {
		t.Fatal("draft constructed public bridge")
	}
	// The authenticated ordinary session remains usable after the rejection.
	call("GET", nil, 200)
	input := draft.KPSettingsInput
	input.Server = "http://172.16.1.8:11005"
	input.Origins = []string{"https://kp.example"}
	input.Users = []kpbridge.Grant{{Subject: "2", UserID: owner.ID}}
	saved := call("PUT", input, 200)
	if !saved.Ready || saved.Running || !saved.Pending {
		t.Fatal(saved)
	}
	call("POST", map[string]string{"revision": saved.Revision, "action": "apply"}, 200)
	active := call("GET", nil, 200)
	if !active.Running || !active.Ready || active.Pending || active.ActiveServer != input.Server || active.ActiveRevision != saved.Revision {
		t.Fatal(active)
	}
	input.Revision = saved.Revision
	input.Server = ""
	draft = call("PUT", input, 200)
	if draft.Ready || !draft.Running || draft.ActiveServer != "http://172.16.1.8:11005" {
		t.Fatal(draft)
	}
	call("POST", map[string]string{"revision": draft.Revision, "action": "apply"}, 422)
	active = call("GET", nil, 200)
	if !active.Running || active.ActiveRevision != saved.Revision || active.StatusError == "" {
		t.Fatal(active)
	}
}

func TestKPSettingsManagementBoundaryAndDraftValidation(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	_, e = ids.Change(ids.Actor(owner), "", identity.Change{Username: "viewer", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if e != nil {
		t.Fatal(e)
	}
	_, sess, token, e := ids.Login("owner", publicFixturePassword, "test", false)
	if e != nil {
		t.Fatal(e)
	}
	_, _, viewer, e := ids.Login("viewer", publicFixturePassword, "test2", false)
	if e != nil {
		t.Fatal(e)
	}
	s := NewKPSettings(t.TempDir(), "project", ids)
	h, e := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true, KPSettings: s}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		method, peer, credential, csrf string
		want                           int
	}{
		{"GET", "127.0.0.1:1", "", "", 401}, {"GET", "127.0.0.1:1", viewer, "", 403},
		{"GET", "127.0.0.1:1", token, "", 200}, {"PUT", "127.0.0.1:1", token, "", 403},
		{"PUT", "192.0.2.1:1", token, sess.CSRF, 403}, {"PUT", "127.0.0.1:1", token, sess.CSRF, 200},
		{"PUT", "127.0.0.1:1", token, sess.CSRF, 409},
	} {
		r := httptest.NewRequest(tc.method, "http://127.0.0.1:12345/api/v1/security/kp-settings", strings.NewReader(`{"revision":"absent","enabled":false}`))
		r.RemoteAddr = tc.peer
		r.Header.Set("Origin", "http://127.0.0.1:12345")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", tc.csrf)
		if tc.credential != "" {
			r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: tc.credential})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(tc, w.Code, w.Body.String())
		}
	}
	initial := s.Snapshot()
	for _, bad := range []KPSettingsInput{
		{Enabled: true, Server: "http://public.example", Origins: []string{"https://kp.example"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID}}},
		{Enabled: true, Server: "http://127.0.0.1:11005", Origins: []string{"*"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID}}},
		{Enabled: true, Server: "http://127.0.0.1:11005", Origins: []string{"https://kp.example"}, Users: []kpbridge.Grant{{Subject: "2", UserID: "missing"}}},
		{Enabled: true, Server: "http://127.0.0.1:11005", Origins: []string{"https://kp.example"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID}, {Subject: "2", UserID: owner.ID}}},
	} {
		bad.Revision = initial.Revision
		if _, e = s.Save(bad); e == nil {
			t.Fatal("invalid saved", bad)
		}
		if bad.Server == "http://public.example" && (!strings.Contains(e.Error(), "KP 后台服务地址无效") || !strings.Contains(e.Error(), "HTTP 仅支持")) {
			t.Fatal("server address error did not explain the HTTP boundary", e)
		}
		if s.Snapshot().Revision != initial.Revision {
			t.Fatal("failed save modified file")
		}
	}
}

func TestKPSettingsLegacyFileCompatibilityAndApplyFailure(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	dir := t.TempDir()
	c := KPConfig{SourceID: "stable-source", WorkspaceID: "stable-project", KPServer: "http://127.0.0.1:11005", KPOrigins: []string{"https://kp.example"}, Users: []kpbridge.Grant{{Subject: "2", UserID: owner.ID, DisplayName: "owner", Role: "viewer"}}}
	raw, _ := json.Marshal(c)
	os.WriteFile(filepath.Join(dir, "kp-bridge.json"), raw, 0600)
	s := NewKPSettings(dir, "new-project-name", ids)
	before := s.Snapshot()
	if !before.Enabled {
		t.Fatal("legacy file disabled")
	}
	if _, e = s.Apply(before.Revision); e == nil || s.Snapshot().Running {
		t.Fatal("applied without public listener factory")
	}
	saved, e := s.Save(before.KPSettingsInput)
	if e != nil {
		t.Fatal(e)
	}
	after, e := LoadKPFile(s.file)
	if e != nil || after.SourceID != c.SourceID || after.WorkspaceID != c.WorkspaceID {
		t.Fatal(after, e)
	}
	ordinary, _ := IdentityHandler(ids, IdentityOptions{Origin: "https://hmi.example", PublicReadOnly: true}, http.NotFoundHandler())
	s.Attach("https://hmi.example", t.TempDir(), ordinary)
	s.SetListening(true)
	old := s.bridge
	os.WriteFile(s.file, []byte(`{"bad":"malformed"}`), 0600)
	if _, e = s.Apply(saved.Revision); e == nil || s.bridge != old || !s.Snapshot().Running {
		t.Fatal("failed apply replaced running bridge", e)
	}
}

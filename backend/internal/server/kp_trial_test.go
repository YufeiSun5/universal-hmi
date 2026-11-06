package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestKPTrialEmptyServerFixedAccountScopeRotationAndFormalSwitch(t *testing.T) {
	raw, ps, _ := platform(t)
	visible, _ := ps.Create(points.CreateInput{Station: "A", Name: "visible", SourceType: "manual", DataType: "FLOAT"})
	hidden, _ := ps.Create(points.CreateInput{Station: "B", Name: "hidden", SourceType: "manual", DataType: "FLOAT"})
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	ids.RegisterStations([]string{"A", "B"})
	reader, e := ids.Change(ids.Actor(owner), "", identity.Change{Username: "fixed-reader", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")}}})
	if e != nil {
		t.Fatal(e)
	}
	const origin = "https://hmi.example"
	const kpOrigin = "http://127.0.0.1:11005"
	iam, e := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, raw)
	if e != nil {
		t.Fatal(e)
	}
	s := NewKPSettings(t.TempDir(), "project", ids)
	admitted := true
	h, e := PublicAccessHandler(iam, PublicAccessOptions{KP: s.Attach(origin, t.TempDir(), iam), Policy: func(netip.Addr) bool { return admitted }})
	if e != nil {
		t.Fatal(e)
	}
	s.SetListening(true)
	saved, e := s.Save(KPSettingsInput{Revision: "absent", Enabled: true, Mode: "trial", TrialUserID: reader.ID, Origins: []string{kpOrigin}})
	if e != nil || !saved.Ready || saved.Server != "" || saved.Running || saved.TrialKey != "" {
		t.Fatal("empty-server trial not saveable", e)
	}
	active, e := s.Apply(saved.Revision)
	if e != nil || !active.Running || active.ActiveMode != "trial" || len(active.TrialKey) != 43 || active.TrialUserName != reader.Username {
		t.Fatal("trial not active", e)
	}
	configBytes, _ := os.ReadFile(s.file)
	if strings.Contains(string(configBytes), active.TrialKey) {
		t.Fatal("ephemeral capability persisted")
	}
	call := func(method, path string, body any, token string, want int) *httptest.ResponseRecorder {
		t.Helper()
		b, _ := json.Marshal(body)
		r := httptest.NewRequest(method, origin+path, strings.NewReader(string(b)))
		r.RemoteAddr = "192.0.2.8:1234"
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", origin)
		if strings.HasPrefix(path, "/api/v1/kp/") {
			r.Header.Set("Origin", kpOrigin)
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
		}
		return w
	}
	bootstrap := func(context, proof, name string, want int) kpbridge.BootstrapReply {
		w := call("POST", "/api/v1/kp/bootstrap", kpbridge.Bootstrap{ContextID: context, LoginVersion: "1", UserName: name, IdentityProof: proof}, "", want)
		var b kpbridge.BootstrapReply
		if want == 200 {
			json.Unmarshal(w.Body.Bytes(), &b)
		}
		return b
	}
	bootstrap("missing", "", kpbridge.TrialUsername, 401)
	bootstrap("arbitrary", active.TrialKey, "owner", 403)
	admitted = false
	bootstrap("denied", active.TrialKey, kpbridge.TrialUsername, 403)
	admitted = true
	boot := bootstrap("trial", active.TrialKey, kpbridge.TrialUsername, 200)
	if _, e = s.bridge.Poll(boot.Channel); e == nil {
		t.Fatal("unproven poll renewed trial")
	}
	w := call("POST", "/api/v1/web/redeem", map[string]string{"ticket": boot.Ticket}, "", 200)
	var reply kpbridge.WebReply
	json.Unmarshal(w.Body.Bytes(), &reply)
	if !strings.Contains(w.Body.String(), `"authentication_mode":"kp-trial"`) || reply.Username != reader.Username {
		t.Fatal("wrong trial identity or missing label")
	}
	w = call("GET", "/api/v1/points", nil, reply.WebToken, 200)
	if !strings.Contains(w.Body.String(), visible.ID) || strings.Contains(w.Body.String(), hidden.ID) {
		t.Fatal("station scope escaped", w.Body.String())
	}
	call("POST", "/api/v1/points", map[string]string{}, reply.WebToken, 403)
	call("GET", "/api/v1/security/kp-settings", nil, reply.WebToken, 403)
	call("POST", "/api/v1/kp/poll", map[string]string{"contextId": boot.ContextID, "loginVersion": boot.LoginVersion, "bridgeToken": boot.BridgeToken, "identityProof": active.TrialKey}, "", 200)
	rotated, e := s.Apply(saved.Revision)
	if e != nil || rotated.TrialKey == active.TrialKey {
		t.Fatal("capability not rotated", e)
	}
	call("GET", "/api/v1/points", nil, reply.WebToken, 401)
	bootstrap("old", active.TrialKey, kpbridge.TrialUsername, 401)
	boot = bootstrap("close", rotated.TrialKey, kpbridge.TrialUsername, 200)
	w = call("POST", "/api/v1/web/redeem", map[string]string{"ticket": boot.Ticket}, "", 200)
	json.Unmarshal(w.Body.Bytes(), &reply)
	call("POST", "/api/v1/kp/close", boot.Channel, "", 200)
	call("GET", "/api/v1/points", nil, reply.WebToken, 401)
	boot = bootstrap("switch", rotated.TrialKey, kpbridge.TrialUsername, 200)
	w = call("POST", "/api/v1/web/redeem", map[string]string{"ticket": boot.Ticket}, "", 200)
	json.Unmarshal(w.Body.Bytes(), &reply)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer valid-kp-proof" {
			fmt.Fprint(w, `{"userId":2,"userName":"verified-user"}`)
		} else {
			fmt.Fprint(w, `{"code":1024}`)
		}
	}))
	defer upstream.Close()
	in := saved.KPSettingsInput
	in.Mode = "verified"
	in.Server = upstream.URL
	in.Users = []kpbridge.Grant{{Subject: "2", UserID: reader.ID}}
	saved, e = s.Save(in)
	if e != nil {
		t.Fatal(e)
	}
	formal, e := s.Apply(saved.Revision)
	if e != nil || formal.TrialKey != "" || formal.ActiveMode != "verified" {
		t.Fatal("formal switch failed", e)
	}
	call("GET", "/api/v1/points", nil, reply.WebToken, 401)
	bootstrap("old-trial", rotated.TrialKey, kpbridge.TrialUsername, 401)
	verified := bootstrap("formal", "valid-kp-proof", "verified-user", 200)
	w = call("POST", "/api/v1/web/redeem", map[string]string{"ticket": verified.Ticket}, "", 200)
	if strings.Contains(w.Body.String(), "kp-trial") {
		t.Fatal("formal session labelled trial")
	}
}

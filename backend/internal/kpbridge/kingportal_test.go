package kpbridge

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestKingPortalResponseAndFixedTarget(t *testing.T) {
	body := `{"userId":2,"userName":"admin001"}`
	hits := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.URL.Path != "/api/v1/getUserInfo" || r.Header.Get("Authorization") != "Bearer fixture-proof" || r.URL.Query().Get("projectName") != "采暖" || r.Header.Get("requesttime") == "" || r.Header.Get("onces") == "" {
			t.Error("wrong KP request contract")
		}
		fmt.Fprint(w, body)
	}))
	defer upstream.Close()
	v, err := NewKingPortalVerifier(upstream.URL, "采暖", nil)
	if err != nil {
		t.Fatal(err)
	}
	b := Bootstrap{IdentityProof: "fixture-proof", KPHost: "attacker.invalid", UserName: "forged"}
	id, err := v.Verify(context.Background(), "fixed-source", b)
	if err != nil || id.Subject != "2" || id.UserName != "admin001" || id.MFA || !id.AuthenticatedAt.IsZero() {
		t.Fatalf("identity or assurance: %+v %v", id, err)
	}
	for _, invalid := range []string{`{"code":1024}`, `{"userId":2,"userName":"admin001","code":401}`, `{"userId":null,"userName":"admin001"}`, `{"userId":0,"userName":"admin001"}`, `{"userId":2.1,"userName":"admin001"}`, `{"userId":2}`, `{"data":{"userId":2,"userName":"admin001"}}`, `{"userId":2,"userName":"admin001"} {}`, strings.Repeat("x", 33000)} {
		body = invalid
		if _, err = v.Verify(context.Background(), "fixed-source", b); err == nil {
			t.Errorf("accepted invalid KP response: %.100s", invalid)
		}
	}
	before := hits
	b.IdentityProof = ""
	if _, err = v.Verify(context.Background(), "fixed-source", b); err == nil || hits != before {
		t.Fatal("missing proof reached upstream")
	}
}

func TestKingPortalRejectsRedirectAndUnsafeConfiguration(t *testing.T) {
	for _, origin := range []string{"http://192.0.2.1:11005", "http://kp.example", "https://user:secret@kp.example", "https://kp.example/path", "https://kp.example?x=1", "https://kp.example#x"} {
		if _, e := NewKingPortalVerifier(origin, "", nil); e == nil {
			t.Errorf("accepted %s", origin)
		}
	}
	reached := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached = true }))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 302) }))
	defer upstream.Close()
	v, _ := NewKingPortalVerifier(upstream.URL, "", nil)
	if _, e := v.Verify(context.Background(), "kp", Bootstrap{IdentityProof: "fixture"}); e == nil || reached {
		t.Fatal("redirect forwarded credential")
	}
}

func TestNativeHeartbeatRevalidatesIdentity(t *testing.T) {
	user := 2
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"userId":%d,"userName":"kp-user"}`, user)
	}))
	defer upstream.Close()
	v, _ := NewKingPortalVerifier(upstream.URL, "", nil)
	s, e := New(Options{SourceID: "kp", WorkspaceID: "project", Verifier: v, Grants: []Grant{{Subject: "2", UserID: "hmi-user", DisplayName: "mapped", Role: "viewer"}}})
	if e != nil {
		t.Fatal(e)
	}
	b, e := s.Bootstrap(context.Background(), Bootstrap{ContextID: "window", LoginVersion: "login", UserName: "kp-user", IdentityProof: "proof"}, "ip")
	if e != nil {
		t.Fatal(e)
	}
	web, e := s.Redeem(b.Ticket, "ip")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Poll(b.Channel); e == nil {
		t.Fatal("native lease renewed without upstream proof")
	}
	if _, e = s.PollVerified(context.Background(), b.Channel, "proof"); e != nil {
		t.Fatal(e)
	}
	user = 3
	if _, e = s.PollVerified(context.Background(), b.Channel, "proof"); e == nil {
		t.Fatal("switched user renewed lease")
	}
	if _, e = s.Me(web.WebToken); e == nil {
		t.Fatal("old user remains active")
	}
	if _, e = s.Redeem(b.Ticket, "ip"); e == nil {
		t.Fatal("ticket replay")
	}
}

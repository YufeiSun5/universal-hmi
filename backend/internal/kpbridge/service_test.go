package kpbridge

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func fixture(t *testing.T, capacity int) (*Service, *time.Time) {
	t.Helper()
	now := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	s, e := New(Options{SourceID: "kp-test", WorkspaceID: "default", Capacity: capacity, Now: func() time.Time { return now }, Grants: []Grant{{"A", "user-a", "A", "viewer"}, {"B", "user-b", "B", "operator"}}, Verifier: VerifyFunc(func(_ context.Context, _ string, b Bootstrap) (Identity, error) {
		if b.IdentityProof != "valid" {
			return Identity{}, failure("identity_not_verified", 401)
		}
		return Identity{Subject: b.UserName, UserName: b.UserName}, nil
	})})
	if e != nil {
		t.Fatal(e)
	}
	return s, &now
}
func login(t *testing.T, s *Service, user, ctx, version string) (BootstrapReply, WebReply) {
	t.Helper()
	b, e := s.Bootstrap(context.Background(), Bootstrap{ctx, version, user, "kp.test", "valid"}, "192.0.2.1")
	if e != nil {
		t.Fatal(e)
	}
	w, e := s.Redeem(b.Ticket, "192.0.2.2")
	if e != nil {
		t.Fatal(e)
	}
	return b, w
}
func code(t *testing.T, e error, want string) {
	t.Helper()
	var v *Error
	if !errors.As(e, &v) || v.Code != want {
		t.Fatalf("want %s, got %v", want, e)
	}
}
func TestLogoutRevokesAllBusinessAndRetainsCommandUntilConfirmed(t *testing.T) {
	s, _ := fixture(t, 0)
	b, w := login(t, s, "A", "tab", "v1")
	if w.CanWrite || w.User.ID != "user-a" || w.KPObservedIP == w.WebObservedIP {
		t.Fatalf("bad user: %+v", w)
	}
	for i := 0; i < 2; i++ {
		v, e := s.Logout(w.WebToken)
		if e != nil || v.State != "logout_requested" {
			t.Fatal(v, e)
		}
		_, e = s.Me(w.WebToken)
		code(t, e, "business_session_revoked")
		p, e := s.Poll(b.Channel)
		if e != nil || p.Command != "logout" {
			t.Fatal(p, e)
		}
	}
	f := false
	v, e := s.LogoffResult(LogoffResult{b.Channel, &f})
	if e != nil || v.State != "logout_requested" {
		t.Fatal(v, e)
	}
	p, _ := s.Poll(b.Channel)
	if p.Command != "logout" {
		t.Fatal(p)
	}
	_, e = s.LogoffResult(LogoffResult{Channel: b.Channel})
	code(t, e, "success_required")
	y := true
	v, e = s.LogoffResult(LogoffResult{b.Channel, &y})
	if e != nil || v.State != "closed" {
		t.Fatal(v, e)
	}
	v2, e := s.Logout(w.WebToken)
	if e != nil || v2.State != "closed" {
		t.Fatal(v2, e)
	} // Never reopen terminal sessions.
	if _, e = s.LogoffResult(LogoffResult{b.Channel, &y}); e != nil {
		t.Fatal(e)
	}
	_, e = s.Me(w.WebToken)
	code(t, e, "business_session_revoked")
}
func TestIndependentLoginVersionsAndChannels(t *testing.T) {
	s, _ := fixture(t, 0)
	old, ow := login(t, s, "A", "tab", "old")
	_, nw := login(t, s, "B", "tab", "new")
	other, tw := login(t, s, "B", "other", "new")
	_, _ = s.Logout(ow.WebToken)
	_, _ = s.Close(old.Channel)
	if _, e := s.Me(nw.WebToken); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Me(tw.WebToken); e != nil {
		t.Fatal(e)
	}
	_, e := s.Me(other.BridgeToken)
	code(t, e, "invalid_web_token")
	other.BridgeToken = tw.WebToken
	_, e = s.Poll(other.Channel)
	code(t, e, "invalid_bridge_token")
}
func TestOneUseTicketRetryAndConcurrency(t *testing.T) {
	s, _ := fixture(t, 0)
	in := Bootstrap{"tab", "v1", "A", "kp", "valid"}
	a, e := s.Bootstrap(context.Background(), in, "ip")
	if e != nil {
		t.Fatal(e)
	}
	b, e := s.Bootstrap(context.Background(), in, "ip")
	if e != nil || a != b {
		t.Fatal(a, b, e)
	}
	var wg sync.WaitGroup
	results := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, e := s.Redeem(a.Ticket, "ip"); results <- e }()
	}
	wg.Wait()
	close(results)
	success := 0
	for e := range results {
		if e == nil {
			success++
		} else {
			code(t, e, "ticket_used_or_expired")
		}
	}
	if success != 1 {
		t.Fatalf("%d redemptions", success)
	}
	_, e = s.Bootstrap(context.Background(), in, "ip")
	code(t, e, "login_already_started")
}
func TestLeaseOnlyKPHeartbeatAndAbsoluteExpiry(t *testing.T) {
	s, now := fixture(t, 0)
	b, w := login(t, s, "B", "tab", "v1")
	*now = now.Add(20 * time.Second)
	if _, e := s.Me(w.WebToken); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Status(w.WebToken); e != nil {
		t.Fatal(e)
	}
	*now = now.Add(10 * time.Second)
	v, e := s.Status(w.WebToken)
	if e != nil || v.State != "expired" {
		t.Fatal(v, e)
	}
	p, e := s.Poll(b.Channel)
	if e != nil || p.Command != "rebootstrap" {
		t.Fatal(p, e)
	}
	_, e = s.Me(w.WebToken)
	code(t, e, "business_session_revoked")
	v, e = s.Logout(w.WebToken)
	if e != nil || v.State != "expired" {
		t.Fatal(v, e)
	}
	s.o.AbsoluteTTL = time.Minute
	b, w = login(t, s, "B", "tab", "v2")
	*now = now.Add(20 * time.Second)
	_, _ = s.Poll(b.Channel)
	*now = now.Add(20 * time.Second)
	if _, e = s.Me(w.WebToken); e != nil {
		t.Fatal(e)
	}
	*now = w.ExpiresAt
	_, e = s.Me(w.WebToken)
	code(t, e, "business_session_revoked")
}
func TestInvalidProofUnprovisionedUserAndCapacityCleanup(t *testing.T) {
	s, now := fixture(t, 1)
	_, e := s.Bootstrap(context.Background(), Bootstrap{"tab", "v", "A", "kp", "forged"}, "ip")
	code(t, e, "identity_not_verified")
	_, e = s.Bootstrap(context.Background(), Bootstrap{"tab", "v", "C", "kp", "valid"}, "ip")
	code(t, e, "user_not_provisioned")
	b, w := login(t, s, "A", "tab", "v1")
	_, e = s.Bootstrap(context.Background(), Bootstrap{"other", "v", "A", "kp", "valid"}, "ip")
	code(t, e, "bridge_capacity_reached")
	_, _ = s.Close(b.Channel)
	*now = now.Add(2 * time.Minute)
	_, e = s.Status(w.WebToken)
	code(t, e, "invalid_web_token")
	login(t, s, "A", "other", "v")
}
func TestPendingVerifierCannotTrustUserName(t *testing.T) {
	s, e := New(Options{SourceID: "kp", WorkspaceID: "default", Grants: []Grant{{"A", "a", "A", "viewer"}}})
	if e != nil {
		t.Fatal(e)
	}
	_, e = s.Bootstrap(context.Background(), Bootstrap{"tab", "v", "A", "kp", ""}, "ip")
	code(t, e, "identity_verifier_unconfigured")
}

func TestSameUserMultipleIPsAndNATStayIndependent(t *testing.T) {
	s, _ := fixture(t, 0)
	var channels []BootstrapReply
	var web []WebReply
	// Two different IPs share A; a NAT address is shared by both A and B.
	for i, tc := range []struct{ user, ip string }{{"A", "192.0.2.10"}, {"A", "192.0.2.20"}, {"A", "198.51.100.1"}, {"B", "198.51.100.1"}} {
		b, e := s.Bootstrap(context.Background(), Bootstrap{fmt.Sprintf("terminal-%d", i), "v1", tc.user, "same-kp-host", "valid"}, tc.ip)
		if e != nil {
			t.Fatal(e)
		}
		w, e := s.Redeem(b.Ticket, tc.ip)
		if e != nil {
			t.Fatal(e)
		}
		channels = append(channels, b)
		web = append(web, w)
	}
	_, _ = s.Logout(web[0].WebToken)
	yes := true
	_, _ = s.LogoffResult(LogoffResult{channels[0].Channel, &yes})
	for i := 1; i < len(web); i++ {
		v, e := s.Me(web[i].WebToken)
		if e != nil || v.State != "active" || v.User.ID != web[i].User.ID {
			t.Fatal(i, v, e)
		}
		if p, e := s.Poll(channels[i].Channel); e != nil || p.Command != "none" {
			t.Fatal(i, p, e)
		}
	}
	// A credential is attached to the exact instance, not only its username/IP.
	wrong := channels[1].Channel
	wrong.BridgeToken = channels[2].BridgeToken
	_, e := s.Close(wrong)
	code(t, e, "invalid_bridge_token")
	if _, e := s.Me(web[1].WebToken); e != nil {
		t.Fatal(e)
	}
}

func TestExpiredLogoutNeverAutomaticallyRebootstraps(t *testing.T) {
	s, now := fixture(t, 0)
	b, w := login(t, s, "A", "tab", "v1")
	_, _ = s.Logout(w.WebToken)
	*now = now.Add(31 * time.Second)
	p, e := s.Poll(b.Channel)
	if e != nil || p.State != "expired" || p.Command != "logout" {
		t.Fatal(p, e)
	}
	no := false
	v, e := s.LogoffResult(LogoffResult{b.Channel, &no})
	if e != nil || v.State != "expired" {
		t.Fatal(v, e)
	}
	yes := true
	v, e = s.LogoffResult(LogoffResult{b.Channel, &yes})
	if e != nil || v.State != "closed" {
		t.Fatal(v, e)
	}
	p, e = s.Poll(b.Channel)
	if e != nil || p.Command != "closed" {
		t.Fatal(p, e)
	}
	_, e = s.Me(w.WebToken)
	code(t, e, "business_session_revoked")
}

func TestIdentityCollisionIdleCleanupAndRestart(t *testing.T) {
	s, now := fixture(t, 1)
	b, w := login(t, s, "A", "same", "v1")
	_, e := s.Bootstrap(context.Background(), Bootstrap{"same", "v1", "B", "kp", "valid"}, "other-ip")
	code(t, e, "identity_conflict")
	*now = now.Add(3 * time.Minute)
	// Cleanup uses the actual lease deadline even when no request ran for minutes.
	login(t, s, "B", "next", "v1")
	_, e = s.Poll(b.Channel)
	code(t, e, "invalid_bridge_token")
	fresh, _ := fixture(t, 0)
	_, e = fresh.Me(w.WebToken)
	code(t, e, "invalid_web_token")
}

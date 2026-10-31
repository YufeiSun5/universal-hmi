package identity

import (
	"errors"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func publicRule(cidr string) PublicIPRule {
	return PublicIPRule{CIDR: cidr, OwnerLabel: "Synthetic owner", Enabled: true}
}
func TestPublicIPPolicyAuthorityAndExpiry(t *testing.T) {
	s, u := fixture(t)
	actor := s.Actor(u)
	ip := netip.MustParseAddr("192.0.2.1")
	if s.PublicIPAllowed(ip) {
		t.Fatal("uninitialized allowed")
	}
	if err := s.InitPublicIPPolicy([]PublicIPRule{publicRule("192.0.2.0/24")}); err != nil {
		t.Fatal(err)
	}
	p, err := s.PublicIPPolicy(actor)
	if err != nil {
		t.Fatal(err)
	}
	if p.Source != "file" || p.Revision != 0 || !s.PublicIPAllowed(ip) {
		t.Fatal(p)
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM security_settings").Scan(&n)
	if n != 0 {
		t.Fatal("bootstrap persisted")
	}
	p.Rules[0].OwnerUserID = u.ID
	expiry := time.Now().Add(time.Hour)
	p.Rules[0].ExpiresAt = &expiry
	saved, err := s.SavePublicIPPolicy(actor, 0, p.Rules)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Revision != 1 || saved.Source != "database" {
		t.Fatal(saved)
	}
	// Reinitializing models restart loading without consulting invalid obsolete file data.
	if err = s.InitPublicIPPolicy([]PublicIPRule{publicRule("obsolete-invalid")}); err != nil {
		t.Fatal(err)
	}
	p, err = s.PublicIPPolicy(actor)
	if err != nil || p.Rules[0].OwnerStatus != "active" {
		t.Fatalf("%+v %v", p, err)
	}
	p.Rules[0].CIDR = "203.0.113.0/24"
	*p.Rules[0].ExpiresAt = time.Now().Add(-time.Hour)
	if !s.PublicIPAllowed(ip) {
		t.Fatal("snapshot alias")
	}
	s.now = func() time.Time { return expiry }
	if s.PublicIPAllowed(ip) {
		t.Fatal("expiry boundary")
	}
	audits, err := s.Audits(actor)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range audits {
		if a.Action == "public_ip_policy.change" {
			found = true
		}
	}
	if !found {
		t.Fatal("no audit")
	}
}
func TestPublicIPPolicyConflictAndFailurePreservesAuthority(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	if err := s.InitPublicIPPolicy(nil); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := s.SavePublicIPPolicy(a, 0, []PublicIPRule{publicRule("192.0.2.1")})
			results <- e
		}()
	}
	wg.Wait()
	close(results)
	success, conflict := 0, 0
	for e := range results {
		if e == nil {
			success++
		} else if errors.Is(e, ErrPublicIPConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal(success, conflict)
	}
	// Abort audit: policy write and audit must roll back together.
	_, err := s.db.Exec("CREATE TRIGGER reject_policy_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.SavePublicIPPolicy(a, 1, nil); !errors.Is(err, ErrPublicIPUnavailable) {
		t.Fatal(err)
	}
	if !s.PublicIPAllowed(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("failed write changed memory")
	}
	if err = s.InitPublicIPPolicy(nil); err != nil {
		t.Fatal(err)
	}
	p, err := s.PublicIPPolicy(a)
	if err != nil || p.Revision != 1 || len(p.Rules) != 1 {
		t.Fatalf("rollback: %+v %v", p, err)
	}
}
func TestPublicIPPolicyInvalidAndOwnerMetadata(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	if err := s.InitPublicIPPolicy(nil); err != nil {
		t.Fatal(err)
	}
	for _, cidr := range []string{"bad", "192.0.2.0/33", "fe80::1%eth0", "::ffff:192.0.2.0/120"} {
		if _, e := s.SavePublicIPPolicy(a, 0, []PublicIPRule{publicRule(cidr)}); !errors.Is(e, ErrPublicIPInvalid) {
			t.Fatal(cidr, e)
		}
	}
	if _, e := s.PublicIPPolicy(authorization.Actor{}); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	if _, e := s.SavePublicIPPolicy(authorization.Actor{}, 0, nil); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	r := publicRule("::ffff:192.0.2.1")
	r.OwnerUserID = "missing"
	if _, e := s.SavePublicIPPolicy(a, 0, []PublicIPRule{r}); !errors.Is(e, ErrPublicIPInvalid) {
		t.Fatal(e)
	}
	r.OwnerUserID = u.ID
	p, e := s.SavePublicIPPolicy(a, 0, []PublicIPRule{r})
	if e != nil {
		t.Fatal(e)
	}
	// A historical missing owner does not revoke network approval or prevent load.
	_, e = s.db.Exec("UPDATE users SET id=? WHERE id=?", "replacement", u.ID)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.InitPublicIPPolicy(nil); e != nil {
		t.Fatal(e)
	}
	if !s.PublicIPAllowed(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("owner became authorization")
	}
	s.publicIPMu.RLock()
	snapshot, e := s.publicIPSnapshotLocked()
	s.publicIPMu.RUnlock()
	if e != nil || snapshot.Rules[0].OwnerStatus != "missing" || snapshot.Rules[0].ID != p.Rules[0].ID {
		t.Fatal(snapshot, e)
	}
}
func TestPublicIPPolicyMalformedStoredNeverFallsBack(t *testing.T) {
	for _, raw := range []string{`{`, `{"schema":2,"revision":1,"rules":[]}`, `{"revision":1,"rules":[]}`, `{"schema":1,"revision":1,"rules":[],"unknown":true}`} {
		t.Run(raw, func(t *testing.T) {
			s, _ := fixture(t)
			if _, e := s.db.Exec("INSERT INTO security_settings(key,value) VALUES(?,?)", publicIPKey, raw); e != nil {
				t.Fatal(e)
			}
			if e := s.InitPublicIPPolicy([]PublicIPRule{publicRule("0.0.0.0/0")}); e == nil {
				t.Fatal("invalid persisted accepted")
			}
			if s.PublicIPAllowed(netip.MustParseAddr("192.0.2.1")) {
				t.Fatal("file fallback")
			}
			var after string
			s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicIPKey).Scan(&after)
			if after != raw {
				t.Fatal("rewrote invalid data")
			}
		})
	}
}

func TestPublicIPPolicyBoundsAndDisabledOwner(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	if e := s.InitPublicIPPolicy(nil); e != nil {
		t.Fatal(e)
	}
	valid := publicRule("2001:db8::/32")
	cases := [][]PublicIPRule{}
	for _, mutate := range []func(*PublicIPRule){
		func(r *PublicIPRule) { r.ID = "invented-id" }, func(r *PublicIPRule) { r.OwnerLabel = string(make([]byte, 129)) },
		func(r *PublicIPRule) { r.Remark = string(make([]byte, 513)) }, func(r *PublicIPRule) { r.OwnerUserID = "bad id" },
		func(r *PublicIPRule) { v := time.Time{}; r.ExpiresAt = &v },
	} {
		r := valid
		mutate(&r)
		cases = append(cases, []PublicIPRule{r})
	}
	many := make([]PublicIPRule, 257)
	for i := range many {
		many[i] = valid
	}
	cases = append(cases, many)
	for _, rules := range cases {
		if _, e := s.SavePublicIPPolicy(a, 0, rules); !errors.Is(e, ErrPublicIPInvalid) {
			t.Fatal(e)
		}
	}
	valid.OwnerUserID = u.ID
	p, e := s.SavePublicIPPolicy(a, 0, []PublicIPRule{valid})
	if e != nil {
		t.Fatal(e)
	}
	if p.Rules[0].OwnerStatus != "active" {
		t.Fatal(p)
	}
	if _, e = s.SavePublicIPPolicy(a, 1, []PublicIPRule{p.Rules[0], p.Rules[0]}); !errors.Is(e, ErrPublicIPInvalid) {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("UPDATE users SET disabled=1 WHERE id=?", u.ID); e != nil {
		t.Fatal(e)
	}
	s.publicIPMu.RLock()
	snapshot, e := s.publicIPSnapshotLocked()
	s.publicIPMu.RUnlock()
	if e != nil || snapshot.Rules[0].OwnerStatus != "disabled" {
		t.Fatal(snapshot, e)
	}
	if !s.PublicIPAllowed(netip.MustParseAddr("2001:db8::1")) {
		t.Fatal("disabled metadata owner revoked IP")
	}
	if s.PublicIPAllowed(netip.Addr{}) || s.PublicIPAllowed(netip.MustParseAddr("fe80::1%eth0")) {
		t.Fatal("invalid source accepted")
	}
}

func TestPublicIPPolicyReopenAndReadFailure(t *testing.T) {
	dir := t.TempDir()
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	u, e := s.Bootstrap("owner", testPassword)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.InitPublicIPPolicy(nil); e != nil {
		t.Fatal(e)
	}
	p, e := s.SavePublicIPPolicy(s.Actor(u), 0, []PublicIPRule{publicRule("192.0.2.1")})
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if e = s.InitPublicIPPolicy([]PublicIPRule{publicRule("invalid-file")}); e != nil {
		t.Fatal(e)
	}
	reloaded, e := s.PublicIPPolicy(s.Actor(u))
	if e != nil || reloaded.Revision != p.Revision || reloaded.Rules[0].ID != p.Rules[0].ID {
		t.Fatal(reloaded, e)
	}
	// Disabled rules are persisted and immediately revoke the current match.
	reloaded.Rules[0].Enabled = false
	if _, e = s.SavePublicIPPolicy(s.Actor(u), 1, reloaded.Rules); e != nil {
		t.Fatal(e)
	}
	if s.PublicIPAllowed(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("disabled rule admitted")
	}
	s.Close()
	if e = s.InitPublicIPPolicy([]PublicIPRule{publicRule("0.0.0.0/0")}); !errors.Is(e, ErrPublicIPUnavailable) {
		t.Fatal(e)
	}
	if s.PublicIPAllowed(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("read error fell back")
	}
}

func TestPublicIPPolicyUnlabelledBootstrap(t *testing.T) {
	s, u := fixture(t)
	if e := s.InitPublicIPPolicy([]PublicIPRule{{CIDR: "192.0.2.1", Enabled: true}}); e != nil {
		t.Fatal(e)
	}
	p, e := s.PublicIPPolicy(s.Actor(u))
	if e != nil {
		t.Fatal(e)
	}
	if p.Rules[0].OwnerLabel != "" {
		t.Fatal("invented owner")
	}
	if _, e = s.SavePublicIPPolicy(s.Actor(u), 0, p.Rules); e != nil {
		t.Fatal(e)
	}
}

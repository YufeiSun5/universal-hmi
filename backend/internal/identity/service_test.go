package identity

import (
	"encoding/base32"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
	"time"
)

const testPassword = "a test password longer than 15"

func fixture(t *testing.T) (*Service, User) {
	t.Helper()
	s, e := Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	u, e := s.Bootstrap("owner", testPassword)
	if e != nil {
		t.Fatal(e)
	}
	return s, u
}
func TestRolesRevocationAndStableScope(t *testing.T) {
	s, owner := fixture(t)
	a := s.Actor(owner)
	if !owner.Grants.Develop() || owner.Grants.Control {
		t.Fatal("bootstrap role separation")
	}
	if _, e := s.Bootstrap("second", testPassword); e == nil {
		t.Fatal("bootstrap reopened")
	}
	if e := s.RegisterStations([]string{"A", "B"}); e != nil {
		t.Fatal(e)
	}
	aid := s.StationID("A")
	s.RegisterStations([]string{"A", "C"})
	if s.StationID("A") != aid {
		t.Fatal("unstable station identity")
	}
	u, e := s.Change(a, "", Change{Username: "reader", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{aid}}})
	if e != nil {
		t.Fatal(e)
	}
	ua := s.Actor(u)
	if !ua.Station("A") || ua.Station("B") || ua.Grants.Develop() {
		t.Fatal("scope escape")
	}
	_, _, token, e := s.Login("reader", testPassword, "one", true)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Change(ua, "", Change{Username: "escalate", Password: testPassword, Grants: owner.Grants}); e == nil {
		t.Fatal("viewer escalated")
	}
	_, e = s.Change(a, u.ID, Change{Username: u.Username, Disabled: true, Version: u.Version, Grants: u.Grants})
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Resolve(token, false); e == nil || ua.Active() {
		t.Fatal("revoked actor/session survived")
	}
	if _, e = s.Change(a, owner.ID, Change{Username: "owner", Version: owner.Version, Grants: owner.Grants}); e == nil {
		t.Fatal("self privilege change allowed")
	}
}
func TestMFAAgainstRFC6238ReplayRecoveryAndPasswordChange(t *testing.T) {
	for _, v := range []struct {
		at   int64
		want string
	}{{59, "94287082"}, {1111111109, "07081804"}, {1111111111, "14050471"}, {1234567890, "89005924"}, {2000000000, "69279037"}, {20000000000, "65353130"}} {
		if got := totp([]byte("12345678901234567890"), v.at/30, 8); got != v.want {
			t.Fatalf("RFC6238 %d: %s", v.at, got)
		}
	}
	s, u := fixture(t)
	at := time.Unix(2000000000, 0)
	s.now = func() time.Time { return at }
	_, sess, token, e := s.Login(u.Username, testPassword, "one", true)
	if e != nil {
		t.Fatal(e)
	}
	_, _, other, e := s.Login(u.Username, testPassword, "two", true)
	if e != nil {
		t.Fatal(e)
	}
	a := s.Actor(u)
	a.Valid = func() bool { _, _, e := s.Resolve(token, false); return e == nil }
	secret, e := s.BeginMFA(a, testPassword)
	if e != nil {
		t.Fatal(e)
	}
	bytes, e := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if e != nil {
		t.Fatal(e)
	}
	code := totp(bytes, at.Unix()/30, 6)
	recovery, e := s.ConfirmMFA(a, code, sess.ID)
	if e != nil || len(recovery) != 8 {
		t.Fatalf("confirm %v", e)
	}
	if _, _, e = s.Resolve(other, false); e == nil {
		t.Fatal("other pre-MFA session survived")
	}
	if _, ss, e := s.Resolve(token, false); e != nil || !ss.MFA {
		t.Fatal("current session not upgraded")
	}
	if _, _, _, e = s.Login(u.Username, testPassword, "three", true, code); e == nil {
		t.Fatal("OTP replay accepted")
	}
	at = at.Add(30 * time.Second)
	if _, ss, _, e := s.Login(u.Username, testPassword, "four", true, totp(bytes, at.Unix()/30, 6)); e != nil || !ss.MFA {
		t.Fatalf("fresh OTP %v", e)
	}
	if _, _, _, e = s.Login(u.Username, testPassword, "five", true, recovery[0]); e != nil {
		t.Fatal(e)
	}
	if _, _, _, e = s.Login(u.Username, testPassword, "six", true, recovery[0]); e == nil {
		t.Fatal("recovery replay accepted")
	}
	if e = s.ChangePassword(a, testPassword, "a different password longer than 15"); e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Resolve(token, false); e == nil {
		t.Fatal("password change kept session")
	}
}
func TestSessionExpiryAndGrantCeiling(t *testing.T) {
	s, u := fixture(t)
	at := time.Now()
	s.now = func() time.Time { return at }
	_, _, token, e := s.Login(u.Username, testPassword, "one", false)
	if e != nil {
		t.Fatal(e)
	}
	at = at.Add(31 * time.Minute)
	if _, _, e = s.Resolve(token, false); e == nil {
		t.Fatal("idle session survived")
	}
	admin := authorization.Grants{Roles: []string{"admin"}, AllStations: true}
	if admin.Develop() || admin.MayGrant(u.Grants) || admin.MayGrant(authorization.Grants{Roles: []string{"operator"}, Control: true}) {
		t.Fatal("admin acquired engineer/control")
	}
}

package identity

import (
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestOnlinePresenceExpiryIdentityAndRevocation(t *testing.T) {
	s, owner := fixture(t)
	actor := s.Actor(owner)
	now := time.Now()
	s.now = func() time.Time { return now }
	reader, err := s.Change(actor, "", Change{Username: "reader", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if err != nil {
		t.Fatal(err)
	}
	_, session1, token1, err := s.Login("reader", testPassword, "one", true)
	if err != nil {
		t.Fatal(err)
	}
	_, _, token2, err := s.Login("reader", testPassword, "two", true)
	if err != nil {
		t.Fatal(err)
	}
	s.ObserveConnection(token1, "192.168.1.11:1234", "Mozilla/5.0")
	s.ObserveConnection(token1, "192.168.1.11:2345", "Mozilla/5.0")
	s.ObserveConnection(token2, "192.168.1.12:1234", "Dart/3.9")
	v, err := s.Online(actor)
	if err != nil || v.Connections != 2 || v.Users != 1 {
		t.Fatalf("%+v %v", v, err)
	}
	for _, row := range v.Items {
		if row.Username != "reader" || row.UserID != reader.ID || row.IP == "" {
			t.Fatal(row)
		}
	}
	if _, err := s.Online(s.Actor(reader)); err != ErrDenied {
		t.Fatal("viewer read online list", err)
	}
	readonly := actor
	readonly.ReadOnly = true
	if _, err := s.Online(readonly); err != ErrDenied {
		t.Fatal("public readonly read online list", err)
	}
	now = now.Add(OnlineWindow)
	v, err = s.Online(actor)
	if err != nil || v.Connections != 0 {
		t.Fatalf("stale presence %+v %v", v, err)
	}
	if _, _, err := s.Resolve(token1, false); err != nil {
		t.Fatal("presence expiry revoked login", err)
	}
	s.ObserveConnection(token1, "192.168.1.11:1234", "Mozilla/5.0")
	_, current, err := s.Resolve(token1, false)
	if err != nil || !current.Last.Equal(session1.Last) {
		t.Fatal("heartbeat changed activity")
	}
	if err := s.Revoke(actor, reader.ID, session1.ID); err != nil {
		t.Fatal(err)
	}
	v, err = s.Online(actor)
	if err != nil || v.Connections != 0 {
		t.Fatalf("revoked presence %+v %v", v, err)
	}
}

func TestOnlineExcludesInvalidKPLease(t *testing.T) {
	s, owner := fixture(t)
	valid := true
	token := "test-kp-token-at-least-thirty-two-characters"
	if err := s.LinkKPToken(owner.ID, token, nil, func() bool { return valid }); err != nil {
		t.Fatal(err)
	}
	s.ObserveConnection(token, "192.168.1.12:4567", "Mozilla/5.0")
	v, err := s.Online(s.Actor(owner))
	if err != nil || v.Connections != 1 || v.Items[0].Client != "KP" {
		t.Fatalf("%+v %v", v, err)
	}
	valid = false
	v, err = s.Online(s.Actor(owner))
	if err != nil || v.Connections != 0 {
		t.Fatalf("invalid KP lease %+v %v", v, err)
	}
}

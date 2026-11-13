package identity

import (
	"crypto/elliptic"
	"crypto/x509"
	"strings"
	"testing"
	"time"
)

func TestAccountSessionsSurviveIdleActiveAndOtherLogins(t *testing.T) {
	for _, channel := range []string{"", "public:web"} {
		t.Run("channel="+channel, func(t *testing.T) {
			s, u := fixture(t)
			now := time.Now()
			s.now = func() time.Time { return now }
			_, session, token, err := s.LoginChannel(u.Username, testPassword, "first", true, channel)
			if err != nil || !session.Expires.IsZero() {
				t.Fatal("expected account session without deadline", session, err)
			}
			for _, age := range []time.Duration{31 * time.Minute, 9 * time.Hour, 30 * 24 * time.Hour} {
				now = session.Started.Add(age)
				// A new password or federated login must not sweep an idle account session.
				if _, _, _, err = s.LoginChannel(u.Username, testPassword, "another", true, channel); err != nil {
					t.Fatal(err)
				}
				if err = s.LinkFederated(u.ID, strings.Repeat("x", 32)+age.String(), true, now, func() bool { return true }); err != nil {
					t.Fatal(err)
				}
				if _, current, err := s.ResolveChannel(token, false, channel); err != nil || current.ID != session.ID {
					t.Fatal("idle session lost", age, current, err)
				}
				if _, _, err = s.ResolveChannel(token, true, channel); err != nil {
					t.Fatal("active session lost", age, err)
				}
			}
			listed, err := s.Sessions(s.Actor(u))
			found := false
			for _, item := range listed {
				found = found || item.ID == session.ID
			}
			if err != nil || !found {
				t.Fatal("retained session missing from management", err)
			}
			if err = s.Revoke(s.Actor(u), u.ID, session.ID); err != nil {
				t.Fatal(err)
			}
			if _, _, err = s.ResolveChannel(token, false, channel); err == nil {
				t.Fatal("explicit revocation ignored")
			}
		})
	}
}

func TestDeviceSessionNoTimeoutStillChecksCertificate(t *testing.T) {
	s, u := fixture(t)
	now := time.Now()
	s.now = func() time.Time { return now }
	actor := s.Actor(u)
	csr, key := registrationTestCSR(t, elliptic.P256())
	registration, err := s.CreateDeviceRegistration(actor, 0, u.ID, "retained device", csr)
	if err != nil {
		t.Fatal(err)
	}
	id := registration.Items[0].ID
	if _, err = s.ApproveDeviceRegistration(actor, registration.Revision, id, now.AddDate(2, 0, 0)); err != nil {
		t.Fatal(err)
	}
	raw, leaf := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.NotAfter = now.AddDate(1, 0, 0) })
	if _, err = s.ApproveDeviceCertificateForLeaf(actor, 0, id, raw); err != nil {
		t.Fatal(err)
	}
	_, session, token, err := s.LoginDevice(u.Username, testPassword, "device", true, leaf)
	if err != nil || !session.Expires.IsZero() {
		t.Fatal(session, err)
	}
	now = now.Add(30 * 24 * time.Hour)
	if _, _, err = s.ResolveDevice(token, false, leaf); err != nil {
		t.Fatal("idle device was logged out", err)
	}
	now = leaf.NotAfter.Add(time.Second)
	if _, _, err = s.ResolveDevice(token, false, leaf); err == nil {
		t.Fatal("expired certificate accepted")
	}
}

func TestFederatedSessionStillFollowsUpstreamLifetime(t *testing.T) {
	s, u := fixture(t)
	now := time.Now()
	s.now = func() time.Time { return now }
	valid := true
	token := strings.Repeat("f", 32)
	if err := s.LinkFederated(u.ID, token, true, now, func() bool { return valid }); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Resolve(token, true); err != nil {
		t.Fatal(err)
	}
	valid = false
	if _, _, err := s.Resolve(token, false); err == nil {
		t.Fatal("upstream logout ignored")
	}
	valid = true
	if err := s.LinkFederated(u.ID, token, true, now, func() bool { return valid }); err != nil {
		t.Fatal(err)
	}
	now = now.Add(31 * time.Minute)
	if _, _, err := s.Resolve(token, false); err == nil {
		t.Fatal("federated timeout lost")
	}
}

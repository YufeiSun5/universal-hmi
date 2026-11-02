package identity

import (
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestDeviceSessionOwnerChannelAndApprovalGeneration(t *testing.T) {
	s, owner, registrations, raw, leaf := certificateFixture(t)
	a := s.Actor(owner)
	id := registrations.Items[0].ID
	approved, err := s.ApproveDeviceCertificate(a, 0, id, raw, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	_, _, deviceToken, err := s.LoginDevice("owner", testPassword, "device", true, leaf)
	if err != nil {
		t.Fatal(err)
	}
	if _, session, err := s.ResolveDevice(deviceToken, false, leaf); err != nil || session.Channel != "public:device" {
		t.Fatal(session, err)
	}
	for _, channel := range []string{"", "public:web", "public:device"} {
		if _, _, err := s.ResolveChannel(deviceToken, true, channel); err == nil {
			t.Fatal("copied token accepted", channel)
		}
	}
	_, _, webToken, err := s.LoginChannel("owner", testPassword, "web", true, "public:web")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ResolveDevice(webToken, false, leaf); err == nil {
		t.Fatal("Web session accepted as device")
	}
	if _, _, err := s.ResolveDevice(deviceToken, false, nil); err == nil {
		t.Fatal("missing TLS certificate accepted")
	}
	_, err = s.Change(a, "", Change{Username: "other", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.LoginDevice("other", testPassword, "other", true, leaf); err == nil {
		t.Fatal("device owner mismatch accepted")
	}
	// A channel-copy failure cannot destroy the legitimate device session.
	if _, _, err := s.ResolveDevice(deviceToken, false, leaf); err != nil {
		t.Fatal(err)
	}
	approved, err = s.RevokeDeviceCertificate(a, approved.Revision, id)
	if err != nil {
		t.Fatal(err)
	}
	// Reapprove before resolving: generation binding still prevents resurrection.
	if _, err := s.ApproveDeviceCertificate(a, approved.Revision, id, raw, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ResolveDevice(deviceToken, false, leaf); err == nil {
		t.Fatal("old session resurrected by reapproval")
	}
	if _, _, _, err := s.LoginDevice("owner", testPassword, "device", true, leaf); err != nil {
		t.Fatal("new approval could not log in", err)
	}
}

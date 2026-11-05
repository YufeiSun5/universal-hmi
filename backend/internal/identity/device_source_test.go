package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestDeviceSourceHintsPreserveOldRecordsAndApproval(t *testing.T) {
	for _, tc := range []struct{ name, kind string }{
		{"HMI mobile installation", "android"},
		{"HMI Browser 0123456789abcdef0123456789abcdef", "windows_browser"},
		{"HMI Browser not-a-valid-installation", "unknown"},
		{"custom device", "unknown"},
	} {
		t.Run(tc.kind+tc.name, func(t *testing.T) {
			s, owner := fixture(t)
			key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			_, leaf := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.Subject.CommonName = tc.name })
			_, _, token, err := s.LoginDevice("owner", testPassword, "::ffff:192.0.2.42", true, leaf)
			if !errors.Is(err, ErrDeviceApprovalPending) || token != "" {
				t.Fatal("source metadata bypassed approval", err)
			}
			snap, err := s.DeviceRegistrations(s.Actor(owner))
			if err != nil || len(snap.Items) != 1 || snap.Items[0].ClientKind != tc.kind || snap.Items[0].RequestIP != "192.0.2.42" {
				t.Fatal(snap, err)
			}
			doc, before, err := s.loadDeviceRegistrations()
			if err != nil || strings.Contains(before, "client_kind") {
				t.Fatal("read-only hint persisted", err)
			}
			// A retry from a different connection must not rewrite the first request.
			s.LoginDevice("owner", testPassword, "192.0.2.99", true, leaf)
			_, after, _ := s.loadDeviceRegistrations()
			if before != after {
				t.Fatal("retry rewrote first request")
			}
			// Existing records have no IP. Reading them derives type without a migration.
			doc.Items[0].RequestIP = ""
			raw, _ := json.Marshal(doc)
			if _, err = s.db.Exec("UPDATE security_settings SET value=? WHERE key=?", string(raw), deviceRegistrationsKey); err != nil {
				t.Fatal(err)
			}
			snap, err = s.DeviceRegistrations(s.Actor(owner))
			if err != nil || snap.Items[0].ClientKind != tc.kind || snap.Items[0].RequestIP != "" || snap.Revision != doc.Revision {
				t.Fatal("old record was not preserved", snap, err)
			}
			_, after, _ = s.loadDeviceRegistrations()
			if after != string(raw) {
				t.Fatal("read mutated stored registration")
			}
			snap, err = s.ApproveLoginDevice(s.Actor(owner), snap.Revision, snap.Items[0].ID)
			if err != nil || snap.Items[0].ClientKind != tc.kind {
				t.Fatal("approval lost source", err)
			}
			if _, err = s.VerifyDeviceCertificate(leaf); err != nil {
				t.Fatal("exact certificate approval changed", err)
			}
		})
	}
}

func TestDeviceSourceManualAndInvalidIP(t *testing.T) {
	s, _ := fixture(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	_, leaf := certificateTestLeaf(t, key, nil)
	s.LoginDevice("owner", testPassword, "not-an-ip", true, leaf)
	doc, _, err := s.loadDeviceRegistrations()
	if err != nil || len(doc.Items) != 1 || doc.Items[0].RequestIP != "" {
		t.Fatal(doc, err)
	}
	item := doc.Items[0]
	item.LoginLeafPEM = ""
	if registrationClientKind(item) != "manual" {
		t.Fatal("manual record classified as device login")
	}
	item.RequestIP = "192.0.2.1\nspoof"
	if validRegistration(item) {
		t.Fatal("invalid persisted IP accepted")
	}
}

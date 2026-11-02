package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestDeviceFirstLoginPendingSingleApprovalAndRevoke(t *testing.T) {
	s, owner := fixture(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	_, leaf := certificateTestLeaf(t, key, nil)
	if err := s.VerifyDeviceBootstrap(leaf); err != nil {
		t.Fatal(err)
	}
	if _, _, token, err := s.LoginDevice("owner", "incorrect", "phone", true, leaf); err == nil || token != "" {
		t.Fatal("wrong password enrolled")
	}
	doc, _ := s.DeviceRegistrations(s.Actor(owner))
	if len(doc.Items) != 0 {
		t.Fatal("unverified account created request")
	}
	for i := 0; i < 2; i++ {
		_, _, token, err := s.LoginDevice("owner", testPassword, "phone", true, leaf)
		if !errors.Is(err, ErrDeviceApprovalPending) || token != "" {
			t.Fatal("pending login issued session", err)
		}
	}
	doc, err := s.DeviceRegistrations(s.Actor(owner))
	if err != nil || len(doc.Items) != 1 || doc.Revision != 1 || doc.Items[0].State != "pending" {
		t.Fatal(doc, err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("pending grants data access")
	}
	other, err := s.Change(s.Actor(owner), "", Change{Username: "other", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = s.LoginDevice(other.Username, testPassword, "other", true, leaf); !errors.Is(err, ErrLogin) {
		t.Fatal("request transferred owner", err)
	}
	if _, err = s.ApproveLoginDevice(s.Actor(other), doc.Revision, doc.Items[0].ID); err == nil {
		t.Fatal("viewer approved")
	}
	if _, err = s.ApproveLoginDevice(s.Actor(owner), 0, doc.Items[0].ID); !errors.Is(err, ErrDeviceRegistrationConflict) {
		t.Fatal(err)
	}
	doc, err = s.ApproveLoginDevice(s.Actor(owner), doc.Revision, doc.Items[0].ID)
	if err != nil || doc.Items[0].State != "approved" {
		t.Fatal(doc, err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err != nil {
		t.Fatal("one approval did not approve certificate", err)
	}
	_, _, token, err := s.LoginDevice("owner", testPassword, "phone", true, leaf)
	if err != nil || token == "" {
		t.Fatal(err)
	}
	if _, _, err = s.ResolveDevice(token, false, leaf); err != nil {
		t.Fatal(err)
	}
	if _, err = s.DisableDeviceRegistration(s.Actor(owner), doc.Revision, doc.Items[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.ResolveDevice(token, false, leaf); err == nil {
		t.Fatal("revoked session alive")
	}
	if s.VerifyDeviceBootstrap(leaf) == nil {
		t.Fatal("disabled device became first login")
	}
}

func TestDeviceApprovalRollsBackAndBootstrapDoesNotReplaceRegisteredLeaf(t *testing.T) {
	s, owner := fixture(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	_, leaf := certificateTestLeaf(t, key, nil)
	s.LoginDevice("owner", testPassword, "phone", true, leaf)
	doc, _ := s.DeviceRegistrations(s.Actor(owner))
	_, different := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.SerialNumber.SetInt64(2) })
	if s.VerifyDeviceBootstrap(different) == nil {
		t.Fatal("different leaf replaced pending leaf")
	}
	if _, err := s.db.Exec("INSERT INTO security_settings(key,value) VALUES(?,?)", deviceCertificatesKey, "corrupt"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ApproveLoginDevice(s.Actor(owner), doc.Revision, doc.Items[0].ID); err == nil {
		t.Fatal("corrupt cert store accepted")
	}
	after, err := s.DeviceRegistrations(s.Actor(owner))
	if err != nil || after.Revision != doc.Revision || after.Items[0].State != "pending" {
		t.Fatal("partial approval committed", after, err)
	}
}

package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"math/big"
	"strings"
	"testing"
	"time"
)

func certificateTestLeaf(t *testing.T, key *ecdsa.PrivateKey, edit func(*x509.Certificate)) (string, *x509.Certificate) {
	t.Helper()
	now := time.Now().UTC()
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: now.Add(-time.Hour), NotAfter: now.Add(2 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, BasicConstraintsValid: true}
	if edit != nil {
		edit(template)
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(raw)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})), leaf
}
func certificateFixture(t *testing.T) (*Service, User, DeviceRegistrationSnapshot, string, *x509.Certificate) {
	t.Helper()
	s, u := fixture(t)
	csr, key := registrationTestCSR(t, elliptic.P256())
	a := s.Actor(u)
	d, err := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
	if err != nil {
		t.Fatal(err)
	}
	d, err = s.ApproveDeviceRegistration(a, d.Revision, d.Items[0].ID, time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	raw, leaf := certificateTestLeaf(t, key, nil)
	return s, u, d, raw, leaf
}
func TestDeviceCertificateGenerationLifecycle(t *testing.T) {
	s, u, d, raw, leaf := certificateFixture(t)
	a := s.Actor(u)
	id := d.Items[0].ID
	expiry := time.Now().Add(time.Hour)
	empty, err := s.DeviceCertificates(a)
	if err != nil || empty.Revision != 0 || len(empty.Items) != 0 {
		t.Fatal(empty, err)
	}
	var count int
	s.db.QueryRow("SELECT count(*) FROM security_settings WHERE key=?", deviceCertificatesKey).Scan(&count)
	if count != 0 {
		t.Fatal("read persisted defaults")
	}
	doc, err := s.ApproveDeviceCertificate(a, 0, id, raw, expiry)
	if err != nil {
		t.Fatal(err)
	}
	if doc.GrantsAccess || doc.MobileTransportReady || doc.Revision != 1 || len(doc.Items[0].ApprovalID) != 32 {
		t.Fatal(doc)
	}
	first := doc.Items[0].ApprovalID
	verified, err := s.VerifyDeviceCertificate(leaf)
	if err != nil || verified.ApprovalID != first {
		t.Fatal(verified, err)
	}
	if _, err = s.ApproveDeviceCertificate(a, 0, id, raw, expiry); !errors.Is(err, ErrDeviceCertificateConflict) {
		t.Fatal(err)
	}
	doc, err = s.RevokeDeviceCertificate(a, doc.Revision, id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("revoked accepted")
	}
	doc, err = s.ApproveDeviceCertificate(a, doc.Revision, id, raw, expiry)
	if err != nil || doc.Items[0].ApprovalID == first {
		t.Fatal(doc, err)
	}
	second := doc.Items[0].ApprovalID
	d, err = s.ApproveDeviceRegistration(a, d.Revision, id, time.Now().Add(30*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	d, err = s.ApproveDeviceRegistration(a, d.Revision, id, time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("expiry shrink/extend resurrected approval")
	}
	doc, err = s.DeviceCertificates(a)
	if err != nil || doc.Items[0].RevokedAt == nil {
		t.Fatal(doc, err)
	}
	doc, err = s.ApproveDeviceCertificate(a, doc.Revision, id, raw, expiry)
	if err != nil || doc.Items[0].ApprovalID == second {
		t.Fatal(doc, err)
	}
	if _, err = s.DisableDeviceRegistration(a, d.Revision, id); err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("disabled registration accepted")
	}
	if _, err = s.RevokeDeviceCertificate(a, doc.Revision, id); err != nil {
		t.Fatal("revocation depends on valid registration", err)
	}
}

func TestLongLivedCertificateExplicitExpiryAndRevocation(t *testing.T) {
	s, u := fixture(t)
	actor := s.Actor(u)
	csr, key := registrationTestCSR(t, elliptic.P256())
	d, err := s.CreateDeviceRegistration(actor, 0, u.ID, "long-lived phone", csr)
	if err != nil {
		t.Fatal(err)
	}
	id := d.Items[0].ID
	d, err = s.ApproveDeviceRegistration(actor, d.Revision, id, time.Now().AddDate(101, 0, 0))
	if err != nil {
		t.Fatal(err)
	}
	raw, leaf := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.NotAfter = time.Now().AddDate(100, 0, 0) })
	doc, err := s.ApproveDeviceCertificateForLeaf(actor, 0, id, raw)
	if err != nil || !doc.Items[0].ExpiresAt.Equal(leaf.NotAfter) {
		t.Fatal(doc, err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RevokeDeviceCertificate(actor, doc.Revision, id); err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("long-lived revoked leaf accepted")
	}
	short := time.Now().Add(time.Hour)
	doc, err = s.ApproveDeviceCertificate(actor, doc.Revision+1, id, raw, short)
	if err != nil || !doc.Items[0].ExpiresAt.Equal(short) {
		t.Fatal(doc, err)
	}
}
func TestDeviceCertificateValidation(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	csr, registeredKey := registrationTestCSR(t, elliptic.P256())
	d, err := s.CreateDeviceRegistration(a, 0, u.ID, "Synthetic", csr)
	if err != nil {
		t.Fatal(err)
	}
	d, err = s.ApproveDeviceRegistration(a, d.Revision, d.Items[0].ID, time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	raw, leaf := certificateTestLeaf(t, registeredKey, nil)
	id := d.Items[0].ID
	expiry := time.Now().Add(time.Hour)
	_, wrongKey := registrationTestCSR(t, elliptic.P256())
	wrong, _ := certificateTestLeaf(t, wrongKey, nil)
	for name, input := range map[string]string{"private": "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----", "multiple": raw + raw, "trailing": raw + "secret", "prefix": "junk" + raw, "oversize": strings.Repeat("x", 16385), "wrongkey": wrong} {
		t.Run(name, func(t *testing.T) {
			if _, err := s.ApproveDeviceCertificate(a, 0, id, input, expiry); !errors.Is(err, ErrDeviceCertificateInvalid) {
				t.Fatal(err)
			}
		})
	}
	for name, edit := range map[string]func(*x509.Certificate){"ca": func(c *x509.Certificate) { c.IsCA = true }, "noeku": func(c *x509.Certificate) { c.ExtKeyUsage = nil }, "anyeku": func(c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageAny} }, "no-sign": func(c *x509.Certificate) { c.KeyUsage = x509.KeyUsageKeyEncipherment }, "future": func(c *x509.Certificate) { c.NotBefore = time.Now().Add(time.Hour) }, "expired": func(c *x509.Certificate) { c.NotAfter = time.Now().Add(-time.Minute) }} {
		t.Run(name, func(t *testing.T) {
			bad, _ := certificateTestLeaf(t, registeredKey, edit)
			if _, err := s.ApproveDeviceCertificate(a, 0, id, bad, expiry); !errors.Is(err, ErrDeviceCertificateInvalid) {
				t.Fatal(err)
			}
			if name != "future" && name != "expired" {
				if _, _, _, err := certificateLeaf(bad); err == nil {
					t.Fatal("invalid profile accepted")
				}
			}
		})
	}
	for _, end := range []time.Time{time.Now().Add(-time.Second), time.Now().Add(5 * time.Hour)} {
		if _, err := s.ApproveDeviceCertificate(a, 0, id, raw, end); !errors.Is(err, ErrDeviceCertificateInvalid) {
			t.Fatal(err)
		}
	}
	doc, err := s.ApproveDeviceCertificate(a, 0, id, raw, expiry)
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return expiry }
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("expiry accepted")
	}
	s.now = time.Now
	if _, err = s.db.Exec("UPDATE users SET disabled=1 WHERE id=?", u.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(leaf); err == nil {
		t.Fatal("disabled owner accepted")
	}
	if doc.Items[0].OwnerUserID != u.ID {
		t.Fatal("owner changed")
	}
}
func TestDeviceCertificateAtomicReapprovalAndCorruption(t *testing.T) {
	s, u, d, raw, leaf := certificateFixture(t)
	a := s.Actor(u)
	id := d.Items[0].ID
	doc, err := s.ApproveDeviceCertificate(a, 0, id, raw, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	var before string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&before)
	if _, err = s.db.Exec("CREATE TRIGGER reject_cert BEFORE UPDATE ON security_settings WHEN NEW.key='public_device_certificates_v1' BEGIN SELECT RAISE(ABORT,'synthetic'); END"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ApproveDeviceRegistration(a, d.Revision, id, time.Now().Add(2*time.Hour)); err == nil {
		t.Fatal("failed hook reported success")
	}
	var after string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&after)
	if before != after {
		t.Fatal("registration escaped rollback")
	}
	if v, err := s.VerifyDeviceCertificate(leaf); err != nil || v.ApprovalID != doc.Items[0].ApprovalID {
		t.Fatal(v, err)
	}
	s.db.Exec("DROP TRIGGER reject_cert")
	s.db.Exec("UPDATE security_settings SET value=? WHERE key=?", "{broken", deviceCertificatesKey)
	if _, err = s.DeviceCertificates(a); !errors.Is(err, ErrDeviceCertificateUnavailable) {
		t.Fatal(err)
	}
	if _, err = s.ApproveDeviceCertificate(a, 0, id, raw, time.Now().Add(time.Hour)); !errors.Is(err, ErrDeviceCertificateUnavailable) {
		t.Fatal(err)
	}
	if _, err = s.ApproveDeviceRegistration(a, d.Revision, id, time.Now().Add(2*time.Hour)); err == nil {
		t.Fatal("bad cert doc treated as empty")
	}
	if _, err = s.DisableDeviceRegistration(a, d.Revision, id); err != nil {
		t.Fatal("corruption blocks emergency disable", err)
	}
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey).Scan(&after)
	if after != "{broken" {
		t.Fatal("corruption overwritten")
	}
}
func TestDeviceCertificateAuditFailureAndUnavailable(t *testing.T) {
	s, u, d, raw, leaf := certificateFixture(t)
	a := s.Actor(u)
	if _, err := s.db.Exec("CREATE TRIGGER reject_cert_audit BEFORE INSERT ON audit WHEN NEW.action='device_certificate.approve' BEGIN SELECT RAISE(ABORT,'synthetic'); END"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ApproveDeviceCertificate(a, 0, d.Items[0].ID, raw, time.Now().Add(time.Hour)); err == nil {
		t.Fatal("audit failure ignored")
	}
	doc, err := s.DeviceCertificates(a)
	if err != nil || doc.Revision != 0 {
		t.Fatal(doc, err)
	}
	s.db.Close()
	if _, err = s.VerifyDeviceCertificate(leaf); !errors.Is(err, ErrDeviceCertificateUnavailable) {
		t.Fatal(err)
	}
}

func TestDeviceCertificateStaleRegistrationGuard(t *testing.T) {
	s, u, d, _, _ := certificateFixture(t)
	_, stale, err := s.loadDeviceRegistrations()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.ApproveDeviceRegistration(s.Actor(u), d.Revision, d.Items[0].ID, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	_, current, err := s.loadDeviceRegistrations()
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		raw      string
		conflict bool
	}{{stale, true}, {current, false}} {
		tx, err := s.db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		err = guardCertificateRegistrationTx(tx, test.raw)
		tx.Rollback()
		if test.conflict && !errors.Is(err, ErrDeviceCertificateConflict) || !test.conflict && err != nil {
			t.Fatal(err)
		}
	}
}
func TestDeviceCertificateReplaceReopenPreservesOtherSettings(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { s.Close() }()
	u, err := s.Bootstrap("owner", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	a := s.Actor(u)
	csr, key := registrationTestCSR(t, elliptic.P256())
	d, err := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
	if err != nil {
		t.Fatal(err)
	}
	id := d.Items[0].ID
	d, err = s.ApproveDeviceRegistration(a, d.Revision, id, time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	tooLong, _ := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.NotAfter = time.Now().Add(4 * time.Hour) })
	if _, err = s.ApproveDeviceCertificate(a, 0, id, tooLong, time.Now().Add(time.Hour)); !errors.Is(err, ErrDeviceCertificateInvalid) {
		t.Fatal("leaf exceeds registration window", err)
	}
	raw, old := certificateTestLeaf(t, key, nil)
	doc, err := s.ApproveDeviceCertificate(a, 0, id, raw, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	raw, current := certificateTestLeaf(t, key, func(c *x509.Certificate) { c.SerialNumber = big.NewInt(2) })
	doc, err = s.ApproveDeviceCertificate(a, doc.Revision, id, raw, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.VerifyDeviceCertificate(old); err == nil {
		t.Fatal("replaced leaf accepted")
	}
	if _, err = s.db.Exec("INSERT INTO security_settings(key,value) VALUES('synthetic_other','preserve')"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.VerifyDeviceCertificate(current)
	if err != nil || got.ApprovalID != doc.Items[0].ApprovalID {
		t.Fatal(got, err)
	}
	var other string
	if err = s.db.QueryRow("SELECT value FROM security_settings WHERE key='synthetic_other'").Scan(&other); err != nil || other != "preserve" {
		t.Fatal(other, err)
	}
}

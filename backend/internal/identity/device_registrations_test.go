package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func registrationTestCSR(t *testing.T, curve elliptic.Curve) (string, *ecdsa.PrivateKey) {
	t.Helper()
	key, e := ecdsa.GenerateKey(curve, rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	der, e := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{Subject: pkix.Name{CommonName: "untrusted-subject-do-not-store"}}, key)
	if e != nil {
		t.Fatal(e)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der})), key
}
func TestDeviceRegistrationLifecycleAndNoAccess(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	csr, _ := registrationTestCSR(t, elliptic.P256())
	first, e := s.DeviceRegistrations(a)
	if e != nil || first.Revision != 0 || len(first.Items) != 0 {
		t.Fatal(first, e)
	}
	var rows int
	s.db.QueryRow("SELECT count(*) FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&rows)
	if rows != 0 {
		t.Fatal("read wrote default")
	}
	p, e := s.CreateDeviceRegistration(a, 0, u.ID, "Synthetic phone", csr)
	if e != nil {
		t.Fatal(e)
	}
	id := p.Items[0].ID
	if p.Revision != 1 || p.Items[0].State != "pending" || p.Items[0].OwnerStatus != "active" || p.GrantsAccess || p.MobileTransportReady {
		t.Fatal(p)
	}
	var raw string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&raw)
	if strings.Contains(raw, "CERTIFICATE REQUEST") || strings.Contains(raw, "untrusted-subject") || strings.Contains(raw, "owner_status") {
		t.Fatal("stored input claims/derived data")
	}
	p, e = s.ApproveDeviceRegistration(a, 1, id, time.Now().Add(time.Hour))
	if e != nil {
		t.Fatal(e)
	}
	if p.Revision != 2 || p.Items[0].State != "approved" || p.Items[0].ApprovedBy != u.ID || p.GrantsAccess || p.MobileTransportReady {
		t.Fatal(p)
	}
	p, e = s.ApproveDeviceRegistration(a, 2, id, time.Now().Add(2*time.Hour))
	if e != nil {
		t.Fatal(e)
	}
	if p.Revision != 3 {
		t.Fatal(p)
	}
	p, e = s.DisableDeviceRegistration(a, 3, id)
	if e != nil || p.Items[0].State != "disabled" || p.Items[0].DisabledAt == nil {
		t.Fatal(p, e)
	}
	if _, e = s.ApproveDeviceRegistration(a, 4, id, time.Now().Add(time.Hour)); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	if _, e = s.CreateDeviceRegistration(a, 4, u.ID, "duplicate", csr); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	if _, e = s.DisableDeviceRegistration(a, 4, id); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
}
func TestDeviceRegistrationRejectsMalformedCSRAndOwner(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	csr, key := registrationTestCSR(t, elliptic.P256())
	p384, _ := registrationTestCSR(t, elliptic.P384())
	block, _ := pem.Decode([]byte(csr))
	block.Bytes[len(block.Bytes)-1] ^= 1
	badSignature := string(pem.EncodeToMemory(block))
	private, _ := x509.MarshalPKCS8PrivateKey(key)
	for _, bad := range []string{badSignature, csr + csr, "prefix" + csr, csr + "trailing", strings.Repeat("x", 8193), p384, string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}))} {
		if _, e := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", bad); !errors.Is(e, ErrDeviceRegistrationInvalid) {
			t.Fatal("bad CSR accepted or unsafe error", e)
		}
	}
	for _, label := range []string{"", strings.Repeat("x", 129), "secret\nlabel"} {
		if _, e := s.CreateDeviceRegistration(a, 0, u.ID, label, csr); !errors.Is(e, ErrDeviceRegistrationInvalid) {
			t.Fatal(e)
		}
	}
	if _, e := s.CreateDeviceRegistration(a, 0, "missing-owner", "synthetic", csr); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	if _, e := s.CreateDeviceRegistration(authorization.Actor{}, 0, u.ID, "synthetic", csr); !errors.Is(e, ErrDenied) {
		t.Fatal(e)
	}
	p, e := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
	if e != nil {
		t.Fatal(e)
	}
	for _, expiry := range []time.Time{{}, time.Now().Add(-time.Second)} {
		if _, e = s.ApproveDeviceRegistration(a, 1, p.Items[0].ID, expiry); !errors.Is(e, ErrDeviceRegistrationInvalid) {
			t.Fatal(e)
		}
	}
	if _, e = s.ApproveDeviceRegistration(a, 1, "missing", time.Now().Add(time.Hour)); !errors.Is(e, ErrDeviceRegistrationNotFound) {
		t.Fatal(e)
	}
}
func TestDeviceRegistrationOwnerDisableAndDeletedAnnotations(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	owner, e := s.Change(a, "", Change{Username: "registration-owner", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if e != nil {
		t.Fatal(e)
	}
	csr, _ := registrationTestCSR(t, elliptic.P256())
	p, e := s.CreateDeviceRegistration(a, 0, owner.ID, "synthetic", csr)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Change(a, owner.ID, Change{Username: owner.Username, Version: owner.Version, Disabled: true, Grants: owner.Grants}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.ApproveDeviceRegistration(a, 1, p.Items[0].ID, time.Now().Add(time.Hour)); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	if _, e = s.CreateDeviceRegistration(a, 1, owner.ID, "synthetic", csr); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	snapshot, e := s.DeviceRegistrations(a)
	if e != nil || snapshot.Items[0].OwnerStatus != "disabled" {
		t.Fatal(snapshot, e)
	}
	if _, e = s.db.Exec("DELETE FROM users WHERE id=?", owner.ID); e != nil {
		t.Fatal(e)
	}
	snapshot, e = s.DeviceRegistrations(a)
	if e != nil || snapshot.Items[0].OwnerStatus != "missing" || snapshot.GrantsAccess {
		t.Fatal(snapshot, e)
	}
	if _, e = s.DisableDeviceRegistration(a, 1, p.Items[0].ID); e != nil {
		t.Fatal(e)
	}
}
func TestDeviceRegistrationConcurrentCASAndAuditRollback(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	csr, _ := registrationTestCSR(t, elliptic.P256())
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
			results <- e
		}()
	}
	wg.Wait()
	close(results)
	success, conflict := 0, 0
	for e := range results {
		if e == nil {
			success++
		} else if errors.Is(e, ErrDeviceRegistrationConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal(success, conflict)
	}
	p, e := s.DeviceRegistrations(a)
	if e != nil {
		t.Fatal(e)
	}
	var before string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&before)
	if _, e = s.db.Exec("CREATE TRIGGER reject_registration_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'synthetic private detail'); END"); e != nil {
		t.Fatal(e)
	}
	if _, e = s.ApproveDeviceRegistration(a, 1, p.Items[0].ID, time.Now().Add(time.Hour)); !errors.Is(e, ErrDeviceRegistrationUnavailable) {
		t.Fatal(e)
	}
	var after string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&after)
	if before != after {
		t.Fatal("failed audit committed registration")
	}
	p, e = s.DeviceRegistrations(a)
	if e != nil || p.Revision != 1 || p.Items[0].State != "pending" {
		t.Fatal(p, e)
	}
}
func TestDeviceRegistrationReopenAndCorruptAuthoritativeData(t *testing.T) {
	dir := t.TempDir()
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	u, e := s.Bootstrap("owner", testPassword)
	if e != nil {
		t.Fatal(e)
	}
	a := s.Actor(u)
	s.db.Exec("INSERT INTO security_settings(key,value) VALUES('unrelated','keep old bytes')")
	csr, _ := registrationTestCSR(t, elliptic.P256())
	p, e := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
	if e != nil {
		t.Fatal(e)
	}
	s.Close()
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	a = s.Actor(u)
	reopened, e := s.DeviceRegistrations(a)
	if e != nil || reopened.Revision != 1 || reopened.Items[0].ID != p.Items[0].ID {
		t.Fatal(reopened, e)
	}
	for _, raw := range []string{`{`, `{"schema":2,"revision":1,"items":[]}`, `{"schema":1,"revision":1,"items":[],"grants_access":true}`} {
		s.db.Exec("UPDATE security_settings SET value=? WHERE key=?", raw, deviceRegistrationsKey)
		if _, e = s.DeviceRegistrations(a); !errors.Is(e, ErrDeviceRegistrationUnavailable) {
			t.Fatal(e)
		}
		if _, e = s.CreateDeviceRegistration(a, 1, u.ID, "repair", csr); !errors.Is(e, ErrDeviceRegistrationUnavailable) {
			t.Fatal(e)
		}
		var after string
		s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&after)
		if after != raw {
			t.Fatal("corrupt data overwritten")
		}
	}
	var old string
	s.db.QueryRow("SELECT value FROM security_settings WHERE key='unrelated'").Scan(&old)
	if old != "keep old bytes" {
		t.Fatal("old settings changed")
	}
	// A trusted actor fixture isolates DB unavailability from session revocation.
	trusted := a
	trusted.Valid = func() bool { return true }
	s.Close()
	if _, e = s.DeviceRegistrations(trusted); !errors.Is(e, ErrDeviceRegistrationUnavailable) {
		t.Fatal(e)
	}
}

func TestDeviceRegistrationSessionBoundActorDoesNotDeadlock(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	_, _, token, e := s.Login(u.Username, testPassword, "synthetic", false)
	if e != nil {
		t.Fatal(e)
	}
	a.Valid = func() bool { _, _, err := s.Resolve(token, false); return err == nil }
	csr, _ := registrationTestCSR(t, elliptic.P256())
	done := make(chan error, 1)
	go func() {
		p, err := s.CreateDeviceRegistration(a, 0, u.ID, "synthetic", csr)
		if err == nil {
			_, err = s.ApproveDeviceRegistration(a, p.Revision, p.Items[0].ID, time.Now().Add(time.Hour))
		}
		if err == nil {
			_, err = s.DeviceRegistrations(a)
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("session-bound actor deadlocked")
	}
}

func TestDeviceRegistrationCapacityAndStoredKeyIntegrity(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	now := time.Now().UTC()
	doc := deviceRegistrationDocument{Schema: 1, Revision: 1, Items: []DeviceRegistration{}}
	for i := 0; i < 256; i++ {
		csr, _ := registrationTestCSR(t, elliptic.P256())
		key, digest, e := registrationCSR(csr)
		if e != nil {
			t.Fatal(e)
		}
		doc.Items = append(doc.Items, DeviceRegistration{ID: randomID(), OwnerUserID: u.ID, Label: "synthetic", PublicKeyPEM: key, SPKISHA256: digest, State: "pending", CreatedAt: now})
	}
	raw, _ := json.Marshal(doc)
	if _, e := s.db.Exec("INSERT INTO security_settings(key,value) VALUES(?,?)", deviceRegistrationsKey, string(raw)); e != nil {
		t.Fatal(e)
	}
	if p, e := s.DeviceRegistrations(a); e != nil || len(p.Items) != 256 {
		t.Fatal(e)
	}
	csr, _ := registrationTestCSR(t, elliptic.P256())
	if _, e := s.CreateDeviceRegistration(a, 1, u.ID, "over limit", csr); !errors.Is(e, ErrDeviceRegistrationInvalid) {
		t.Fatal(e)
	}
	doc.Items[0].SPKISHA256 = strings.Repeat("0", 64)
	raw, _ = json.Marshal(doc)
	s.db.Exec("UPDATE security_settings SET value=? WHERE key=?", string(raw), deviceRegistrationsKey)
	if _, e := s.DeviceRegistrations(a); !errors.Is(e, ErrDeviceRegistrationUnavailable) {
		t.Fatal("stored fingerprint corruption accepted", e)
	}
}

package networkaccess

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func fixture(t *testing.T) *Service {
	t.Helper()
	s := New(t.TempDir(), "https://203.0.113.10:9090", true, "")
	s.addresses = func() ([]Address, error) { return []Address{{"192.168.50.5", "test NIC"}}, nil }
	return s
}
func TestLANConfigurationCertificatePersistenceAndRevision(t *testing.T) {
	s := fixture(t)
	v, e := s.Snapshot()
	if e != nil || v.Enabled || v.Address != "192.168.50.5" || v.Port != 18443 {
		t.Fatal(v, e)
	}
	if _, e = os.Stat(filepath.Join(s.dir, "lan-access.json")); !os.IsNotExist(e) {
		t.Fatal("read created config", e)
	}
	v, e = s.Save(Input{0, true, "192.168.50.5", 18443})
	if e != nil || !v.RestartRequired || v.Running || v.Fingerprint == "" {
		t.Fatal(v, e)
	}
	cfg, config, e := s.Deployment()
	if e != nil || config == nil {
		t.Fatal(e)
	}
	if _, e = s.Save(Input{0, false, "192.168.50.5", 18443}); !errors.Is(e, ErrConflict) {
		t.Fatal("stale update", e)
	}
	certificate, e := x509.ParseCertificate(config.Certificates[0].Certificate[0])
	if e != nil {
		t.Fatal(e)
	}
	if certificate.NotAfter.Before(time.Now().AddDate(9, 0, 0)) || certificate.VerifyHostname("192.168.50.5") != nil {
		t.Fatal("bad lifetime or SAN")
	}
	// Real TLS handshake verifies the generated certificate using its IP SAN.
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	server.TLS = config
	server.StartTLS()
	defer server.Close()
	pool := x509.NewCertPool()
	pool.AddCert(certificate)
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, ServerName: "192.168.50.5", MinVersion: tls.VersionTLS12}}, Timeout: time.Second * 5}
	response, e := client.Get(server.URL)
	if e != nil {
		t.Fatal(e)
	}
	response.Body.Close()
	if response.StatusCode != 204 {
		t.Fatal(response.StatusCode)
	}
	s.SetRunning(cfg, true, "")
	v, e = s.Snapshot()
	if e != nil || v.RestartRequired || !v.Running {
		t.Fatal(v, e)
	}
	oldFingerprint := v.Fingerprint
	v, e = s.Save(Input{v.Revision, true, "192.168.50.5", 18444})
	if e != nil || v.Fingerprint != oldFingerprint || !v.RestartRequired {
		t.Fatal("port change rotated certificate", v, e)
	}
	raw, _ := json.Marshal(v)
	if bytes.Contains(raw, []byte("PRIVATE KEY")) || bytes.Contains(raw, []byte("private_key")) {
		t.Fatal("private key leaked")
	}
	reopened := New(s.dir, s.publicOrigin, true, "")
	reopened.addresses = s.addresses
	next, _, e := reopened.Deployment()
	if e != nil || next.Port != 18444 {
		t.Fatal(next, e)
	}
}
func TestLANInvalidAndFailedSavePreserveConfiguration(t *testing.T) {
	s := fixture(t)
	for _, address := range []string{"0.0.0.0", "127.0.0.1", "8.8.8.8", "198.18.0.1", "::1", "192.168.99.99"} {
		if _, e := s.Save(Input{0, true, address, 18443}); !errors.Is(e, ErrInvalid) {
			t.Fatal(address, e)
		}
	}
	v, e := s.Save(Input{0, false, "192.168.50.5", 18443})
	if e != nil {
		t.Fatal(e)
	}
	if v.CertificatePEM != "" {
		t.Fatal("disabled config generated certificate")
	}
	// A directory blocks the atomic replacement, proving failure cannot report a save.
	path := filepath.Join(s.dir, "lan-access.json")
	raw, e := os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.Remove(path); e != nil {
		t.Fatal(e)
	}
	if e = os.Mkdir(path, 0700); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Save(Input{1, false, "192.168.50.5", 18444}); e == nil {
		t.Fatal("accepted unavailable storage")
	}
	if e = os.Remove(path); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(path, raw, 0600); e != nil {
		t.Fatal(e)
	}
	v, e = s.Snapshot()
	if e != nil || v.Port != 18443 || v.Revision != 1 {
		t.Fatal(v, e)
	}
}

func TestLANPrivateKeyCannotBeGeneratedUnderWebRoot(t *testing.T) {
	s := fixture(t)
	s.webRoot = s.dir
	if _, err := s.Save(Input{0, true, "192.168.50.5", 18443}); err == nil {
		t.Fatal("generated private material inside served directory")
	}
	files, err := os.ReadDir(filepath.Join(s.dir, "lan-certificates"))
	if err != nil || len(files) != 0 {
		t.Fatal("private material was written", files, err)
	}
	if _, err := os.Stat(filepath.Join(s.dir, "lan-access.json")); !os.IsNotExist(err) {
		t.Fatal("failed configuration persisted", err)
	}
}

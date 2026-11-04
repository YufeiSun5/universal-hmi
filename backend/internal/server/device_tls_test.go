package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func deviceTLSFixture(t *testing.T) (*identity.Service, identity.User, identity.DeviceCertificateSnapshot, tls.Certificate) {
	t.Helper()
	s, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	u, err := s.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{}, key)
	if err != nil {
		t.Fatal(err)
	}
	registrations, err := s.CreateDeviceRegistration(s.Actor(u), 0, u.ID, "TLS test installation", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csr})))
	if err != nil {
		t.Fatal(err)
	}
	registrations, err = s.ApproveDeviceRegistration(s.Actor(u), registrations.Revision, registrations.Items[0].ID, time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(2 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, BasicConstraintsValid: true}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(raw)
	if err != nil {
		t.Fatal(err)
	}
	doc, err := s.ApproveDeviceCertificate(s.Actor(u), 0, registrations.Items[0].ID, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})), time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return s, u, doc, tls.Certificate{Certificate: [][]byte{raw}, PrivateKey: key, Leaf: leaf}
}

func TestDeviceTLSFullResumedAndLiveRevocation(t *testing.T) {
	for _, version := range []uint16{tls.VersionTLS12, tls.VersionTLS13} {
		t.Run(tls.VersionName(version), func(t *testing.T) {
			s, owner, doc, certificate := deviceTLSFixture(t)
			h, err := PublicAccessHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if publicDeviceLeaf(r) == nil || !publicIPAccessValid(r) {
					t.Error("missing proven device binding")
				}
				w.WriteHeader(204)
			}), PublicAccessOptions{Device: s.VerifyDeviceCertificate})
			if err != nil {
				t.Fatal(err)
			}
			ts := httptest.NewUnstartedServer(h)
			ts.Config.ErrorLog = log.New(io.Discard, "", 0)
			ts.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: version, MaxVersion: version}, s)
			if err != nil {
				t.Fatal(err)
			}
			ts.StartTLS()
			defer ts.Close()
			pool := x509.NewCertPool()
			pool.AddCert(ts.Certificate())
			config := &tls.Config{MinVersion: version, MaxVersion: version, RootCAs: pool, Certificates: []tls.Certificate{certificate}, ClientSessionCache: tls.NewLRUClientSessionCache(8)}
			transport := &http.Transport{TLSClientConfig: config, DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
			for i := 0; i < 2; i++ {
				resp, err := client.Get(ts.URL + "/api/v1/points")
				if err != nil {
					t.Fatal(err)
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if resp.StatusCode != 204 || resp.TLS.DidResume != (i == 1) {
					t.Fatalf("status=%d resumed=%t request=%d", resp.StatusCode, resp.TLS.DidResume, i)
				}
			}
			// Even approved devices cannot reach a control route.
			resp, err := client.Post(ts.URL+"/api/v1/write", "application/json", nil)
			if err != nil {
				t.Fatal(err)
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode != 403 {
				t.Fatal("write reached downstream", resp.StatusCode)
			}
			if _, err = s.RevokeDeviceCertificate(s.Actor(owner), doc.Revision, doc.Items[0].RegistrationID); err != nil {
				t.Fatal(err)
			}
			if resp, err = client.Get(ts.URL + "/health"); err == nil {
				resp.Body.Close()
				t.Fatal("revoked resumed TLS certificate accepted")
			}
			// No certificate or a fake header cannot select the device channel.
			web := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}, DisableKeepAlives: true}
			defer web.CloseIdleConnections()
			req, _ := http.NewRequest("GET", ts.URL+"/health", nil)
			req.Header.Set("X-Device-ID", doc.Items[0].RegistrationID)
			req.Header.Set("X-Client-Channel", "android")
			resp, err = (&http.Client{Transport: web, Timeout: 5 * time.Second}).Do(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			if resp.StatusCode != 403 {
				t.Fatal("header bypassed IP policy", resp.StatusCode)
			}
		})
	}
}

func TestDeviceTLSRejectsWrongPrivateKeyAndDifferentLeaf(t *testing.T) {
	s, _, _, certificate := deviceTLSFixture(t)
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("unapproved peer reached HTTP") }))
	ts.Config.ErrorLog = log.New(io.Discard, "", 0)
	var err error
	ts.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: tls.VersionTLS12}, s)
	if err != nil {
		t.Fatal(err)
	}
	ts.StartTLS()
	defer ts.Close()
	pool := x509.NewCertPool()
	pool.AddCert(ts.Certificate())
	wrongKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wrongPossession := certificate
	wrongPossession.PrivateKey = wrongKey
	key := certificate.PrivateKey.(*ecdsa.PrivateKey)
	template := *certificate.Leaf
	template.SerialNumber = big.NewInt(2)
	raw, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	differentLeaf := certificate
	differentLeaf.Certificate = [][]byte{raw}
	differentLeaf.Leaf, _ = x509.ParseCertificate(raw)
	for _, candidate := range []tls.Certificate{wrongPossession, differentLeaf} {
		transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{candidate}}}
		client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
		resp, err := client.Get(ts.URL + "/health")
		transport.CloseIdleConnections()
		if err == nil {
			resp.Body.Close()
			t.Fatal("unapproved certificate or key accepted")
		}
	}
}

func TestDeviceTLSRechecksExistingConnectionAndStream(t *testing.T) {
	s, owner, doc, certificate := deviceTLSFixture(t)
	var streamValid func() bool
	h, err := PublicAccessHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		streamValid = func() bool { return publicIPAccessValid(r) }
		w.WriteHeader(204)
	}), PublicAccessOptions{Device: s.VerifyDeviceCertificate})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer(h)
	ts.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: tls.VersionTLS12}, s)
	if err != nil {
		t.Fatal(err)
	}
	ts.StartTLS()
	defer ts.Close()
	pool := x509.NewCertPool()
	pool.AddCert(ts.Certificate())
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{certificate}}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	resp, err := client.Get(ts.URL + "/api/v1/points")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 204 || streamValid == nil || !streamValid() {
		t.Fatal("initial admission failed")
	}
	if _, err := s.RevokeDeviceCertificate(s.Actor(owner), doc.Revision, doc.Items[0].RegistrationID); err != nil {
		t.Fatal(err)
	}
	if streamValid() {
		t.Fatal("stream validity survived revocation")
	}
	resp, err = client.Get(ts.URL + "/api/v1/points")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatal("keepalive bypassed live revocation", resp.StatusCode)
	}
}

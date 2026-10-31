package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
)

func testRemote(t *testing.T) (remoteConfig, string) {
	t.Helper()
	dir := t.TempDir()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	leaf := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("203.0.113.5"), net.ParseIP("2001:db8::5")}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, _ := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	priv, _ := x509.MarshalPKCS8PrivateKey(key)
	os.WriteFile(filepath.Join(dir, "cert.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600)
	os.WriteFile(filepath.Join(dir, "key.pem"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: priv}), 0600)
	return remoteConfig{Schema: 2, WebAllowlist: []server.PublicIPRule{{CIDR: "192.0.2.0/24", Owner: "Synthetic test network"}}, Enabled: true, Origin: "https://203.0.113.5:18443", Listen: "127.0.0.1:0", Certificate: "cert.pem", PrivateKey: "key.pem"}, filepath.Join(dir, "remote.json")
}
func TestRemoteConfiguration(t *testing.T) {
	c, path := testRemote(t)
	save := func() {
		b, _ := json.Marshal(c)
		if e := os.WriteFile(path, b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	save()
	r, e := loadRemote(path)
	if e != nil || r.TLS == nil || r.Digest == "" {
		t.Fatalf("valid: %v", e)
	}
	for _, entry := range [][2]string{{"https://203.0.113.5:443", "https://203.0.113.5"}, {"https://[2001:db8::5]:443", "https://[2001:db8::5]"}, {"https://203.0.113.5:18443", "https://203.0.113.5:18443"}} {
		previous := c.Origin
		c.Origin = entry[0]
		save()
		normalized, e := loadRemote(path)
		if e != nil || normalized.Config.Origin != entry[1] {
			t.Fatalf("origin canonicalization %s: %s %v", entry[0], normalized.Config.Origin, e)
		}
		c.Origin = previous
	}
	for _, field := range []string{"origin", "listen", "certificate", "private_key"} {
		t.Run(field, func(t *testing.T) {
			bad := c
			switch field {
			case "origin":
				bad.Origin = ""
			case "listen":
				bad.Listen = ""
			case "certificate":
				bad.Certificate = ""
			case "private_key":
				bad.PrivateKey = ""
			}
			b, _ := json.Marshal(bad)
			os.WriteFile(path, b, 0600)
			if _, e := loadRemote(path); e == nil {
				t.Fatal("accepted missing field")
			}
		})
	}
	c.Origin = "https://203.0.113.6:18443"
	save()
	if _, e := loadRemote(path); e == nil {
		t.Fatal("IP mismatch accepted")
	}
	c.Origin = "https://203.0.113.5:18443"
	c.PrivateKey = "cert.pem"
	save()
	if _, e := loadRemote(path); e == nil {
		t.Fatal("invalid key accepted")
	}
	c = remoteConfig{Schema: 1}
	save()
	if r, e := loadRemote(path); e != nil || r.TLS != nil {
		t.Fatalf("disabled template: %v", e)
	}
}
func TestRemotePrivateKeyOutsideWeb(t *testing.T) {
	dir := t.TempDir()
	web := filepath.Join(dir, "web")
	os.Mkdir(web, 0700)
	key := filepath.Join(web, "key.pem")
	os.WriteFile(key, []byte("private"), 0600)
	if e := validateRemotePrivatePath(filepath.Join(dir, "remote.json"), "web/key.pem", web); e == nil {
		t.Fatal("private key allowed in web")
	}
	outside := filepath.Join(dir, "key.pem")
	os.WriteFile(outside, []byte("private"), 0600)
	if e := validateRemotePrivatePath(filepath.Join(dir, "remote.json"), "key.pem", web); e != nil {
		t.Fatal(e)
	}
}
func TestRemoteCertificateRenewalAndValidity(t *testing.T) {
	c, path := testRemote(t)
	raw, _ := json.Marshal(c)
	os.WriteFile(path, raw, 0600)
	first, e := loadRemote(path)
	if e != nil {
		t.Fatal(e)
	}
	certPath := filepath.Join(filepath.Dir(path), "cert.pem")
	keyBytes, _ := os.ReadFile(filepath.Join(filepath.Dir(path), "key.pem"))
	block, _ := pem.Decode(keyBytes)
	key, _ := x509.ParsePKCS8PrivateKey(block.Bytes)
	private := key.(*ecdsa.PrivateKey)
	cert := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("203.0.113.5"), net.ParseIP("2001:db8::5")}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	write := func() {
		der, e := x509.CreateCertificate(rand.Reader, cert, cert, &private.PublicKey, private)
		if e != nil {
			t.Fatal(e)
		}
		os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600)
	}
	write()
	second, e := loadRemote(path)
	if e != nil || first.Digest == second.Digest {
		t.Fatalf("renewal not detected: %v", e)
	}
	cert.NotAfter = time.Now().Add(-time.Minute)
	write()
	if _, e := loadRemote(path); e == nil {
		t.Fatal("expired certificate accepted")
	}
	cert.NotBefore = time.Now().Add(time.Hour)
	cert.NotAfter = time.Now().Add(2 * time.Hour)
	write()
	if _, e := loadRemote(path); e == nil {
		t.Fatal("future certificate accepted")
	}
}

func TestServeListenersShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ls := []net.Listener{}
	ss := []*http.Server{}
	for i := 0; i < 2; i++ {
		l, e := net.Listen("tcp", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		ls = append(ls, l)
		ss = append(ss, &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })})
	}
	done := make(chan error, 1)
	go func() { done <- serveListeners(ctx, ss, ls) }()
	for _, l := range ls {
		res, e := http.Get("http://" + l.Addr().String())
		if e != nil {
			t.Fatal(e)
		}
		res.Body.Close()
	}
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown timeout")
	}
	for _, l := range ls {
		if c, e := net.DialTimeout("tcp", l.Addr().String(), time.Second); e == nil {
			c.Close()
			t.Fatal("listener survived shutdown")
		}
	}
}

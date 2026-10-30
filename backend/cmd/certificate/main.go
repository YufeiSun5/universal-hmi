package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

func main() {
	ipText := flag.String("ip", "", "public fixed IP included in IP SAN")
	output := flag.String("out", "", "new private certificate directory (must not exist)")
	days := flag.Int("days", 365, "certificate validity in days (1-825)")
	flag.Parse()
	if err := generate(*ipText, *output, *days); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func generate(ipText, output string, days int) error {
	ip := net.ParseIP(ipText)
	if ip == nil || ip.IsUnspecified() || ip.IsLoopback() || output == "" || days < 1 || days > 825 {
		return fmt.Errorf("provide --ip PUBLIC_IP --out NEW_PRIVATE_DIRECTORY [--days 365]")
	}
	if err := os.Mkdir(output, 0700); err != nil {
		return fmt.Errorf("refusing to replace existing certificate directory: %w", err)
	}
	if err := protectDirectory(output); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	now := time.Now()
	leaf := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Universal HMI private HTTPS"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(time.Duration(days) * 24 * time.Hour), IPAddresses: []net.IP{ip}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: false}
	der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	if err != nil {
		return err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	write := func(name, kind string, b []byte, mode os.FileMode) error {
		f, e := os.OpenFile(filepath.Join(output, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
		if e != nil {
			return e
		}
		_, e = f.Write(pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: b}))
		ce := f.Close()
		if e != nil {
			return e
		}
		return ce
	}
	if err = write("server-key.pem", "PRIVATE KEY", private, 0600); err != nil {
		return err
	}
	if err = write("server-cert.pem", "CERTIFICATE", der, 0644); err != nil {
		return err
	}
	hash := sha256.Sum256(der)
	fmt.Printf("Certificate: %s\nPrivate key: %s\nSHA256 fingerprint: %s\nExpires: %s\n", filepath.Join(output, "server-cert.pem"), filepath.Join(output, "server-key.pem"), hex.EncodeToString(hash[:]), leaf.NotAfter.UTC().Format(time.RFC3339))
	return nil
}

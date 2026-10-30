package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateRefusesOverwrite(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "certs")
	if e := generate("203.0.113.5", dir, 1); e != nil {
		t.Fatal(e)
	}
	certPEM, _ := os.ReadFile(filepath.Join(dir, "server-cert.pem"))
	block, _ := pem.Decode(certPEM)
	cert, e := x509.ParseCertificate(block.Bytes)
	if e != nil || cert.IsCA || !cert.BasicConstraintsValid {
		t.Fatalf("certificate must be a self-signed non-CA leaf: %v", e)
	}
	before, _ := os.ReadFile(filepath.Join(dir, "server-key.pem"))
	if e := generate("203.0.113.5", dir, 1); e == nil {
		t.Fatal("overwrote directory")
	}
	after, _ := os.ReadFile(filepath.Join(dir, "server-key.pem"))
	if string(before) != string(after) {
		t.Fatal("key changed")
	}
}

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
)

type remoteConfig struct {
	Schema      int    `json:"schema"`
	Enabled     bool   `json:"enabled"`
	Origin      string `json:"origin"`
	Listen      string `json:"listen"`
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
	// Only direct TCP peers are matched; forwarded headers are never trusted.
	WebAllowlist []server.PublicIPRule `json:"web_allowlist"`
}
type remoteDeployment struct {
	Config remoteConfig
	Digest string
	TLS    *tls.Config
}

func validateRemotePrivatePath(configPath, keyPath, webDir string) error {
	if webDir == "" {
		return nil
	}
	if !filepath.IsAbs(keyPath) {
		keyPath = filepath.Join(filepath.Dir(configPath), keyPath)
	}
	key, e := filepath.Abs(keyPath)
	if e != nil {
		return e
	}
	web, e := filepath.Abs(webDir)
	if e != nil {
		return e
	}
	// Resolve links so a symlink cannot accidentally publish the private key.
	key, e = filepath.EvalSymlinks(key)
	if e != nil {
		return e
	}
	web, e = filepath.EvalSymlinks(web)
	if e != nil {
		return e
	}
	rel, e := filepath.Rel(web, key)
	if e != nil {
		return e
	}
	if rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("remote private key must be outside the served web directory")
	}
	return nil
}

func loadRemote(path string) (remoteDeployment, error) {
	return loadRemoteConfig(path, true)
}

// Startup defers bootstrap validation until the authoritative database is read.
func loadRemoteConfig(path string, validateBootstrap bool) (remoteDeployment, error) {
	var result remoteDeployment
	if path == "" {
		return result, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return result, fmt.Errorf("remote configuration: %w", err)
	}
	hash := sha256.Sum256(raw)
	result.Digest = hex.EncodeToString(hash[:])
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&result.Config); err != nil {
		return result, fmt.Errorf("remote configuration: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF {
		return result, fmt.Errorf("remote configuration must contain one JSON object")
	}
	c := &result.Config
	if c.Schema != 1 && c.Schema != 2 {
		return result, fmt.Errorf("remote configuration schema must be 2 (disabled schema 1 remains supported)")
	}
	if c.Schema == 1 && c.Enabled {
		return result, fmt.Errorf("enabled remote schema 1 is no longer supported: preserve the original file and explicitly create a disabled schema 2 configuration with web_allowlist before enabling public read-only access")
	}
	if c.Schema == 2 && validateBootstrap {
		if _, err := server.PublicAccessHandler(http.NotFoundHandler(), server.PublicAccessOptions{WebAllowlist: c.WebAllowlist}); err != nil {
			return result, fmt.Errorf("remote web_allowlist: %w", err)
		}
	}
	if !c.Enabled {
		return result, nil
	}
	u, e := url.Parse(c.Origin)
	if e != nil || u.Scheme != "https" || net.ParseIP(u.Hostname()) == nil || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return result, fmt.Errorf("enabled remote access requires an exact HTTPS IP origin without path/query")
	}
	// Browsers serialize the HTTPS default port without :443. Canonicalize
	// before IdentityHandler performs its exact Host/Origin checks.
	if u.Port() == "443" {
		host := u.Hostname()
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		u.Host = host
		c.Origin = u.String()
	}
	if _, _, e = net.SplitHostPort(c.Listen); e != nil {
		return result, fmt.Errorf("remote listen must include an address and port: %w", e)
	}
	if c.Certificate == "" || c.PrivateKey == "" {
		return result, fmt.Errorf("enabled remote access requires certificate and private_key")
	}
	resolve := func(p string) string {
		if filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(filepath.Dir(path), p)
	}
	certPath, keyPath := resolve(c.Certificate), resolve(c.PrivateKey)
	certBytes, e := os.ReadFile(certPath)
	if e != nil {
		return result, e
	}
	keyBytes, e := os.ReadFile(keyPath)
	if e != nil {
		return result, e
	}
	material := sha256.New()
	material.Write(raw)
	material.Write(certBytes)
	material.Write(keyBytes)
	result.Digest = hex.EncodeToString(material.Sum(nil))
	pair, e := tls.LoadX509KeyPair(certPath, keyPath)
	if e != nil {
		return result, fmt.Errorf("remote certificate/key: %w", e)
	}
	leaf, e := x509.ParseCertificate(pair.Certificate[0])
	if e != nil {
		return result, e
	}
	now := time.Now()
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return result, fmt.Errorf("remote certificate is not currently valid")
	}
	if e = leaf.VerifyHostname(u.Hostname()); e != nil {
		return result, fmt.Errorf("remote certificate IP SAN: %w", e)
	}
	if leaf.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return result, fmt.Errorf("remote certificate must allow digital signatures")
	}
	serverUsage := len(leaf.ExtKeyUsage) == 0
	for _, usage := range leaf.ExtKeyUsage {
		if usage == x509.ExtKeyUsageServerAuth || usage == x509.ExtKeyUsageAny {
			serverUsage = true
		}
	}
	if !serverUsage {
		return result, fmt.Errorf("remote certificate must allow server authentication")
	}
	result.TLS = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}}
	return result, nil
}

// serveListeners owns both accept loops. Any failure shuts down both endpoints;
// bind all listeners before calling this function so startup cannot be partial.
func serveListeners(ctx context.Context, servers []*http.Server, listeners []net.Listener) error {
	errors := make(chan error, len(servers))
	for i, s := range servers {
		go func(s *http.Server, l net.Listener) { errors <- s.Serve(l) }(s, listeners[i])
	}
	var result error
	select {
	case <-ctx.Done():
	case result = <-errors:
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, s := range servers {
		if e := s.Shutdown(shutdown); e != nil {
			s.Close()
			if result == nil {
				result = e
			}
		}
	}
	if result == http.ErrServerClosed {
		return nil
	}
	return result
}

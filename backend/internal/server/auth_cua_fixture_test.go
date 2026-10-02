package server

import (
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// TestManualAuthenticatedCUAFixture is opt-in manual GUI infrastructure, not an
// automated UI driver or a deployable account. It serves real application/auth
// code on TLS loopback and exports only its synthetic public certificate for an
// isolated in-process trust store in test_driver/auth_cua.dart. Never install it
// into a browser/OS trust store or use these test credentials in a deployment.
func TestManualAuthenticatedCUAFixture(t *testing.T) {
	output := os.Getenv("HMI_AUTH_CUA_FIXTURE")
	if output == "" {
		t.Skip("manual CUA fixture is opt-in")
	}
	raw, _, _ := platform(t)
	mux := http.NewServeMux()
	mux.Handle("/", raw)
	mux.Handle("/mcp", NewMCPHandler(raw, MCPOptions{AllowWrite: true, Authorize: func(r *http.Request, write bool) bool {
		p, ok := PrincipalFromContext(r.Context())
		return ok && (!write || p.AllowWrite)
	}}))
	srv := httptest.NewUnstartedServer(nil)
	hash, err := bcrypt.GenerateFromPassword([]byte("fixture-only-login"), 12)
	if err != nil {
		t.Fatal(err)
	}
	auth, err := NewAuth(AuthConfig{Username: "qa-operator", PasswordHash: string(hash), AllowWrite: true, PublicOrigin: "https://" + srv.Listener.Addr().String(), SessionTTL: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	srv.Config.Handler = auth.Handler(mux)
	srv.StartTLS()
	defer srv.Close()
	dir := t.TempDir()
	ca := filepath.Join(dir, "fixture-public-certificate.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	stop := filepath.Join(dir, "stop")
	payload, _ := json.Marshal(map[string]any{"url": srv.URL, "ca_file": ca, "stop_file": stop, "expires_after_seconds": 60, "purpose": "isolated manual CUA TLS/auth test; not production"})
	if err := os.WriteFile(output, payload, 0600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(output)
	t.Log("Isolated TLS fixture ready; use test-only credentials declared in this test and the public-certificate path in the readiness file")
	timer := time.NewTimer(25 * time.Minute)
	defer timer.Stop()
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-timer.C:
			t.Fatal("manual CUA observation window elapsed; fixture stopped")
		case <-tick.C:
			if _, err := os.Stat(stop); err == nil {
				return
			}
		}
	}
}

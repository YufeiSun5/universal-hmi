package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
)

// Re-execute only this test in a disposable process so real main assembly and
// its flag/lifecycle globals cannot contaminate the parent test process.
func TestPublicStartupHelper(t *testing.T) {
	raw := os.Getenv("HMI_PUBLIC_STARTUP_TEST_ARGS")
	if raw == "" {
		return
	}
	var args []string
	if err := json.Unmarshal([]byte(raw), &args); err != nil {
		t.Fatal(err)
	}
	flag.CommandLine = flag.NewFlagSet("hmi-public-startup-test", flag.ExitOnError)
	os.Args = append([]string{"hmi-public-startup-test"}, args...)
	main()
}

type publicStartup struct {
	local  string
	remote remoteConfig
	client *http.Client
}

func launchPublicStartup(t *testing.T, variant string) publicStartup {
	t.Helper()
	config, path := testRemote(t)
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	config.Listen = reservation.Addr().String()
	if err := reservation.Close(); err != nil {
		t.Fatal(err)
	}
	config.WebAllowlist = []server.PublicIPRule{{CIDR: "127.0.0.0/8", Owner: "Synthetic cloud loopback"}}
	switch variant {
	case "legacy":
		config.Schema = 1
	case "invalid-cidr", "database-policy":
		config.WebAllowlist[0].CIDR = "not-an-IP"
	case "empty":
		config.WebAllowlist = nil
	}
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if variant == "malformed" {
		raw = []byte(`{"schema":2,"enabled":true,`)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Dir(path)
	if variant == "database-policy" {
		ids, err := identity.Open(filepath.Join(dir, "data", "security"))
		if err != nil {
			t.Fatal(err)
		}
		owner, err := ids.Bootstrap("synthetic-owner", "synthetic startup password longer than 15")
		if err != nil {
			t.Fatal(err)
		}
		if err = ids.InitPublicIPPolicy(nil); err != nil {
			t.Fatal(err)
		}
		if _, err = ids.SavePublicIPPolicy(ids.Actor(owner), 0, []identity.PublicIPRule{{CIDR: "127.0.0.1", Enabled: true}}); err != nil {
			t.Fatal(err)
		}
		if err = ids.Close(); err != nil {
			t.Fatal(err)
		}
	}
	web := filepath.Join(dir, "web")
	if err := os.Mkdir(web, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(web, "main.dart.js"), []byte("synthetic startup asset"), 0600); err != nil {
		t.Fatal(err)
	}
	endpoint := filepath.Join(dir, "endpoint.json")
	args := []string{"--listen", "127.0.0.1:0", "--auto-port", "--endpoint-file", endpoint, "--data-dir", filepath.Join(dir, "data"), "--identity", "--identity-local-setup", "--remote-config", path, "--web-dir", web}
	encoded, _ := json.Marshal(args)
	logPath := filepath.Join(dir, "startup.log")
	log, err := os.Create(logPath)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestPublicStartupHelper$")
	cmd.Env = append(os.Environ(), "HMI_PUBLIC_STARTUP_TEST_ARGS="+string(encoded))
	cmd.Stdout = log
	cmd.Stderr = log
	if err := cmd.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("startup helper did not stop")
		}
		log.Close()
	})
	fail := func(reason string) { data, _ := os.ReadFile(logPath); t.Fatalf("%s: %s", reason, data) }
	var found struct {
		URL string `json:"url"`
		PID int    `json:"pid"`
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(endpoint)
		if err == nil && json.Unmarshal(data, &found) == nil && found.URL != "" {
			break
		}
		// ProcessState is written by Wait; inspect process completion only through channel.
		select {
		case err := <-done:
			done <- err
			fail("startup helper exited")
		default:
		}
		time.Sleep(20 * time.Millisecond)
	}
	if found.URL == "" || found.PID != cmd.Process.Pid {
		fail("local endpoint not published")
	}
	cert, err := os.ReadFile(filepath.Join(dir, "cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(cert) {
		t.Fatal("test cert invalid")
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, config.Listen)
	}}
	t.Cleanup(transport.CloseIdleConnections)
	return publicStartup{local: strings.TrimSuffix(found.URL, "/"), remote: config, client: &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func startupCall(t *testing.T, client *http.Client, method, url, origin, host, token, body string) (int, http.Header, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, url, bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if host != "" {
		req.Host = host
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, resp.Header, data
}

// Setup and login run the real Argon2id cost (3 passes, 64 MiB), including
// under -race on shared CI runners. Give only those requests a bounded budget
// matching the server write timeout; ordinary boundary probes remain at 5s.
// Copying preserves TLS trust/redirect policy without mutating the probe client.
func startupPasswordClient(client *http.Client) *http.Client {
	copy := *client
	copy.Timeout = 30 * time.Second
	return &copy
}

func TestStartupPasswordClientKeepsProbeDeadlineAndTransport(t *testing.T) {
	transport := &http.Transport{}
	defer transport.CloseIdleConnections()
	probe := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	auth := startupPasswordClient(probe)
	if auth == probe || auth.Timeout != 30*time.Second || probe.Timeout != 5*time.Second {
		t.Fatal("authentication budget mutated or replaced ordinary probe deadline")
	}
	if auth.Transport != probe.Transport || auth.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Fatal("authentication client lost TLS transport or redirect policy")
	}
}

func startupLocalRepair(t *testing.T, s publicStartup, enabled bool) string {
	t.Helper()
	client := &http.Client{Timeout: 5 * time.Second}
	if code, _, body := startupCall(t, client, "GET", s.local+"/health", "", "", "", ""); code != 200 {
		t.Fatalf("local health %d %s", code, body)
	}
	code, _, body := startupCall(t, client, "GET", s.local+"/api/v1/local/deployment", "", "", "", "")
	var deployment struct {
		Enabled bool   `json:"remote_enabled"`
		Error   string `json:"remote_config_error"`
	}
	if code != 200 || json.Unmarshal(body, &deployment) != nil || deployment.Enabled != enabled || (deployment.Error == "") == !enabled {
		t.Fatalf("deployment enabled=%t: %d %s", enabled, code, body)
	}
	credentials := `{"username":"synthetic-owner","password":"synthetic startup password longer than 15"}`
	if code, _, body := startupCall(t, startupPasswordClient(client), "POST", s.local+"/api/v1/auth/setup", s.local, "", "", credentials); code != 200 {
		t.Fatalf("local setup %d %s", code, body)
	}
	login := `{"username":"synthetic-owner","password":"synthetic startup password longer than 15","issue_token":true}`
	code, _, body = startupCall(t, startupPasswordClient(client), "POST", s.local+"/api/v1/auth/login", s.local, "", "", login)
	var session struct {
		Token  string `json:"bearer_token"`
		Manage bool   `json:"can_manage_users"`
	}
	if code != 200 || json.Unmarshal(body, &session) != nil || session.Token == "" || !session.Manage {
		t.Fatalf("local login %d %s", code, body)
	}
	return session.Token
}

func TestPublicStartupInvalidConfigPreservesLocalRepair(t *testing.T) {
	for _, variant := range []string{"malformed", "legacy", "invalid-cidr"} {
		t.Run(variant, func(t *testing.T) {
			s := launchPublicStartup(t, variant)
			startupLocalRepair(t, s, false)
			// The rejected public configuration must not have bound its requested listener.
			unused, err := net.Listen("tcp", s.remote.Listen)
			if err != nil {
				t.Fatalf("public listener unexpectedly bound: %v", err)
			}
			unused.Close()
		})
	}
}

func TestPublicStartupSchema2IPAndReadonlyBoundary(t *testing.T) {
	for _, variant := range []string{"empty", "allow"} {
		t.Run(variant, func(t *testing.T) {
			s := launchPublicStartup(t, variant)
			localToken := startupLocalRepair(t, s, true)
			if variant == "empty" {
				for _, path := range []string{"/health", "/main.dart.js", "/api/v1/auth/login"} {
					code, _, body := startupCall(t, s.client, "GET", s.remote.Origin+path, "", "", "", "")
					if code != 403 {
						t.Fatalf("empty allowlist %s: %d %s", path, code, body)
					}
				}
				return
			}
			code, headers, body := startupCall(t, s.client, "GET", s.remote.Origin+"/main.dart.js", "", "", "", "")
			if code != 200 || string(body) != "synthetic startup asset" || headers.Get("X-Content-Type-Options") != "nosniff" || headers.Get("X-Frame-Options") != "DENY" || headers.Get("Strict-Transport-Security") == "" {
				t.Fatalf("asset boundary: %d %v %s", code, headers, body)
			}
			if code, _, _ := startupCall(t, s.client, "GET", s.remote.Origin+"/main.dart.js", "", "wrong.example", "", ""); code != 403 {
				t.Fatalf("wrong Host accepted: %d", code)
			}
			login := `{"username":"synthetic-owner","password":"synthetic startup password longer than 15","issue_token":true}`
			code, _, body = startupCall(t, startupPasswordClient(s.client), "POST", s.remote.Origin+"/api/v1/auth/login", s.remote.Origin, "", "", login)
			var session struct {
				Token   string `json:"bearer_token"`
				Channel string `json:"channel"`
				Manage  bool   `json:"can_manage_users"`
			}
			if code != 200 || json.Unmarshal(body, &session) != nil || session.Token == "" || session.Channel != "public:web" || session.Manage {
				t.Fatalf("public owner session %d %s", code, body)
			}
			for _, path := range []string{"/api/v1/security/users", "/api/v1/apply", "/api/v1/local/deployment", "/mcp"} {
				if code, _, body := startupCall(t, s.client, "POST", s.remote.Origin+path, s.remote.Origin, "", session.Token, `{}`); code != 403 {
					t.Fatalf("public admin route %s: %d %s", path, code, body)
				}
			}
			if code, _, _ := startupCall(t, s.client, "GET", s.remote.Origin+"/api/v1/runtime", "", "", localToken, ""); code != 401 {
				t.Fatalf("local token accepted public: %d", code)
			}
		})
	}
}

func TestPublicStartupDatabasePolicyIgnoresObsoleteFileRules(t *testing.T) {
	s := launchPublicStartup(t, "database-policy")
	code, _, body := startupCall(t, s.client, "GET", s.remote.Origin+"/main.dart.js", "", "", "", "")
	if code != 200 {
		t.Fatalf("persisted policy lost to obsolete invalid bootstrap: %d %s", code, body)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	login := `{"username":"synthetic-owner","password":"synthetic startup password longer than 15","issue_token":true}`
	code, _, body = startupCall(t, startupPasswordClient(client), "POST", s.local+"/api/v1/auth/login", s.local, "", "", login)
	var session struct {
		Token string `json:"bearer_token"`
	}
	if code != 200 || json.Unmarshal(body, &session) != nil || session.Token == "" {
		t.Fatalf("local login %d %s", code, body)
	}
	code, _, body = startupCall(t, client, "PUT", s.local+"/api/v1/security/public-access", s.local, "", session.Token, `{"revision":1,"rules":[]}`)
	if code != 200 {
		t.Fatalf("live policy save %d %s", code, body)
	}
	if code, _, body = startupCall(t, s.client, "GET", s.remote.Origin+"/main.dart.js", "", "", "", ""); code != 403 {
		t.Fatalf("live policy not applied %d %s", code, body)
	}
	if code, _, body = startupCall(t, client, "GET", s.local+"/api/v1/security/public-access", "", "", session.Token, ""); code != 200 {
		t.Fatalf("local repair blocked %d %s", code, body)
	}
}

func TestPublicStartupRequestAuditIsLocalAndRedacted(t *testing.T) {
	s := launchPublicStartup(t, "allow")
	token := startupLocalRepair(t, s, true)
	if code, _, _ := startupCall(t, s.client, "GET", s.remote.Origin+"/api/v1/unknown-secret-id?password=secret-query", "", "", "", ""); code != 403 {
		t.Fatal(code)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		code, _, body := startupCall(t, client, "GET", s.local+"/api/v1/security/public-access/events", "", "", token, "")
		var snapshot identity.PublicAccessSnapshot
		if code != 200 || json.Unmarshal(body, &snapshot) != nil {
			t.Fatalf("local audit %d %s", code, body)
		}
		if len(snapshot.Items) > 0 {
			if len(snapshot.Items) != 1 || snapshot.Items[0].Route != "/api/*" || snapshot.Items[0].Decision != "public_read_only" || snapshot.Items[0].UserID != "" || strings.Contains(string(body), "secret-") {
				t.Fatalf("audit attribution/leak %s", body)
			}
			if code, _, _ := startupCall(t, s.client, "GET", s.remote.Origin+"/api/v1/security/public-access/events", "", "", token, ""); code != 403 {
				t.Fatal("public audit exposed", code)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("public request audit missing")
}

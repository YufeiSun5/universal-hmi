package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

// A real TLS loopback server exercises the final middleware order; all data and
// credentials are synthetic and disappear with the test process/temp directory.
func authenticatedPlatform(t *testing.T, writes, mcpWrites bool) (*httptest.Server, *http.Client) {
	t.Helper()
	raw, _, _ := platform(t)
	mux := http.NewServeMux()
	mux.Handle("/", raw)
	mux.Handle("/mcp", newFixtureMCPHandler(raw, MCPOptions{AllowWrite: mcpWrites, Authorize: func(r *http.Request, write bool) bool {
		principal, ok := PrincipalFromContext(r.Context())
		return ok && (!write || principal.AllowWrite)
	}}))
	srv := httptest.NewUnstartedServer(nil)
	hash, err := bcrypt.GenerateFromPassword([]byte("isolated-test-password-only"), 12)
	if err != nil {
		t.Fatal(err)
	}
	auth, err := NewAuth(AuthConfig{Username: "test-operator", PasswordHash: string(hash), AllowWrite: writes, PublicOrigin: "https://" + srv.Listener.Addr().String()})
	if err != nil {
		t.Fatal(err)
	}
	srv.Config.Handler = auth.Handler(mux)
	srv.StartTLS()
	t.Cleanup(srv.Close)
	client := srv.Client()
	client.Jar, _ = cookiejar.New(nil)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return srv, client
}

func integrationRequest(t *testing.T, client *http.Client, server, method, path, body, csrf string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, server+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Origin", server)
	req.Header.Set("MCP-Protocol-Version", "2025-11-25")
	if csrf != "" {
		req.Header.Set("X-CSRF-Token", csrf)
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
	return resp.StatusCode, data
}
func integrationLogin(t *testing.T, client *http.Client, server string) string {
	t.Helper()
	code, body := integrationRequest(t, client, server, "POST", "/api/v1/auth/login", `{"username":"test-operator","password":"isolated-test-password-only"}`, "")
	if code != 200 {
		t.Fatalf("login: %d %s", code, body)
	}
	var session struct {
		CSRF string `json:"csrf_token"`
	}
	if err := json.Unmarshal(body, &session); err != nil || session.CSRF == "" {
		t.Fatalf("session %s, %v", body, err)
	}
	return session.CSRF
}

func TestAuthenticatedPlatformProtectsEveryBusinessRouteAndMCP(t *testing.T) {
	srv, client := authenticatedPlatform(t, true, true)
	for _, tool := range MCPToolInventory() {
		if tool.Path == "/health" {
			continue
		}
		path := strings.ReplaceAll(tool.Path, "{id}", "test-id")
		code, body := integrationRequest(t, client, srv.URL, tool.Method, path, `{}`, "")
		if code != 401 {
			t.Errorf("anonymous %s %s: %d %s", tool.Method, path, code, body)
		}
	}
	rpc := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"points_list","arguments":{}}}`
	code, body := integrationRequest(t, client, srv.URL, "POST", "/mcp", rpc, "")
	if code != 401 {
		t.Fatalf("anonymous MCP: %d %s", code, body)
	}
	csrf := integrationLogin(t, client, srv.URL)
	code, body = integrationRequest(t, client, srv.URL, "POST", "/mcp", rpc, "")
	if code != 403 {
		t.Fatalf("MCP cookie CSRF bypass: %d %s", code, body)
	}
	code, body = integrationRequest(t, client, srv.URL, "POST", "/mcp", rpc, csrf)
	if code != 200 || bytes.Contains(body, []byte(`"isError":true`)) {
		t.Fatalf("MCP read: %d %s", code, body)
	}
	mcpCreate := `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"points_create","arguments":{"station":"A","name":"MCP TLS origin integration","source_type":"manual","data_type":"FLOAT"}}}`
	code, body = integrationRequest(t, client, srv.URL, "POST", "/mcp", mcpCreate, csrf)
	if code != 200 || bytes.Contains(body, []byte(`"isError":true`)) || bytes.Contains(body, []byte(`"error":`)) || !bytes.Contains(body, []byte("MCP TLS origin integration")) {
		t.Fatalf("MCP authenticated HTTPS mutation: %d %s", code, body)
	}
	point := `{"station":"A","name":"auth integration","source_type":"manual","data_type":"FLOAT","scale_factor":2,"offset":3}`
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points", point, csrf)
	if code != 201 {
		t.Fatalf("create: %d %s", code, body)
	}
	var saved struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &saved); err != nil || saved.ID == "" {
		t.Fatalf("saved %s", body)
	}
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/apply", `{}`, csrf)
	if code != 200 {
		t.Fatalf("apply %d %s", code, body)
	}
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/"+saved.ID+"/sample", `{"value":4}`, csrf)
	if code != 200 {
		t.Fatalf("sample %d %s", code, body)
	}
	code, body = integrationRequest(t, client, srv.URL, "GET", "/api/v1/runtime", "", "")
	if code != 200 || !bytes.Contains(body, []byte(saved.ID)) {
		t.Fatalf("runtime %d %s", code, body)
	}
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/auth/logout", `{}`, csrf)
	if code != 200 {
		t.Fatalf("logout %d %s", code, body)
	}
	for _, path := range []string{"/api/v1/runtime", "/api/v1/points", "/api/v1/jobs"} {
		code, body = integrationRequest(t, client, srv.URL, "GET", path, "", "")
		if code != 401 {
			t.Errorf("after logout %s: %d %s", path, code, body)
		}
	}
	code, body = integrationRequest(t, client, srv.URL, "POST", "/mcp", rpc, csrf)
	if code != 401 {
		t.Fatalf("MCP after logout %d %s", code, body)
	}
}

func TestAuthenticatedMCPRequiresBothWritePermissions(t *testing.T) {
	for _, test := range []struct {
		name         string
		account, mcp bool
	}{
		{"read-only account", false, true}, {"read-only MCP", true, false}, {"both read-only", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			srv, client := authenticatedPlatform(t, test.account, test.mcp)
			csrf := integrationLogin(t, client, srv.URL)
			rpc := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"points_create","arguments":{"station":"A","name":"must not exist","source_type":"manual","data_type":"FLOAT"}}}`
			code, body := integrationRequest(t, client, srv.URL, "POST", "/mcp", rpc, csrf)
			if code != 200 || !bytes.Contains(body, []byte(`"code":-32003`)) {
				t.Fatalf("write permission: %d %s", code, body)
			}
			code, body = integrationRequest(t, client, srv.URL, "GET", "/api/v1/points", "", "")
			if code != 200 || bytes.Contains(body, []byte("must not exist")) {
				t.Fatalf("side effect %d %s", code, body)
			}
		})
	}
}

func TestAuthTLSClientRequiresTrustedCertificateAndHostname(t *testing.T) {
	srv, trusted := authenticatedPlatform(t, false, false)
	// A stock client does not trust the isolated self-signed fixture certificate.
	client := &http.Client{Transport: http.DefaultTransport.(*http.Transport).Clone()}
	defer client.CloseIdleConnections()
	if response, err := client.Get(srv.URL + "/health"); err == nil {
		response.Body.Close()
		t.Fatal("untrusted fixture certificate unexpectedly accepted")
	}
	// Trust in the fixture CA alone must not disable hostname verification.
	transport := trusted.Transport.(*http.Transport).Clone()
	transport.TLSClientConfig = transport.TLSClientConfig.Clone()
	transport.TLSClientConfig.ServerName = "wrong-host.invalid"
	mismatched := &http.Client{Transport: transport}
	defer mismatched.CloseIdleConnections()
	if response, err := mismatched.Get(srv.URL + "/health"); err == nil {
		response.Body.Close()
		t.Fatal("incorrect certificate hostname unexpectedly accepted")
	}
	code, body := integrationRequest(t, trusted, srv.URL, "GET", "/health", "", "")
	if code != 200 {
		t.Fatalf("explicit test-only CA trust failed: %d %s", code, body)
	}
}

package server

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestFirstDeviceTLSLoginPendingApprovalAndReadOnly(t *testing.T) {
	// A real client key unknown to this independent server; no Web allowlist.
	_, _, _, certificate := deviceTLSFixture(t)
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(nil)
	captchas := newLoginCaptchas()
	opts := IdentityOptions{Origin: "https://" + srv.Listener.Addr().String(), PublicReadOnly: true, captchas: captchas}
	api, err := IdentityHandler(ids, opts, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if err != nil {
		t.Fatal(err)
	}
	static, _ := IdentityHandler(ids, opts, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "login assets") }))
	srv.Config.Handler, err = PublicAccessHandler(api, PublicAccessOptions{Device: ids.VerifyDeviceCertificate, Bootstrap: ids.VerifyDeviceBootstrap, Static: static})
	if err != nil {
		t.Fatal(err)
	}
	srv.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: tls.VersionTLS12}, ids)
	if err != nil {
		t.Fatal(err)
	}
	srv.StartTLS()
	defer srv.Close()
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{certificate}}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	call := func(method, path, body, token string) (int, []byte, http.Header) {
		t.Helper()
		r, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		r.Header.Set("Origin", srv.URL)
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		res, e := client.Do(r)
		if e != nil {
			t.Fatal(e)
		}
		defer res.Body.Close()
		data, e := io.ReadAll(res.Body)
		if e != nil {
			t.Fatal(e)
		}
		return res.StatusCode, data, res.Header
	}
	if status, _, _ := call("GET", "/", "", ""); status != 200 {
		t.Fatal("login assets denied", status)
	}
	if status, _, _ := call("GET", authSessionPath, "", ""); status != 200 {
		t.Fatal(status)
	}
	if status, _, _ := call("GET", loginCaptchaPath, "", ""); status != 200 {
		t.Fatal(status)
	}
	for _, path := range []string{"/api/v1/points", "/api/v1/runtime", "/api/v1/security/users", "/api/v1/security/devices", "/health", "/mcp", "/api/v1/external/screens/x/query"} {
		for _, method := range []string{"GET", "POST"} {
			if status, _, _ := call(method, path, "{}", ""); status != 403 {
				t.Fatal("pending reached data", method, path, status)
			}
		}
	}
	sum := sha256.Sum256(certificate.Leaf.Raw)
	login := func() (int, []byte, http.Header) {
		body, _ := json.Marshal(map[string]any{"username": "owner", "password": publicFixturePassword, "issue_token": true, "captcha_id": seedLoginCaptcha(captchas, "127.0.0.1:"+hex.EncodeToString(sum[:])), "captcha_answer": "12345"})
		return call("POST", authLoginPath, string(body), "")
	}
	for i := 0; i < 2; i++ {
		status, data, headers := login()
		if status != 403 || !strings.Contains(string(data), "device_approval_pending") || headers.Get("Set-Cookie") != "" || strings.Contains(string(data), "bearer_token") {
			t.Fatalf("pending response %d %s", status, data)
		}
	}
	doc, err := ids.DeviceRegistrations(ids.Actor(owner))
	if err != nil || len(doc.Items) != 1 {
		t.Fatal(doc, err)
	}
	// The actual local management route performs the single approval.
	_, _, adminToken, err := ids.Login("owner", publicFixturePassword, "local-admin", true)
	if err != nil {
		t.Fatal(err)
	}
	local, err := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	approvalBody, _ := json.Marshal(map[string]any{"revision": doc.Revision})
	req := httptest.NewRequest("POST", "http://127.0.0.1:12345/api/v1/security/devices/"+doc.Items[0].ID+"/approve-login", strings.NewReader(string(approvalBody)))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Origin", "http://127.0.0.1:12345")
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	local.ServeHTTP(recorder, req)
	if recorder.Code != 200 {
		t.Fatalf("local approval %d %s", recorder.Code, recorder.Body.String())
	}
	status, data, _ := login()
	if status != 200 {
		t.Fatalf("approved login %d %s", status, data)
	}
	var session struct {
		Token     string `json:"bearer_token"`
		CanWrite  bool   `json:"can_write"`
		CanManage bool   `json:"can_manage_users"`
	}
	if json.Unmarshal(data, &session) != nil || session.Token == "" || session.CanWrite || session.CanManage {
		t.Fatal("invalid public session")
	}
	if status, _, _ := call("GET", "/api/v1/points", "", session.Token); status != 204 {
		t.Fatal(status)
	}
	if status, _, _ := call("POST", "/api/v1/stations", "{}", session.Token); status != 403 {
		t.Fatal("write allowed", status)
	}
	certs, _ := ids.DeviceCertificates(ids.Actor(owner))
	if _, err = ids.RevokeDeviceCertificate(ids.Actor(owner), certs.Revision, doc.Items[0].ID); err != nil {
		t.Fatal(err)
	}
	if status, _, _ := call("GET", "/api/v1/points", "", session.Token); status != 403 {
		t.Fatal("revoked device read", status)
	}
}

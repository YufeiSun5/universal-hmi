package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestDeviceCertificatesLocalHTTPBoundary(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	_, session, token, err := ids.Login("owner", publicFixturePassword, "fixture", false)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body, csrf, credential, peer, forward string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:12345"+path, strings.NewReader(body))
		r.RemoteAddr = peer
		r.Header.Set("Origin", "http://127.0.0.1:12345")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", csrf)
		r.Header.Set("Forwarded", forward)
		if credential != "" {
			r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: credential})
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	const path = "/api/v1/security/device-certificates"
	for _, test := range []struct {
		token, peer, forward string
		status               int
	}{{"", "127.0.0.1:1", "", 401}, {token, "192.0.2.1:1", "", 403}, {token, "127.0.0.1:1", "for=127.0.0.1", 403}} {
		if w := call("GET", path, "", "", test.token, test.peer, test.forward); w.Code != test.status {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if w := call("GET", path, "", "", token, "127.0.0.1:1", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"grants_access":false`) {
		t.Fatal(w.Code, w.Body.String())
	}
	_, err = ids.Change(ids.Actor(owner), "", identity.Change{Username: "reader", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if err != nil {
		t.Fatal(err)
	}
	_, _, memberToken, err := ids.Login("reader", publicFixturePassword, "fixture", false)
	if err != nil {
		t.Fatal(err)
	}
	if w := call("GET", path, "", "", memberToken, "127.0.0.1:1", ""); w.Code != 403 {
		t.Fatal("member", w.Code)
	}
	remoteSession := session
	remoteSession.Channel = "public:web"
	rr := httptest.NewRequest("GET", path, nil)
	rr.RemoteAddr = "127.0.0.1:1"
	ww := httptest.NewRecorder()
	deviceCertificatesAPI(ww, rr, ids, ids.Actor(owner), remoteSession)
	if ww.Code != 403 {
		t.Fatal("channel", ww.Code)
	}
	oldSession := session
	oldSession.Started = time.Now().Add(-16 * time.Minute)
	rr = httptest.NewRequest("POST", path+"/fake/revoke", strings.NewReader(`{"revision":0}`))
	rr.RemoteAddr = "127.0.0.1:1"
	ww = httptest.NewRecorder()
	securityAPI(ww, rr, ids, ids.Actor(owner), oldSession)
	if ww.Code != 403 || !strings.Contains(ww.Body.String(), "recent_login_required") {
		t.Fatal(ww.Code, ww.Body.String())
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{}, key)
	if err != nil {
		t.Fatal(err)
	}
	d, err := ids.CreateDeviceRegistration(ids.Actor(owner), 0, owner.ID, "Synthetic", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csr})))
	if err != nil {
		t.Fatal(err)
	}
	id := d.Items[0].ID
	d, err = ids.ApproveDeviceRegistration(ids.Actor(owner), d.Revision, id, time.Now().Add(2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(90 * time.Minute), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	raw := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	input, _ := json.Marshal(map[string]any{"revision": 0, "leaf_pem": raw, "expires_at": time.Now().Add(time.Hour)})
	approve := path + "/" + id + "/approve"
	if w := call("POST", approve, string(input), "", token, "127.0.0.1:1", ""); w.Code != 403 {
		t.Fatal("csrf", w.Code)
	}
	w := call("POST", approve, string(input), session.CSRF, token, "127.0.0.1:1", "")
	var snapshot identity.DeviceCertificateSnapshot
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &snapshot) != nil || snapshot.Revision != 1 || snapshot.GrantsAccess || snapshot.MobileTransportReady {
		t.Fatal(w.Code, w.Body.String())
	}
	if w = call("POST", approve, string(input), session.CSRF, token, "127.0.0.1:1", ""); w.Code != 409 {
		t.Fatal("conflict", w.Code)
	}
	invalid, _ := json.Marshal(map[string]any{"revision": 1, "leaf_pem": "-----BEGIN PRIVATE KEY-----\nNEVER_ECHO_SECRET\n-----END PRIVATE KEY-----", "expires_at": time.Now().Add(time.Hour)})
	if w = call("POST", approve, string(invalid), session.CSRF, token, "127.0.0.1:1", ""); w.Code != 422 || strings.Contains(w.Body.String(), "NEVER_ECHO_SECRET") {
		t.Fatal(w.Code, w.Body.String())
	}
	if w = call("POST", path+"/"+id+"/revoke", `{"revision":1}`, session.CSRF, token, "127.0.0.1:1", ""); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	public, err := PublicAccessHandler(handler, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "http://127.0.0.1:12345"+path, nil)
	r.RemoteAddr = "127.0.0.1:1"
	r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: token})
	w = httptest.NewRecorder()
	public.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("public mounted management", w.Code)
	}
}

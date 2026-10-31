package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func deviceRecordCSR(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{Subject: pkix.Name{CommonName: "synthetic untrusted subject"}}, key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der}))
}

func TestDeviceRegistrationsLocalBoundaryAndNoMobileGrant(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	_, sess, token, err := ids.Login("owner", publicFixturePassword, "fixture", false)
	if err != nil {
		t.Fatal(err)
	}
	h, err := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	call := func(handler http.Handler, method, path, body, csrf, credential, peer string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:12345"+path, strings.NewReader(body))
		r.RemoteAddr = peer
		r.Header.Set("Origin", "http://127.0.0.1:12345")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", csrf)
		r.Header.Set("X-Device-ID", "claimed-phone-is-not-identity")
		if credential != "" {
			r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: credential})
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	const path = "/api/v1/security/devices"
	if w := call(h, "GET", path, "", "", "", "127.0.0.1:1"); w.Code != 401 {
		t.Fatal("anonymous", w.Code)
	}
	w := call(h, "GET", path, "", "", token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	var snapshot identity.DeviceRegistrationSnapshot
	if err = json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Revision != 0 || len(snapshot.Items) != 0 || snapshot.MobileTransportReady || snapshot.GrantsAccess {
		t.Fatal("initial grants", snapshot)
	}
	data, _ := json.Marshal(map[string]any{"revision": 0, "owner_user_id": owner.ID, "label": "Synthetic install", "csr_pem": deviceRecordCSR(t)})
	for _, tc := range []struct{ csrf, peer string }{{"", "127.0.0.1:1"}, {sess.CSRF, "198.51.100.4:1"}} {
		if w = call(h, "POST", path, string(data), tc.csrf, token, tc.peer); w.Code != 403 {
			t.Fatal("management guard", w.Code)
		}
	}
	w = call(h, "POST", path, string(data), sess.CSRF, token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if err = json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Revision != 1 || len(snapshot.Items) != 1 || snapshot.GrantsAccess || snapshot.MobileTransportReady {
		t.Fatal(snapshot)
	}
	id := snapshot.Items[0].ID
	if snapshot.Items[0].OwnerUserID != owner.ID || snapshot.Items[0].State != "pending" {
		t.Fatal("subject became owner", snapshot)
	}
	if w = call(h, "POST", path, string(data), sess.CSRF, token, "127.0.0.1:1"); w.Code != 409 {
		t.Fatal("stale revision", w.Code, w.Body)
	}
	approve, _ := json.Marshal(map[string]any{"revision": 1, "expires_at": time.Now().UTC().Add(time.Hour)})
	w = call(h, "POST", path+"/"+id+"/approve", string(approve), sess.CSRF, token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if err = json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Revision != 2 || snapshot.Items[0].State != "approved" || snapshot.GrantsAccess || snapshot.MobileTransportReady {
		t.Fatal("approval granted mobile access", snapshot)
	}
	viewer, err := ids.Change(ids.Actor(owner), "", identity.Change{Username: "viewer", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if err != nil {
		t.Fatal(err)
	}
	_, _, viewerToken, err := ids.Login(viewer.Username, publicFixturePassword, "fixture", false)
	if err != nil {
		t.Fatal(err)
	}
	if w = call(h, "GET", path, "", "", viewerToken, "127.0.0.1:1"); w.Code != 403 {
		t.Fatal("viewer", w.Code)
	}
	public, err := PublicAccessHandler(h, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1/32"}}})
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{path, path + "/" + id + "/approve", path + "/" + id + "/disable"} {
		if w = call(public, "POST", target, string(approve), sess.CSRF, token, "127.0.0.1:1"); w.Code != 403 {
			t.Fatal("public route", w.Code, w.Body)
		}
	}
	w = call(h, "POST", path+"/"+id+"/disable", `{"revision":2}`, sess.CSRF, token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if err = json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Revision != 3 || snapshot.Items[0].State != "disabled" || snapshot.GrantsAccess {
		t.Fatal(snapshot)
	}
	// Independent local-channel guard, not merely the public route allowlist.
	r := httptest.NewRequest("GET", path, nil)
	r.RemoteAddr = "127.0.0.1:1"
	w = httptest.NewRecorder()
	remoteSession := sess
	remoteSession.Channel = "public:web"
	deviceRegistrationsAPI(w, r, ids, ids.Actor(owner), remoteSession)
	if w.Code != 403 {
		t.Fatal("channel", w.Code)
	}
	// Existing recent-login contract applies to record mutation too.
	w = httptest.NewRecorder()
	oldSession := sess
	oldSession.Started = time.Now().Add(-16 * time.Minute)
	r = httptest.NewRequest("POST", path, strings.NewReader(string(data)))
	r.RemoteAddr = "127.0.0.1:1"
	securityAPI(w, r, ids, ids.Actor(owner), oldSession)
	if w.Code != 403 || !strings.Contains(w.Body.String(), "recent_login_required") {
		t.Fatal("recent login", w.Code, w.Body)
	}
}

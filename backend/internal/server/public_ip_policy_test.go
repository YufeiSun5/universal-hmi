package server

import (
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicIPManagementLocalAuthCSRFAndRevision(t *testing.T) {
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", publicFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	if err = ids.InitPublicIPPolicy([]identity.PublicIPRule{{CIDR: "192.0.2.0/24", Enabled: true}}); err != nil {
		t.Fatal(err)
	}
	_, session, token, err := ids.Login("owner", publicFixturePassword, "test", false)
	if err != nil {
		t.Fatal(err)
	}
	h, err := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:12345", LocalSetup: true}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, body, csrf, credential, peer string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:12345/api/v1/security/public-access", strings.NewReader(body))
		r.RemoteAddr = peer
		r.Header.Set("Origin", "http://127.0.0.1:12345")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("X-CSRF-Token", csrf)
		if credential != "" {
			r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: credential})
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("GET", "", "", "", "127.0.0.1:1"); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	w := call("GET", "", "", token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	var policy identity.PublicIPPolicy
	if err = json.Unmarshal(w.Body.Bytes(), &policy); err != nil {
		t.Fatal(err)
	}
	if policy.Source != "file" || policy.Revision != 0 {
		t.Fatal(policy)
	}
	body := `{"revision":0,"rules":[{"cidr":"198.51.100.0/24","enabled":true,"owner_label":"Synthetic shared NAT"}]}`
	if w = call("PUT", body, "", token, "127.0.0.1:1"); w.Code != 403 {
		t.Fatal("CSRF accepted", w.Code, w.Body)
	}
	if w = call("PUT", body, session.CSRF, token, "198.51.100.3:1"); w.Code != 403 {
		t.Fatal("remote management", w.Code, w.Body)
	}
	w = call("PUT", body, session.CSRF, token, "127.0.0.1:1")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if err = json.Unmarshal(w.Body.Bytes(), &policy); err != nil {
		t.Fatal(err)
	}
	if policy.Source != "database" || policy.Revision != 1 || len(policy.Rules) != 1 || policy.Rules[0].ID == "" {
		t.Fatal(policy)
	}
	if w = call("PUT", body, session.CSRF, token, "127.0.0.1:1"); w.Code != 409 {
		t.Fatal("stale save", w.Code, w.Body)
	}
	viewer, err := ids.Change(ids.Actor(owner), "", identity.Change{Username: "reader", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if err != nil {
		t.Fatal(err)
	}
	_, _, readerToken, err := ids.Login(viewer.Username, publicFixturePassword, "test", false)
	if err != nil {
		t.Fatal(err)
	}
	if w = call("GET", "", "", readerToken, "127.0.0.1:1"); w.Code != 403 {
		t.Fatal("viewer read policy", w.Code, w.Body)
	}
	public, err := PublicAccessHandler(h, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "http://127.0.0.1:12345/api/v1/security/public-access", nil)
	r.RemoteAddr = "127.0.0.1:1"
	r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: token})
	w = httptest.NewRecorder()
	public.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("public route mounted", w.Code, w.Body)
	}
}

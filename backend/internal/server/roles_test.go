package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestCustomRoleHTTPAuthorizationAndRevocation(t *testing.T) {
	s, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	const password = "role HTTP test password over fifteen"
	owner, e := s.Bootstrap("owner", password)
	if e != nil {
		t.Fatal(e)
	}
	u, e := s.Change(s.Actor(owner), "", identity.Change{Username: "reader", Password: password, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if e != nil {
		t.Fatal(e)
	}
	_, _, ownerToken, e := s.Login(owner.Username, password, "owner", true)
	if e != nil {
		t.Fatal(e)
	}
	_, _, readerToken, e := s.Login(u.Username, password, "reader", true)
	if e != nil {
		t.Fatal(e)
	}
	h, e := IdentityHandler(s, IdentityOptions{Origin: "http://127.0.0.1:18160", LocalSetup: true}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	call := func(token, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18160"+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call(readerToken, "GET", "/api/v1/security/roles", ""); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
	w := call(ownerToken, "POST", "/api/v1/security/roles", `{"name":"值班长","grants":{"roles":["viewer","operator"],"export":true}}`)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	var role identity.Role
	if e = json.Unmarshal(w.Body.Bytes(), &role); e != nil {
		t.Fatal(e)
	}
	w = call(ownerToken, "POST", "/api/v1/security/roles/"+role.ID+"/members", fmt.Sprintf(`{"version":%d,"changes":[{"user_id":%q,"version":%d,"assigned":true}]}`, role.Version, u.ID, u.Version))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(readerToken, "GET", "/api/v1/security/sessions", ""); w.Code != 401 {
		t.Fatal("old session still accepted", w.Code)
	}
	w = call(ownerToken, "GET", "/api/v1/security/users", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"custom_role_ids":["`+role.ID+`"]`) || !strings.Contains(w.Body.String(), `"direct_grants"`) {
		t.Fatal(w.Code, w.Body)
	}
	// Cookie sessions remain subject to CSRF even for the new role endpoints.
	_, _, cookieToken, e := s.Login(owner.Username, password, "cookie", false)
	if e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1:18160/api/v1/security/roles", strings.NewReader(`{}`))
	r.RemoteAddr = "127.0.0.1:1"
	r.AddCookie(&http.Cookie{Name: "hmi_local_identity", Value: cookieToken})
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("role mutation bypassed CSRF", w.Code)
	}
}

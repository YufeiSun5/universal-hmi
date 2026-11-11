package server

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestAccountCreationAndAuthorizationWithOlderSession(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", publicFixturePassword)
	if e != nil {
		t.Fatal(e)
	}
	_, session, _, e := ids.Login("owner", publicFixturePassword, "fixture", true)
	if e != nil {
		t.Fatal(e)
	}
	session.Started = time.Now().Add(-24 * time.Hour)
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/v1/security/"+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		w := httptest.NewRecorder()
		securityAPI(w, r, ids, ids.Actor(owner), session)
		return w
	}
	w := call("POST", "users", `{"username":"new-reader","password":"synthetic sufficiently long password","grants":{"roles":["viewer"],"all_stations":true}}`)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var user identity.User
	if e = json.Unmarshal(w.Body.Bytes(), &user); e != nil {
		t.Fatal(e)
	}
	user.Grants.Export = true
	change := identity.Change{Username: user.Username, Version: user.Version, Grants: user.Grants}
	body, _ := json.Marshal(change)
	w = call("PUT", "users/"+user.ID, string(body))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	stored, e := ids.User(user.ID)
	if e != nil || !stored.Grants.Export {
		t.Fatal("authorization not saved", e)
	}
	// Removing the age check does not grant management rights to ordinary users.
	r := httptest.NewRequest("POST", "/api/v1/security/users", strings.NewReader(`{}`))
	w = httptest.NewRecorder()
	securityAPI(w, r, ids, ids.Actor(stored), session)
	if w.Code != 403 {
		t.Fatal("reader created account", w.Code, w.Body.String())
	}
}

package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestExternalHTTPIdentityScopeAndRevocation(t *testing.T) {
	raw, _, engine := platform(t)
	s, e := externaldata.Open(engine.Store, t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	password := "synthetic-test-only"
	source, e := s.SaveSource(context.Background(), externaldata.SourceChange{Source: externaldata.Source{Name: "独立历史", Host: "127.0.0.1", Port: 1, Database: "KIOHistory", Username: "test", Encrypt: true, UTCOffsetMinutes: 480}, Password: &password})
	if e != nil {
		t.Fatal(e)
	}
	screen, e := s.SaveScreen(context.Background(), externaldata.Screen{Name: "外部日报", SourceID: source.ID, Kind: "hourly"})
	if e != nil {
		t.Fatal(e)
	}
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	owner, e := ids.Bootstrap("owner", "long synthetic password for tests")
	if e != nil {
		t.Fatal(e)
	}
	user, e := ids.Change(ids.Actor(owner), "", identity.Change{Username: "reader", Password: "long synthetic password for tests", Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}})
	if e != nil {
		t.Fatal(e)
	}
	handler, e := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:18080", LocalSetup: true}, ExternalDataHandler(raw, s, ""))
	if e != nil {
		t.Fatal(e)
	}
	_, _, token, e := ids.Login(user.Username, "long synthetic password for tests", "", true, "test")
	if e != nil {
		t.Fatal(e)
	}
	call := func(token, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18080"+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := call("", "GET", "/api/v1/external/screens", ""); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(token, "GET", "/api/v1/external/screens", ""); w.Code != 200 || strings.Contains(w.Body.String(), screen.ID) {
		t.Fatal(w.Code, w.Body)
	}
	for _, op := range [][2]string{{"GET", "/api/v1/external/sources"}, {"POST", "/api/v1/external/sources"}, {"POST", "/api/v1/external/screens"}, {"GET", "/api/v1/external/screens/" + screen.ID + "/stations"}, {"POST", "/api/v1/external/screens/" + screen.ID + "/query"}} {
		if w := call(token, op[0], op[1], "{}"); w.Code != 403 {
			t.Fatal(op, w.Code, w.Body)
		}
	}
	user, e = ids.Change(ids.Actor(owner), user.ID, identity.Change{Username: user.Username, Version: user.Version, Grants: authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{screen.ID}}})
	if e != nil {
		t.Fatal(e)
	}
	if w := call(token, "GET", "/api/v1/external/screens", ""); w.Code != 401 {
		t.Fatal("old session survived", w.Code)
	}
	_, _, token, e = ids.Login(user.Username, "long synthetic password for tests", "", true, "test")
	if e != nil {
		t.Fatal(e)
	}
	if w := call(token, "GET", "/api/v1/external/screens", ""); w.Code != 200 || !strings.Contains(w.Body.String(), screen.ID) {
		t.Fatal(w.Code, w.Body)
	}
	// Invalid query reaches the authorized use case, and fails before opening SQL.
	if w := call(token, "POST", "/api/v1/external/screens/"+screen.ID+"/query", `{"station":"A","date":"invalid"}`); w.Code != 422 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(token, "POST", "/api/v1/external/screens/"+screen.ID+"/query", `{"sql":"DELETE dbo.Station"}`); w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
	_, _, ownerToken, e := ids.Login(owner.Username, "long synthetic password for tests", "", true, "owner")
	if e != nil {
		t.Fatal(e)
	}
	if w := call(ownerToken, "GET", "/api/v1/external/sources", ""); w.Code != 200 || strings.Contains(w.Body.String(), password) || strings.Contains(w.Body.String(), "secret") {
		t.Fatal(w.Code, w.Body)
	}
	update, _ := json.Marshal(externaldata.SourceChange{Source: source})
	if w := call(ownerToken, "POST", "/api/v1/external/sources", string(update)); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(ownerToken, "POST", "/api/v1/external/sources", string(update)); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	// The wrapper retains origin protection even without an identity middleware.
	r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:18080/api/v1/external/sources", strings.NewReader(string(update)))
	r.Header.Set("Origin", "https://untrusted.example")
	w := httptest.NewRecorder()
	ExternalDataHandler(raw, s, "").ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("origin bypass", w.Code, w.Body)
	}
}

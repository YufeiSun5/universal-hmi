package server

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEquipmentHTTPIdentityAndScope(t *testing.T) {
	raw, _, engine := platform(t)
	s, e := equipment.Open(engine.Store, t.TempDir(), func() ([]string, error) { return []string{"A", "B"}, nil })
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.Save(context.Background(), equipment.Device{Station: "A", Code: "P01", Name: "pump", Category: "水泵", Location: "Boiler Room 1", Status: "active"})
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
	handler, e := IdentityHandler(ids, IdentityOptions{Origin: "http://127.0.0.1:18080", LocalSetup: true}, EquipmentHandler(raw, s, ""))
	if e != nil {
		t.Fatal(e)
	}
	_, _, token, e := ids.Login(user.Username, "long synthetic password for tests", "", true, "test")
	if e != nil {
		t.Fatal(e)
	}
	call := func(auth, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18080"+path, strings.NewReader(body))
		r.RemoteAddr = "127.0.0.1:1"
		if auth != "" {
			r.Header.Set("Authorization", "Bearer "+auth)
		}
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := call("", "GET", "/api/v1/equipment", ""); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(token, "GET", "/api/v1/equipment", ""); w.Code != 200 || !strings.Contains(w.Body.String(), d.ID) {
		t.Fatal(w.Code, w.Body)
	}
	for _, tt := range []struct {
		path  string
		found bool
	}{
		{"/api/v1/equipment?station=A&category=%E6%B0%B4%E6%B3%B5&location=boiler&search=pump", true},
		{"/api/v1/equipment?location=room+2", false},
	} {
		w := call(token, "GET", tt.path, "")
		if w.Code != 200 || strings.Contains(w.Body.String(), d.ID) != tt.found {
			t.Fatalf("%s: %d %s", tt.path, w.Code, w.Body)
		}
	}
	if w := call(token, "GET", "/api/v1/equipment/status?ids="+d.ID, ""); w.Code != 200 || !strings.Contains(w.Body.String(), "unconfigured") {
		t.Fatal(w.Code, w.Body)
	}
	for _, op := range [][2]string{{"POST", "/api/v1/equipment"}, {"POST", "/api/v1/equipment/" + d.ID + "/photos"}, {"DELETE", "/api/v1/equipment/" + d.ID + "/photos/unknown"}} {
		if w := call(token, op[0], op[1], "{}"); w.Code != 403 {
			t.Fatal(w.Code, w.Body)
		}
	}
	user, e = ids.Change(ids.Actor(owner), user.ID, identity.Change{Username: user.Username, Version: user.Version, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if e != nil {
		t.Fatal(e)
	}
	if w := call(token, "GET", "/api/v1/equipment", ""); w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	_, _, token, e = ids.Login(user.Username, "long synthetic password for tests", "", true, "test")
	if e != nil {
		t.Fatal(e)
	}
	if w := call(token, "GET", "/api/v1/equipment", ""); w.Code != 200 || strings.Contains(w.Body.String(), d.ID) {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(token, "GET", "/api/v1/equipment/"+d.ID, ""); w.Code != 404 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call(token, "GET", "/api/v1/equipment/status?ids="+d.ID, ""); w.Code != 404 {
		t.Fatal(w.Code, w.Body)
	}
}

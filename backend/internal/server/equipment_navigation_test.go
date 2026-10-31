package server

import (
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEquipmentNavigationHTTP(t *testing.T) {
	raw, _, engine := platform(t)
	s, err := equipment.Open(engine.Store, t.TempDir(), func() ([]string, error) { return []string{"A", "B"}, nil })
	if err != nil {
		t.Fatal(err)
	}
	handler := EquipmentHandler(raw, s, "")
	call := func(method, body string, edit, all, active bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/api/v1/equipment-navigation", strings.NewReader(body))
		roles := []string{"viewer"}
		if edit {
			roles = []string{"engineer"}
		}
		req = req.WithContext(authorization.WithActor(req.Context(), authorization.Actor{Grants: authorization.Grants{Roles: roles, AllStations: all, StationIDs: []string{"A"}}, StationID: func(n string) string { return n }, Valid: func() bool { return active }}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w
	}
	body := `{"revision":0,"nodes":[{"id":"g","label":"group","children":[{"id":"a","label":"A","station":"A","site":"zone"},{"id":"b","label":"B","station":"B"}]}]}`
	for _, tt := range []struct{ edit, all bool }{{false, true}, {true, false}} {
		w := call("PUT", body, tt.edit, tt.all, true)
		if w.Code != 403 {
			t.Fatal(w.Code, w.Body)
		}
	}
	w := call("PUT", body, true, true, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"revision":1`) {
		t.Fatal(w.Code, w.Body)
	}
	w = call("PUT", body, true, true, true)
	if w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	w = call("GET", "", false, false, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"site":"zone"`) || strings.Contains(w.Body.String(), `"station":"B"`) {
		t.Fatal(w.Code, w.Body)
	}
	w = call("GET", "", false, true, false)
	if w.Code != 401 {
		t.Fatal(w.Code, w.Body)
	}
	w = call("PUT", `{"revision":1,"nodes":[],"unexpected":true}`, true, true, true)
	if w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
}

package server

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSharedHeatPriceHTTPRuntimeGrantsConflictAndReadOnly(t *testing.T) {
	raw, _, engine := platform(t)
	s, e := externaldata.Open(engine.Store, t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	pw := "synthetic"
	source, e := s.SaveSource(context.Background(), externaldata.SourceChange{Source: externaldata.Source{Name: "统计", Host: "127.0.0.1", Port: 1433, Database: "fixture", Username: "fixture"}, Password: &pw})
	if e != nil {
		t.Fatal(e)
	}
	view, e := s.SaveScreen(context.Background(), externaldata.Screen{Name: "能耗", SourceID: source.ID, Kind: "energy"})
	if e != nil {
		t.Fatal(e)
	}
	handler := ExternalDataHandler(raw, s, "")
	actor := authorization.Actor{ID: "alice", Valid: func() bool { return true }, Grants: authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}}}
	call := func(method, body string, a authorization.Actor) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "http://127.0.0.1/api/v1/external/screens/"+view.ID+"/heat-prices", strings.NewReader(body))
		req = req.WithContext(authorization.WithActor(req.Context(), a))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w
	}
	if w := call("POST", `{"year":2025,"unit_price":"20.25","revision":0}`, actor); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	actor.ID = "bob"
	if w := call("GET", "", actor); w.Code != 200 || !strings.Contains(w.Body.String(), `"20.25"`) || !strings.Contains(w.Body.String(), `"can_edit":true`) {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", `{"year":2025,"unit_price":"30","revision":0}`, actor); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	actor.ReadOnly = true
	if w := call("GET", "", actor); w.Code != 200 || !strings.Contains(w.Body.String(), `"can_edit":false`) {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", `{"year":2025,"unit_price":"30","revision":1}`, actor); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
	actor.ReadOnly = false
	actor.Grants.ExternalScreenIDs = nil
	if w := call("GET", "", actor); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", `{"year":2025,"unit_price":"30","revision":1}`, actor); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
}

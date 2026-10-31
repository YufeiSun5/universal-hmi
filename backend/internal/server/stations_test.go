package server

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func TestStationFirstSharedScreenHTTP(t *testing.T) {
	h, ps, engine := platform(t)
	for _, name := range []string{"A", "B"} {
		if w := request(h, "POST", "/api/v1/stations", `{"name":"`+name+`"}`); w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
	}
	if w := request(h, "POST", "/api/v1/stations", `{"name":"A"}`); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	if w := request(h, "POST", "/api/v1/stations", `{"name":" "}`); w.Code != 400 {
		t.Fatal(w.Code, w.Body)
	}
	if len(ps.List()) != 0 {
		t.Fatal("creating a station created points")
	}
	var names []string
	if e := engine.Store.LoadConfig("station_directory", &names); e != nil || len(names) != 2 {
		t.Fatal(names, e)
	}
	a, _ := ps.Create(points.CreateInput{Station: "A", Name: "A pressure", SourceType: "manual", DataType: "FLOAT"})
	b, _ := ps.Create(points.CreateInput{Station: "B", Name: "B pressure", SourceType: "manual", DataType: "FLOAT"})
	public := process.Document{SchemaVersion: 1, ID: "public", Name: "公共工艺", Width: 1600, Height: 900, Assets: map[string]process.Asset{}, Nodes: []process.Node{{ID: "pressure", Kind: "value", X: 10, Y: 20, Width: 100, Height: 40, Color: "#000000", Fill: "none", FontSize: 20, StrokeWidth: 2}}}
	save := func(d process.Document, code int) process.Document {
		t.Helper()
		data, _ := json.Marshal(d)
		w := request(h, "PUT", "/api/v1/screens/"+d.ID, string(data))
		if w.Code != code {
			t.Fatal(w.Code, w.Body)
		}
		var saved process.Document
		_ = json.Unmarshal(w.Body.Bytes(), &saved)
		return saved
	}
	public = save(public, 200)
	instance := public
	instance.ID = "station-A"
	instance.Name = "A 工艺"
	instance.Station = "A"
	instance.Revision = 0
	instance.Nodes = []process.Node{}
	instance.TemplateID = public.ID
	instance.TemplateRevision = public.Revision
	instance.Bindings = map[string]process.ElementBinding{"pressure": {PointID: a.ID}}
	instance = save(instance, 200)
	cross := instance
	cross.Bindings = map[string]process.ElementBinding{"pressure": {PointID: b.ID}}
	instance = save(cross, 200)
	if ps.List()[1].Station != "B" {
		t.Fatal("cross reference changed ownership")
	}
	public.Nodes[0].X = 50
	public = save(public, 200)
	save(instance, 409)
	var fresh process.Document
	w := request(h, "GET", "/api/v1/screens/station-A", "")
	_ = json.Unmarshal(w.Body.Bytes(), &fresh)
	if w.Code != 200 || fresh.TemplateRevision != 2 || fresh.Nodes[0].X != 50 || fresh.Nodes[0].PointID != b.ID {
		t.Fatal(w.Code, w.Body)
	}
	if w := request(h, "DELETE", "/api/v1/screens/public?revision=2", ""); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	actor := authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}, Valid: func() bool { return true }, StationID: func(n string) string { return n }}
	call := func(method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r = r.WithContext(authorization.WithActor(r.Context(), actor))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := call("GET", "/api/v1/stations", ""); w.Code != 200 || strings.Contains(w.Body.String(), `"B"`) || !strings.Contains(w.Body.String(), `"A"`) {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("POST", "/api/v1/stations", `{"name":"C"}`); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("GET", "/api/v1/screens/station-A", ""); w.Code != 200 || strings.Contains(w.Body.String(), `"bindings"`) {
		t.Fatal(w.Code, w.Body)
	}
	if w := call("GET", "/api/v1/screens/public", ""); w.Code != 403 {
		t.Fatal(w.Code, w.Body)
	}
}

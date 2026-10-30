package server

import (
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"testing"
)

func TestNavigationAndGISJumpUseSavedIdentity(t *testing.T) {
	h, _, _ := platform(t)
	for _, id := range []string{"A", "B"} {
		d := process.Document{SchemaVersion: 1, ID: id, Name: id, Station: id, Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}}
		b, _ := json.Marshal(d)
		if w := request(h, "PUT", "/api/v1/screens/"+id, string(b)); w.Code != 200 {
			t.Fatal(w.Body.String())
		}
	}
	body := `{"revision":0,"enabled":true,"nodes":[{"id":"group","label":"一组两个独立站","children":[{"id":"a","label":"第一站","screen_id":"A"},{"id":"b","label":"第二站","screen_id":"B"}]}]}`
	if w := request(h, "PUT", "/api/v1/navigation", body); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := request(h, "PUT", "/api/v1/navigation", body); w.Code != 409 {
		t.Fatal(w.Code)
	}
	mcp := NewMCPHandler(h, MCPOptions{AllowWrite: true})
	menu := mcpCall(t, mcp, "navigation_get", map[string]any{})
	if menu["revision"] != float64(1) {
		t.Fatal(menu)
	}
	result := mcpCall(t, mcp, "navigation_save", map[string]any{"navigation": menu})
	if result["revision"] != float64(2) {
		t.Fatal(result)
	}
	// Empty groups at the maximum depth round-trip through MCP as well as HTTP.
	var deep map[string]any
	_ = json.Unmarshal([]byte(`{"revision":2,"enabled":true,"nodes":[{"id":"one","label":"1","children":[{"id":"two","label":"2","children":[{"id":"three","label":"3","children":[{"id":"four","label":"4","children":[]}]}]}]}]}`), &deep)
	mcpCall(t, mcp, "navigation_save", map[string]any{"navigation": deep})
	d := process.Document{SchemaVersion: 1, ID: "map", Name: "地图", Kind: "gis", Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}, GIS: &process.GISConfig{Stations: []process.GISStation{{ID: "marker", Name: "站标", Longitude: 122, Latitude: 39, TargetScreenID: "B"}}}}
	b, _ := json.Marshal(d)
	if w := request(h, "PUT", "/api/v1/screens/map", string(b)); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	saved := mcpCall(t, mcp, "screen_get", map[string]any{"id": "map"})
	mcpCall(t, mcp, "screen_save", map[string]any{"id": "map", "screen": saved})
	d.Revision = 2
	d.GIS.Stations[0].TargetScreenID = "map"
	b, _ = json.Marshal(d)
	if w := request(h, "PUT", "/api/v1/screens/map", string(b)); w.Code != 422 {
		t.Fatal(w.Code, w.Body.String())
	}
	request(h, "DELETE", "/api/v1/screens/B?revision=1", "")
	if w := request(h, "GET", "/api/v1/navigation", ""); w.Code != 200 {
		t.Fatal("deleted target must not destroy menu", w.Body.String())
	}
	if w := request(h, "GET", "/api/v1/screens/B", ""); w.Code != 404 {
		t.Fatal(w.Code)
	}
}

package server

import (
	"encoding/json"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
)

func TestHTTPDiscoveryRequiresExistingSourceAndDoesNotConnectOrSave(t *testing.T) {
	h, ps, e := platform(t)
	if err := e.Sources([]acquisition.Source{{ID: "s", Name: "s", Broker: "tcp://127.0.0.1:1", Topic: "data", Protocol: "generic"}}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/api/v1/sources/missing/discovery", "/api/v1/sources/s/discovery?limit=501", "/api/v1/sources/s/discovery?offset=-1", "/api/v1/sources/s/discovery?limit=bad"} {
		if response := request(h, "GET", path, ""); response.Code < 400 {
			t.Fatalf("invalid request succeeded: %s", path)
		}
	}
	response := request(h, "GET", "/api/v1/sources/s/discovery?q=temp&limit=50", "")
	var page rt.DiscoveryPage
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &page) != nil || page.Connected || page.Total != 0 || len(ps.List()) != 0 || page.State != "" {
		t.Fatalf("read-only scan unexpectedly connected/saved: %d %s", response.Code, response.Body.String())
	}
}

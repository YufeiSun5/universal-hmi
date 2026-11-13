package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestOverviewHTTPRevisionScopeAndPublicReadOnly(t *testing.T) {
	h, ps, _ := platform(t)
	a, err := ps.Create(points.CreateInput{Station: "A", Name: "A temperature", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := ps.Create(points.CreateInput{Station: "B", Name: "secret B", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	cfg := overview.Config{Columns: []overview.Column{{ID: "c", Group: "温度", Name: "供温", Decimals: 1}}, Rows: []overview.Row{
		{ID: "a", Area: "一区", Name: "A站", Station: "A", Bindings: map[string]string{"c": b.ID}, Additional: &overview.AdditionalRow{Columns: []string{"c"}, Bindings: map[string]string{"c": b.ID}}},
		{ID: "b", Area: "秘密区域", Name: "秘密B", Station: "B", Bindings: map[string]string{"c": a.ID}},
	}}
	data, _ := json.Marshal(cfg)
	if w := request(h, "PUT", "/api/v1/live-overview", string(data)); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	if w := request(h, "PUT", "/api/v1/live-overview", string(data)); w.Code != 409 {
		t.Fatal(w.Code, w.Body)
	}
	valid := true
	actor := authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}, StationID: func(s string) string { return s }, Valid: func() bool { return valid }}
	scoped := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r.WithContext(authorization.WithActor(r.Context(), actor)))
	})
	call := func(handler http.Handler, method string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://localhost/api/v1/live-overview", strings.NewReader(string(data)))
		r.RemoteAddr = "192.0.2.1:1234"
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	pub, err := PublicAccessHandler(scoped, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "192.0.2.1"}}})
	if err != nil {
		t.Fatal(err)
	}
	w := call(pub, "GET")
	if w.Code != 200 || strings.Contains(w.Body.String(), b.ID) || strings.Contains(w.Body.String(), "秘密") || !strings.Contains(w.Body.String(), "A站") {
		t.Fatal(w.Code, w.Body)
	}
	for _, method := range []string{"PUT", "POST", "DELETE"} {
		if w = call(pub, method); w.Code != 403 {
			t.Fatal(method, w.Code, w.Body)
		}
	}
	if w = call(scoped, "PUT"); w.Code != 403 {
		t.Fatal("viewer write", w.Code, w.Body)
	}
	valid = false
	if w = call(pub, "GET"); w.Code != 401 {
		t.Fatal("revocation", w.Code, w.Body)
	}
}

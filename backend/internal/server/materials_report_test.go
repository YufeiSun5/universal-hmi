package server

import (
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/materials"
	"net/http/httptest"
	"testing"
)

func TestMaterialsReportRoutesAndPermissions(t *testing.T) {
	raw, _, engine := platform(t)
	store, e := materials.Open(engine.Store.DB, materialFiles(t))
	if e != nil {
		t.Fatal(e)
	}
	handler := MaterialsHandler(raw, store, "")
	for _, tt := range []struct {
		path, kind string
		in, out    bool
		code       int
	}{
		{"reports", "inbound", true, false, 200}, {"reports", "outbound", true, false, 403},
		{"reports/export", "both", true, false, 403}, {"reports/export", "both", true, true, 200},
		{"reports", "inbound", false, false, 403}, {"reports", "stock", true, true, 422},
	} {
		req := httptest.NewRequest("GET", "/api/v1/materials/"+tt.path+"?kind="+tt.kind+"&from=2026-11-01T00:00:00Z&until=2026-12-01T00:00:00Z", nil)
		req = req.WithContext(authorization.WithActor(req.Context(), authorization.Actor{ID: "report", Grants: authorization.Grants{MaterialsInbound: tt.in, MaterialsOutbound: tt.out}, Valid: func() bool { return true }}))
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != tt.code {
			t.Fatalf("%+v => %d %s", tt, rec.Code, rec.Body.String())
		}
	}
}

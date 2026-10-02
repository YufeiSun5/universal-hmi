package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func platform(t *testing.T) (http.Handler, *points.Service, *rt.Engine) {
	t.Helper()
	dir := t.TempDir()
	ps, err := points.Open(filepath.Join(dir, "points.json"))
	if err != nil {
		t.Fatal(err)
	}
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	engine, err := rt.New(ps, db)
	if err != nil {
		t.Fatal(err)
	}
	files, err := analysis.New(db, ps, filepath.Join(dir, "exports"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { files.Close(); engine.Close(); db.Close() })
	return PlatformHandler(ps, engine, files, "", ""), ps, engine
}
func request(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
	return w
}
func TestWriteRequiresExplicitValueAndCommandCanBeReconciled(t *testing.T) {
	h, ps, e := platform(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "setpoint", SourceType: "manual", DataType: "FLOAT", Writable: true})
	if err != nil {
		t.Fatal(err)
	}
	version, _ := e.Apply()
	for _, fragment := range []string{"", `,"value":null`} {
		body := `{"command_id":"explicit-command","point_id":"` + p.ID + `","version":"` + version + `"` + fragment + `}`
		w := request(h, "POST", "/api/v1/write", body)
		if w.Code != 400 {
			t.Fatalf("missing/null accepted: %d %s", w.Code, w.Body.String())
		}
	}
	cap := request(h, "GET", "/api/v1/points/"+p.ID+"/write-capability", "")
	if cap.Code != 200 || !strings.Contains(cap.Body.String(), `"writable":true`) {
		t.Fatal(cap.Body.String())
	}
	w := request(h, "POST", "/api/v1/write", `{"command_id":"explicit-command","point_id":"`+p.ID+`","version":"`+version+`","value":0}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = request(h, "GET", "/api/v1/commands/explicit-command", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"readback_confirmed"`) {
		t.Fatal(w.Body.String())
	}
}
func TestStationHTTPPolicySnapshotBatchAndCatalog(t *testing.T) {
	h, _, e := platform(t)
	w := request(h, "POST", "/api/v1/points/batch", `{"items":[{"station":"A","name":"x","data_type":"FLOAT","source_type":"manual"},{"station":"B","name":"x","data_type":"FLOAT","source_type":"manual"}]}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	var batch struct {
		Items []points.Definition `json:"items"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &batch); err != nil {
		t.Fatal(err)
	}
	e.Apply()
	for _, p := range batch.Items {
		e.Manual(p.ID, 1.0)
	}
	w = request(h, "PUT", "/api/v1/storage?station=A", `{"station":"A","enabled":false,"interval_ms":500,"retention_days":17,"point_ids":[]}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = request(h, "GET", "/api/v1/storage?station=A", "")
	if !strings.Contains(w.Body.String(), `"retention_days":17`) {
		t.Fatal(w.Body.String())
	}
	w = request(h, "GET", "/api/v1/storage", "")
	if !strings.Contains(w.Body.String(), `"retention_days":30`) {
		t.Fatal("scoped policy changed global")
	}
	w = request(h, "POST", "/api/v1/snapshot?station=A", "")
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = request(h, "GET", "/api/v1/history/catalog?station=A", "")
	if !strings.Contains(w.Body.String(), `"limit":20000`) || !strings.Contains(w.Body.String(), `"truncated":false`) {
		t.Fatal(w.Body.String())
	}
	w = request(h, "GET", "/api/v1/history?station=B", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"items":[]`) {
		t.Fatal("snapshot escaped scope: " + w.Body.String())
	}
}

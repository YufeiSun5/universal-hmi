package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestConfigurationBoundarySerializesSeparateHandlersAndRejectsDeletedReferences(t *testing.T) {
	for _, kind := range []string{"rules", "storage", "equipment", "screens"} {
		t.Run(kind, func(t *testing.T) {
			api, ps, engine := platform(t)
			p, err := ps.Create(points.CreateInput{Station: "A", Name: "old", SourceType: "manual", DataType: "FLOAT"})
			if err != nil {
				t.Fatal(err)
			}
			_, err = ps.Create(points.CreateInput{Station: "A", Name: "keep", SourceType: "manual", DataType: "FLOAT"})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = engine.Apply(); err != nil {
				t.Fatal(err)
			}
			eq, err := equipment.Open(engine.Store, t.TempDir(), func() ([]string, error) { return []string{"A"}, nil }, equipment.StatusPorts{Catalog: ps})
			if err != nil {
				t.Fatal(err)
			}
			api = EquipmentHandler(api, eq, "")
			entered, release := make(chan struct{}), make(chan struct{})
			// This is a second independently constructed adapter, as with local
			// and public listeners. Pause inside the protected delete boundary.
			deleter := configurationMutationGuard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-release; api.ServeHTTP(w, r) }))
			deleted := make(chan *httptest.ResponseRecorder, 1)
			go func() { deleted <- request(deleter, "DELETE", "/api/v1/points/"+p.ID, "") }()
			<-entered
			method, path, body := "PUT", "/api/v1/storage", `{"interval_ms":1000,"retention_days":30,"point_ids":["`+p.ID+`"]}`
			switch kind {
			case "rules":
				path = "/api/v1/rules"
				body = `{"items":[{"id":"r","name":"r","station":"A","logic":"and","trigger":"rising","cooldown_ms":200,"conditions":[{"point_id":"` + p.ID + `","op":">","value":0}],"actions":[{"type":"snapshot"}]}]}`
			case "equipment":
				method = "POST"
				path = "/api/v1/equipment"
				body = `{"station":"A","name":"pump","code":"P","category":"pump","signals":{"running":{"point_id":"` + p.ID + `","expression":"x > 0"}}}`
			case "screens":
				path = "/api/v1/screens/s"
				body = `{"schema_version":1,"id":"s","name":"s","station":"A","width":1600,"height":900,"nodes":[{"id":"v","kind":"value","point_id":"` + p.ID + `","width":100,"height":40,"font_size":20,"stroke_width":1,"color":"#000000","fill":"none"}],"assets":{}}`
			}
			queued := make(chan *httptest.ResponseRecorder, 1)
			go func() { queued <- request(api, method, path, body) }()
			select {
			case w := <-queued:
				t.Fatalf("configuration escaped serialization: %d %s", w.Code, w.Body.String())
			case <-time.After(30 * time.Millisecond):
			}
			close(release)
			if w := <-deleted; w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			if w := <-queued; w.Code < 400 {
				t.Fatalf("dangling reference accepted: %s", w.Body.String())
			}
			if len(ps.List()) != 1 {
				t.Fatal("delete did not complete")
			}
		})
	}
}

func TestLegacySingleDeleteUsesReferencesAndBatchConflictsRemainAtomic(t *testing.T) {
	h, ps, e := platform(t)
	a, _ := ps.Create(points.CreateInput{Station: "A", Name: "a", SourceType: "manual", DataType: "FLOAT"})
	b, _ := ps.Create(points.CreateInput{Station: "A", Name: "b", SourceType: "manual", DataType: "FLOAT"})
	e.Store.SaveConfig("policy", map[string]any{"point_ids": []string{a.ID}})
	if w := request(h, "DELETE", "/api/v1/points/"+a.ID, ""); w.Code != 409 {
		t.Fatal(w.Code, w.Body.String())
	}
	body, _ := json.Marshal(map[string]any{"targets": []map[string]string{{"id": a.ID, "revision": points.Revision(a)}, {"id": b.ID, "revision": points.Revision(b)}}})
	w := request(h, "POST", "/api/v1/points/delete-preview", string(body))
	var out map[string]any
	json.Unmarshal(w.Body.Bytes(), &out)
	if out["can_commit"] != false || len(ps.List()) != 2 {
		t.Fatal(w.Body.String())
	}
}

func TestDeletedStationBlocksQueuedImplicitRecreationUntilExplicitCreate(t *testing.T) {
	for _, kind := range []string{"points", "screens", "storage", "equipment", "rules"} {
		t.Run(kind, func(t *testing.T) {
			api, ps, engine := platform(t)
			if w := request(api, "POST", "/api/v1/stations", `{"name":"old"}`); w.Code != 200 {
				t.Fatal(w.Body.String())
			}
			preview := request(api, "POST", "/api/v1/stations/delete-preview", `{"targets":[{"name":"old"}]}`)
			var plan map[string]any
			json.Unmarshal(preview.Body.Bytes(), &plan)
			body, _ := json.Marshal(map[string]any{"targets": []map[string]string{{"name": "old"}}, "preview_token": plan["preview_token"]})
			eq, err := equipment.Open(engine.Store, t.TempDir(), func() ([]string, error) {
				all, err := StationDirectory(ps, engine).List()
				names := []string{}
				for _, s := range all {
					names = append(names, s.Name)
				}
				return names, err
			}, equipment.StatusPorts{Catalog: ps})
			if err != nil {
				t.Fatal(err)
			}
			api = EquipmentHandler(api, eq, "")
			entered, release := make(chan struct{}), make(chan struct{})
			deleter := configurationMutationGuard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-release; api.ServeHTTP(w, r) }))
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- request(deleter, "POST", "/api/v1/stations/delete-commit", string(body)) }()
			<-entered
			method, path, payload := "POST", "/api/v1/points", `{"station":"old","name":"scan","source_type":"manual","data_type":"FLOAT"}`
			switch kind {
			case "screens":
				method = "PUT"
				path = "/api/v1/screens/sample"
				payload = `{"schema_version":1,"id":"sample","name":"s","station":"old","width":1600,"height":900,"nodes":[],"assets":{}}`
			case "storage":
				method = "PUT"
				path = "/api/v1/storage?station=old"
				payload = `{"interval_ms":1000,"retention_days":30,"point_ids":[]}`
			case "equipment":
				path = "/api/v1/equipment"
				payload = `{"station":"old","name":"pump","code":"P","category":"pump"}`
			case "rules":
				method = "PUT"
				path = "/api/v1/rules"
				payload = `{"items":[{"station":"old","name":"r","id":"r","conditions":[],"actions":[]}]}`
			}
			queued := make(chan *httptest.ResponseRecorder, 1)
			go func() { queued <- request(api, method, path, payload) }()
			select {
			case w := <-queued:
				t.Fatalf("escaped station boundary: %d %s", w.Code, w.Body.String())
			case <-time.After(30 * time.Millisecond):
			}
			close(release)
			if w := <-done; w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			if w := <-queued; w.Code < 400 {
				t.Fatal("deleted station revived", w.Body.String())
			}
			if w := request(api, "POST", "/api/v1/stations", `{"name":"old"}`); w.Code != 200 {
				t.Fatal(w.Body.String())
			}
			var tombstones []string
			engine.Store.LoadConfig("station_directory_deleted", &tombstones)
			if len(tombstones) != 0 {
				t.Fatal("recreation retained tombstone", tombstones)
			}
			if w := request(api, "POST", "/api/v1/points", `{"station":"old","name":"scan","source_type":"manual","data_type":"FLOAT"}`); w.Code != 201 {
				t.Fatal(w.Body.String())
			}
			if w := request(api, "POST", "/api/v1/points", `{"station":"new MQTT group","name":"scan","source_type":"manual","data_type":"FLOAT"}`); w.Code != 201 {
				t.Fatal("first implicit group rejected", w.Body.String())
			}
		})
	}
}

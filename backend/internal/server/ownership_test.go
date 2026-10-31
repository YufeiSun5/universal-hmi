package server

import (
	"bytes"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/ownership"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"strings"
	"testing"
)

func TestOwnershipSavedStationCannotBeDeletedUntilApplied(t *testing.T) {
	h, ps, e := platform(t)
	for _, name := range []string{"A", "B"} {
		if w := request(h, "POST", "/api/v1/stations", `{"name":"`+name+`"}`); w.Code != 200 {
			t.Fatal(w.Body)
		}
	}
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "active point", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	r := ownership.Request{Targets: []points.StationTarget{{ID: p.ID, Revision: points.Revision(p), Station: "B"}}}
	b, _ := json.Marshal(r)
	w := request(h, "POST", "/api/v1/points/ownership-preview", string(b))
	var preview ownership.Result
	json.Unmarshal(w.Body.Bytes(), &preview)
	r.PreviewToken = preview.PreviewToken
	b, _ = json.Marshal(r)
	w = request(h, "POST", "/api/v1/points/ownership-commit", string(b))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	w = request(h, "POST", "/api/v1/stations/delete-preview", `{"targets":[{"name":"A"}]}`)
	if w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte(`"kind":"runtime"`)) || !bytes.Contains(w.Body.Bytes(), []byte(`"can_commit":false`)) {
		t.Fatal(w.Code, w.Body)
	}
	var blocked map[string]any
	json.Unmarshal(w.Body.Bytes(), &blocked)
	deleteRequest := map[string]any{"targets": []any{map[string]any{"name": "A"}}, "preview_token": blocked["preview_token"]}
	b, _ = json.Marshal(deleteRequest)
	if w = request(h, "POST", "/api/v1/stations/delete-commit", string(b)); w.Code != 409 {
		t.Fatal("active station deletion", w.Code, w.Body)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	w = request(h, "POST", "/api/v1/stations/delete-preview", `{"targets":[{"name":"A"}]}`)
	if w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte(`"can_commit":true`)) {
		t.Fatal(w.Code, w.Body)
	}
	var ready map[string]any
	json.Unmarshal(w.Body.Bytes(), &ready)
	deleteRequest["preview_token"] = ready["preview_token"]
	b, _ = json.Marshal(deleteRequest)
	if w = request(h, "POST", "/api/v1/stations/delete-commit", string(b)); w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
}

func TestOwnershipHTTPAuthCSRFLimitsAndExplicitCommit(t *testing.T) {
	srv, client := authenticatedPlatform(t, true, false)
	for _, action := range []string{"preview", "commit"} {
		code, _ := integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-"+action, `{}`, "")
		if code != 401 {
			t.Fatal("anonymous", action, code)
		}
	}
	csrf := integrationLogin(t, client, srv.URL)
	for _, action := range []string{"preview", "commit"} {
		code, _ := integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-"+action, `{}`, "")
		if code != 403 {
			t.Fatal("csrf", action, code)
		}
	}
	code, _ := integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-preview", `{"targets":[],"preview_token":"`+strings.Repeat("x", 1024*1024)+`"}`, csrf)
	if code != 400 {
		t.Fatal("oversized", code)
	}
	code, _ = integrationRequest(t, client, srv.URL, "POST", "/api/v1/stations", `{"name":"A"}`, csrf)
	if code != 200 {
		t.Fatal(code)
	}
	code, _ = integrationRequest(t, client, srv.URL, "POST", "/api/v1/stations", `{"name":"B"}`, csrf)
	if code != 200 {
		t.Fatal(code)
	}
	code, body := integrationRequest(t, client, srv.URL, "POST", "/api/v1/points", `{"station":"A","name":"owned","source_type":"manual","data_type":"FLOAT"}`, csrf)
	if code != 201 {
		t.Fatal(code, string(body))
	}
	var p points.Definition
	json.Unmarshal(body, &p)
	r := ownership.Request{Targets: []points.StationTarget{{ID: p.ID, Revision: points.Revision(p), Station: "B"}}}
	b, _ := json.Marshal(r)
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-preview", string(b), csrf)
	var out ownership.Result
	json.Unmarshal(body, &out)
	if code != 200 || !out.CanCommit {
		t.Fatal(code, string(body))
	}
	code, _ = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-commit", string(b), csrf)
	if code != 409 {
		t.Fatal("tokenless", code)
	}
	r.PreviewToken = out.PreviewToken
	b, _ = json.Marshal(r)
	code, body = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-commit", string(b), csrf)
	if code != 200 {
		t.Fatal(code, string(body))
	}
	json.Unmarshal(body, &out)
	if !out.Saved || out.Applied || out.Backup == nil {
		t.Fatal(string(body))
	}
	code, _ = integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-commit", string(b), csrf)
	if code != 409 {
		t.Fatal("stale", code)
	}
}

func TestOwnershipHTTPReaderCannotAnalyzeOrCommit(t *testing.T) {
	srv, client := authenticatedPlatform(t, false, false)
	csrf := integrationLogin(t, client, srv.URL)
	for _, action := range []string{"preview", "commit"} {
		code, _ := integrationRequest(t, client, srv.URL, "POST", "/api/v1/points/ownership-"+action, `{}`, csrf)
		if code != 403 {
			t.Fatal(action, code)
		}
	}
}

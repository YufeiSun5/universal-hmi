package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"reflect"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func TestScreenHTTPAndMCPShareRevisionContract(t *testing.T) {
	h, _, _ := platform(t)
	d := process.Document{SchemaVersion: 1, ID: "screen", Name: "测试画面", Station: "A", Width: 1600, Height: 900, Nodes: []process.Node{}, Assets: map[string]process.Asset{}}
	var picture bytes.Buffer
	if err := png.Encode(&picture, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	d.Nodes = []process.Node{{ID: "image", Kind: "image", Image: "reference", Width: 100, Height: 100, Color: "#2563eb", Fill: "none", FontSize: 20, StrokeWidth: 4}}
	d.Assets["reference"] = process.Asset{Name: "reference.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(picture.Bytes())}
	data, _ := json.Marshal(d)
	w := request(h, "PUT", "/api/v1/screens/screen", string(data))
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w = request(h, "PUT", "/api/v1/screens/screen", string(data)); w.Code != 409 {
		t.Fatalf("stale save: %d", w.Code)
	}
	for _, invalid := range []string{string(data) + " {}", strings.Replace(string(data), `"id":"screen"`, `"id":"other"`, 1), strings.Replace(string(data), `"name":`, `"unknown":true,"name":`, 1)} {
		if w = request(h, "PUT", "/api/v1/screens/screen", invalid); w.Code != 400 {
			t.Fatalf("invalid request: %d %s", w.Code, w.Body.String())
		}
	}
	mcp := NewMCPHandler(h, MCPOptions{AllowWrite: true})
	got := mcpCall(t, mcp, "screen_get", map[string]any{"id": "screen"})
	if got["revision"] != float64(1) {
		t.Fatal(got)
	}
	got["name"] = "MCP 保存"
	saved := mcpCall(t, mcp, "screen_save", map[string]any{"id": "screen", "screen": got})
	if saved["revision"] != float64(2) {
		t.Fatal(saved)
	}
	asset := saved["assets"].(map[string]any)["reference"].(map[string]any)
	if asset["data"] != d.Assets["reference"].Data {
		t.Fatal("MCP save lost embedded image")
	}
	list := mcpCall(t, mcp, "screens_list", map[string]any{"station": "A"})
	if len(list["items"].([]any)) != 1 {
		t.Fatal(list)
	}
	if w = request(h, "DELETE", "/api/v1/screens/screen?revision=1", ""); w.Code != 409 {
		t.Fatalf("stale delete: %d", w.Code)
	}
	mcpCall(t, mcp, "screen_delete", map[string]any{"id": "screen", "revision": 2})
	if w = request(h, "GET", "/api/v1/screens/screen", ""); w.Code != 404 {
		t.Fatalf("delete: %d", w.Code)
	}
}

func TestScreenDecodeFailuresExplainReasonAndPreserveSavedDocument(t *testing.T) {
	h, _, _ := platform(t)
	d := process.Document{SchemaVersion: 1, ID: "decode-screen", Name: "原画面", Width: 1280, Height: 660, Nodes: []process.Node{}, Assets: map[string]process.Asset{}}
	data, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	if w := request(h, "PUT", "/api/v1/screens/decode-screen", string(data)); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	cases := []struct{ name, body, message string }{
		{"unknown field", strings.Replace(string(data), `"name":`, `"future_option":true,"name":`, 1), "不支持的字段 future_option"},
		{"wrong integer", strings.Replace(string(data), `"revision":0`, `"revision":1.5`, 1), "revision 必须为整数"},
		{"wrong number", strings.Replace(string(data), `"width":1280`, `"width":"wide"`, 1), "width 的数据类型不正确"},
		{"syntax", `{"schema_version":}`, "JSON 格式错误"},
		{"incomplete", `{"schema_version":1`, "内容不完整"},
		{"empty", "", "文件为空"},
		{"size", `{"name":"` + strings.Repeat("x", process.MaxDocumentBytes) + `"}`, "超过 8 MiB"},
		{"trailing oversized whitespace", string(data) + strings.Repeat(" ", process.MaxDocumentBytes), "超过 8 MiB"},
		{"trailing syntax", string(data) + " !", "JSON 格式错误"},
		{"multiple documents", string(data) + " {}", "只能包含一个 JSON 对象"},
		{"wrong identity", strings.Replace(string(data), `"id":"decode-screen"`, `"id":"other"`, 1), "保存地址不匹配"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := request(h, "PUT", "/api/v1/screens/decode-screen", tc.body)
			var response struct {
				Error struct{ Code, Message string } `json:"error"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if w.Code != 400 || response.Error.Code != "invalid_request" || !strings.Contains(response.Error.Message, tc.message) {
				t.Fatalf("missing diagnostic: %d %+v", w.Code, response.Error)
			}
			got := request(h, "GET", "/api/v1/screens/decode-screen", "")
			var saved process.Document
			if err := json.Unmarshal(got.Body.Bytes(), &saved); err != nil || saved.Revision != 1 || saved.Name != d.Name {
				t.Fatalf("failed request changed original: %+v %v", saved, err)
			}
		})
	}
}

func TestScreenHTTPPersistsAllPipeOptions(t *testing.T) {
	h, _, _ := platform(t)
	radius, spacing, speed, threshold, count := 24.0, 80.0, 60.0, 0.0, 3
	rule := &process.ArrowRule{Match: "all", Conditions: []process.ArrowCondition{{Slot: "运行", Operator: ">", Value: &threshold}}}
	d := process.Document{SchemaVersion: 1, ID: "pipe-options", Name: "管道设置", Width: 1280, Height: 660, Nodes: []process.Node{{
		ID: "pipe", Kind: "pipe", X: 100, Y: 100, Width: 200, Height: 100, Color: "#2563eb", Fill: "none", StrokeWidth: 12, FontSize: 20,
		PipeStyle: "cylinder", PipeRounded: true, PipeElbows: true, PipeBendRadius: &radius,
		Arrow: true, ArrowMode: "count", ArrowCount: &count, ArrowSpacing: &spacing, ArrowAnimate: true, ArrowReverse: true, ArrowSpeed: &speed,
		ArrowVisibleRule: rule, ArrowMotionRule: rule, Orthogonal: true, Points: []process.Position{{X: 100, Y: 100}, {X: 300, Y: 100}, {X: 300, Y: 200}},
	}}, Assets: map[string]process.Asset{}}
	data, _ := json.Marshal(d)
	w := request(h, "PUT", "/api/v1/screens/pipe-options", string(data))
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	var saved process.Document
	if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	d.Revision = 1
	if !reflect.DeepEqual(d, saved) {
		t.Fatalf("save lost pipe options: %+v", saved)
	}
	w = request(h, "GET", "/api/v1/screens/pipe-options", "")
	if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil || !reflect.DeepEqual(d, saved) {
		t.Fatalf("reopen lost pipe options: %+v %v", saved, err)
	}
}

func TestMaterialHTTPAndMCPShareRevisionContract(t *testing.T) {
	h, _, _ := platform(t)
	var picture bytes.Buffer
	if err := png.Encode(&picture, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	m := process.Material{SchemaVersion: 1, ID: "custom-pump", Name: "透明泵", Category: "泵", Asset: process.Asset{Name: "pump.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(picture.Bytes())}}
	data, _ := json.Marshal(m)
	w := request(h, "PUT", "/api/v1/process-materials/custom-pump", string(data))
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w = request(h, "PUT", "/api/v1/process-materials/custom-pump", string(data)); w.Code != 409 {
		t.Fatalf("stale save: %d", w.Code)
	}
	if w = request(h, "PUT", "/api/v1/process-materials/custom-pump", string(data)+" {}"); w.Code != 400 {
		t.Fatalf("trailing JSON: %d", w.Code)
	}
	mcp := NewMCPHandler(h, MCPOptions{AllowWrite: true})
	got := mcpCall(t, mcp, "process_material_get", map[string]any{"id": m.ID})
	got["name"] = "MCP 素材"
	saved := mcpCall(t, mcp, "process_material_save", map[string]any{"id": m.ID, "material": got})
	if saved["revision"] != float64(2) || saved["width"] != float64(2) || saved["asset"].(map[string]any)["data"] != m.Asset.Data {
		t.Fatal(saved)
	}
	list := mcpCall(t, mcp, "process_materials_list", map[string]any{})
	item := list["items"].([]any)[0].(map[string]any)
	if _, ok := item["asset"]; ok {
		t.Fatal("metadata list exposes full image")
	}
	mcpCall(t, mcp, "process_material_delete", map[string]any{"id": m.ID, "revision": 2})
	if w = request(h, "GET", "/api/v1/process-materials/custom-pump", ""); w.Code != 404 {
		t.Fatalf("delete: %d", w.Code)
	}
}

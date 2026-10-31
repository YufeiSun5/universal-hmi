package transfer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/xuri/excelize/v2"
	"image"
	"image/png"
	"path/filepath"
	"strings"
	"testing"
)

func raw(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
func setup(t *testing.T) *Service {
	t.Helper()
	dir := t.TempDir()
	p, e := points.Open(filepath.Join(dir, "points.json"))
	if e != nil {
		t.Fatal(e)
	}
	sc, e := process.Open(filepath.Join(dir, "screens"))
	if e != nil {
		t.Fatal(e)
	}
	return New(p, sc)
}
func screen() process.Document {
	return process.Document{SchemaVersion: 1, ID: "original", Name: "test", Station: "A", Width: 800, Height: 600, Nodes: []process.Node{{ID: "n", Kind: "value", X: 10, Y: 10, Width: 100, Height: 40, Color: "#2563eb", Fill: "none", StrokeWidth: 2, FontSize: 16, PointID: "foreign"}}, Assets: map[string]process.Asset{}}
}
func request() Request {
	return Request{Bundle: Bundle{Format: Format, Version: 1, Screens: []json.RawMessage{raw(Screen{"s", screen()})}, Variables: []json.RawMessage{raw(Variable{"v", points.CreateInput{Name: "P", Station: "A", DataType: "FLOAT", SourceType: "manual"}})}, Bindings: []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "point_id", VariableKey: "v", Operation: "set"})}}, ScreenTargets: map[string]Target{"s": {Mode: "create"}}, VariableTargets: map[string]Target{"v": {Mode: "create"}}, StationMap: map[string]string{"A": "A"}}
}
func TestPreviewCommitIdempotencyAndClear(t *testing.T) {
	s := setup(t)
	r := request()
	p, e := s.Preview(context.Background(), r)
	if e != nil || len(p.Remaining) > 0 {
		t.Fatalf("preview %v %+v", e, p)
	}
	if len(s.Points.List()) != 0 {
		t.Fatal("preview mutated")
	}
	r.PreviewToken = p.PreviewToken
	c, e := s.Commit(context.Background(), r)
	if e != nil || len(c.Remaining) > 0 {
		t.Fatalf("commit %v %+v", e, c)
	}
	if len(s.Points.List()) != 1 {
		t.Fatal("point missing")
	}
	p, e = s.Preview(context.Background(), r)
	if e != nil || len(p.Remaining) > 0 {
		t.Fatalf("retry %v %+v", e, p)
	}
	for _, it := range p.Items {
		if it.Kind != "binding" && it.Status != "unchanged" {
			t.Fatalf("not idempotent %+v", it)
		}
	}
	list, _ := s.Screens.ListAll()
	d, _ := s.Screens.Get(list[0].ID)
	if d.Nodes[0].PointID != s.Points.List()[0].ID {
		t.Fatal("wrong binding")
	}
	clear := Request{Bundle: Bundle{Format: Format, Version: 1, Bindings: []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "point_id", Operation: "clear"})}}, ScreenTargets: map[string]Target{"s": {ID: d.ID, Mode: "update", Revision: raw(d.Revision)}}}
	p, e = s.Preview(context.Background(), clear)
	if e != nil || len(p.Remaining) > 0 {
		t.Fatalf("clear %v %+v", e, p)
	}
	clear.PreviewToken = p.PreviewToken
	_, e = s.Commit(context.Background(), clear)
	if e != nil {
		t.Fatal(e)
	}
	d, _ = s.Screens.Get(d.ID)
	if d.Nodes[0].PointID != "" {
		t.Fatal("clear ignored")
	}
}
func TestPermissionAndInvalidProperty(t *testing.T) {
	s := setup(t)
	r := request()
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return true }})
	if _, e := s.Preview(ctx, r); e == nil {
		t.Fatal("permission bypass")
	}
	r.Bundle.Bindings = []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "evil", Operation: "clear"})}
	p, e := s.Preview(context.Background(), r)
	if e != nil || len(p.Remaining) == 0 {
		t.Fatal("invalid property accepted")
	}
}
func TestHumanWorkbookEditableAndLargePayload(t *testing.T) {
	r := request()
	d := screen()
	d.Nodes[0].Text = strings.Repeat("大", 40000)
	r.Bundle.Screens = []json.RawMessage{raw(Screen{"s", d})}
	data, e := Encode(r.Bundle, "xlsx", "bundle")
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(data))
	if e != nil {
		t.Fatal(e)
	}
	_ = f.SetCellStr("变量", "B2", "edited")
	buf, e := f.WriteToBuffer()
	if e != nil {
		t.Fatal(e)
	}
	decoded, e := Decode(buf.Bytes(), "xlsx", "")
	if e != nil {
		t.Fatal(e)
	}
	var v Variable
	_ = json.Unmarshal(decoded.Variables[0], &v)
	if v.Definition.Name != "edited" {
		t.Fatal("visible edits ignored")
	}
	var sc Screen
	_ = json.Unmarshal(decoded.Screens[0], &sc)
	if sc.Document.Nodes[0].Text != d.Nodes[0].Text {
		t.Fatal("large payload lost")
	}
	csv, e := Encode(r.Bundle, "csv", "bindings")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = Decode(csv, "csv", ""); e != nil {
		t.Fatal(e)
	}
}
func TestVariableOrderAndCAS(t *testing.T) {
	s := setup(t)
	p, e := s.Points.Create(points.CreateInput{Station: "A", Name: "P", DataType: "FLOAT", SourceType: "manual"})
	if e != nil {
		t.Fatal(e)
	}
	in := input(p)
	in.Name = "changed"
	if _, e = s.Points.UpdateRevision(p.ID, "old", in); e == nil {
		t.Fatal("old revision accepted")
	}
	in.Station = "B"
	if _, e = s.Points.UpdateRevision(p.ID, points.Revision(p), in); e == nil {
		t.Fatal("ownership moved")
	}
	a := Variable{"a", points.CreateInput{Inputs: []string{"b"}}}
	b := Variable{"b", points.CreateInput{}}
	o, e := orderVariables([]json.RawMessage{raw(a), raw(b)})
	if e != nil || rowKey(o[0]) != "b" {
		t.Fatal("not topological")
	}
}
func TestUnresolvedBindingSavesEmptyLayoutAndPreservesExisting(t *testing.T) {
	s := setup(t)
	r := request()
	r.Bundle.Variables = nil
	r.VariableTargets = nil
	p, e := s.Preview(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	r.PreviewToken = p.PreviewToken
	c, e := s.Commit(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	if len(c.Remaining) == 0 {
		t.Fatal("unresolved not reported")
	}
	list, _ := s.Screens.ListAll()
	if len(list) != 1 {
		t.Fatal("layout blocked by unresolved variable")
	}
	d, _ := s.Screens.Get(list[0].ID)
	if d.Nodes[0].PointID != "" {
		t.Fatal("raw foreign ID leaked")
	}
}
func TestArrowClearKeepsRuleAndSemanticConflict(t *testing.T) {
	s := setup(t)
	v := 1.0
	d := screen()
	d.Nodes[0].Kind = "pipe"
	d.Nodes[0].PointID = ""
	d.Nodes[0].Arrow = true
	d.Nodes[0].Points = []process.Position{{X: 10, Y: 10}, {X: 110, Y: 10}}
	d.Nodes[0].ArrowVisibleRule = &process.ArrowRule{Match: "all", Conditions: []process.ArrowCondition{{Slot: "a", PointID: "", Operator: ">", Value: &v}}}
	d, e := s.Screens.Save(d)
	if e != nil {
		t.Fatalf("invalid fixture: %v", e)
	}
	r := Request{Bundle: Bundle{Format: Format, Version: 1, Bindings: []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "arrow_visible_rule", Operation: "clear"})}}, ScreenTargets: map[string]Target{"s": {ID: d.ID, Mode: "update", Revision: raw(d.Revision)}}}
	p, e := s.Preview(context.Background(), r)
	if e != nil || len(p.Remaining) > 0 {
		t.Fatalf("%v %+v", e, p)
	}
	r.PreviewToken = p.PreviewToken
	_, e = s.Commit(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	d, _ = s.Screens.Get(d.ID)
	if d.Nodes[0].ArrowVisibleRule == nil {
		t.Fatal("clear deleted rule")
	}
	changed := cloneRule(d.Nodes[0].ArrowVisibleRule)
	newValue := 2.0
	changed.Conditions[0].Value = &newValue
	r.Bundle.Bindings = []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "arrow_visible_rule", Operation: "set", Rule: changed})}
	r.ScreenTargets["s"] = Target{ID: d.ID, Mode: "update", Revision: raw(d.Revision)}
	p, e = s.Preview(context.Background(), r)
	if e != nil || len(p.Remaining) == 0 {
		t.Fatal("changed condition accepted")
	}
}
func TestSharedInstanceCrossStationBindingAndConflict(t *testing.T) {
	s := setup(t)
	p, e := s.Points.Create(points.CreateInput{Station: "Other", Name: "cross", DataType: "FLOAT", SourceType: "manual"})
	if e != nil {
		t.Fatal(e)
	}
	d := screen()
	d.ID = "public"
	d.Station = ""
	d.Nodes[0].PointID = ""
	label := d.Nodes[0]
	label.ID = "label"
	label.Kind = "text"
	d.Nodes = append(d.Nodes, label)
	var imageBytes bytes.Buffer
	_ = png.Encode(&imageBytes, image.NewRGBA(image.Rect(0, 0, 2, 2)))
	d.Assets["asset"] = process.Asset{Name: "test.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(imageBytes.Bytes())}
	photo := label
	photo.ID = "photo"
	photo.Kind = "image"
	photo.Image = "asset"
	d.Nodes = append(d.Nodes, photo)
	d, e = s.Screens.Save(d)
	if e != nil {
		t.Fatal(e)
	}
	instance := process.Document{SchemaVersion: 1, ID: "instance", Name: "instance", Station: "A", Width: 800, Height: 600, TemplateID: d.ID, TemplateRevision: d.Revision, Bindings: map[string]process.ElementBinding{}}
	instance, e = s.Screens.SaveWithPoints(instance, nil)
	if e != nil {
		t.Fatal(e)
	}
	r := Request{Bundle: Bundle{Format: Format, Version: 1, Bindings: []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "point_id", Operation: "set", VariableKey: "v"})}}, ScreenTargets: map[string]Target{"s": {ID: instance.ID, Mode: "update", Revision: raw(instance.Revision)}}, VariableTargets: map[string]Target{"v": {ID: p.ID, Mode: "reference"}}}
	pre, e := s.Preview(context.Background(), r)
	if e != nil || len(pre.Remaining) > 0 {
		t.Fatalf("preview %v %+v", e, pre)
	}
	r.PreviewToken = pre.PreviewToken
	c, e := s.Commit(context.Background(), r)
	if e != nil || len(c.Remaining) > 0 {
		t.Fatalf("commit %v %+v", e, c)
	}
	got, _ := s.Screens.Get(instance.ID)
	if got.Nodes[0].PointID != p.ID || s.Points.List()[0].Station != "Other" {
		t.Fatal("cross station reference lost or ownership moved")
	}
	r.ScreenTargets["s"] = Target{ID: instance.ID, Mode: "update", Revision: raw(int64(1))}
	r.Bundle.Bindings = []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "point_id", Operation: "clear"})}
	pre, e = s.Preview(context.Background(), r)
	if e != nil || len(pre.Remaining) == 0 {
		t.Fatal("old revision accepted")
	}
}
func TestExportImportRoundTrip(t *testing.T) {
	s := setup(t)
	r := request()
	p, _ := s.Preview(context.Background(), r)
	r.PreviewToken = p.PreviewToken
	if _, e := s.Commit(context.Background(), r); e != nil {
		t.Fatal(e)
	}
	list, _ := s.Screens.ListAll()
	bundle, e := s.Export(context.Background(), ExportRequest{ScreenIDs: []string{list[0].ID}, Kind: "bundle"})
	if e != nil {
		t.Fatal(e)
	}
	for _, format := range []string{"json", "xlsx"} {
		t.Run(format, func(t *testing.T) {
			data, e := Encode(bundle, format, "bundle")
			if e != nil {
				t.Fatal(e)
			}
			b, e := Decode(data, format, "")
			if e != nil {
				t.Fatal(e)
			}
			target := setup(t)
			req := Request{Bundle: b, StationMap: map[string]string{"A": "B"}, ScreenTargets: map[string]Target{}, VariableTargets: map[string]Target{}}
			for _, raw := range b.Screens {
				req.ScreenTargets[rowKey(raw)] = Target{Mode: "create"}
			}
			for _, raw := range b.Variables {
				req.VariableTargets[rowKey(raw)] = Target{Mode: "create"}
			}
			pre, e := target.Preview(context.Background(), req)
			if e != nil || len(pre.Remaining) > 0 {
				t.Fatalf("preview %v %+v", e, pre)
			}
			req.PreviewToken = pre.PreviewToken
			result, e := target.Commit(context.Background(), req)
			if e != nil || len(result.Remaining) > 0 {
				t.Fatalf("commit %v %+v", e, result)
			}
			screens, _ := target.Screens.ListAll()
			d, _ := target.Screens.Get(screens[0].ID)
			if d.Station != "B" || d.Nodes[0].PointID == "" || d.Nodes[0].X != 10 {
				t.Fatal("roundtrip corrupted layout/bindings")
			}
		})
	}
}
func TestSourceTypeConflictAndBlankOperation(t *testing.T) {
	s := setup(t)
	p, e := s.Points.Create(points.CreateInput{Station: "A", Name: "old", DataType: "FLOAT", SourceType: "mqtt", SourceID: "src", Topic: "t", SourcePath: "p"})
	if e != nil {
		t.Fatal(e)
	}
	s.Sources = func() []map[string]string { return []map[string]string{{"id": "src", "name": "source"}} }
	r := Request{Bundle: Bundle{Format: Format, Version: 1, Variables: []json.RawMessage{raw(Variable{"v", points.CreateInput{Station: "A", Name: "renamed", DataType: "BOOL", SourceType: "mqtt", SourceID: "alias", Topic: "t", SourcePath: "p"}})}}, StationMap: map[string]string{"A": "A"}, SourceMap: map[string]string{"alias": "src"}}
	pre, e := s.Preview(context.Background(), r)
	if e != nil || len(pre.Remaining) == 0 {
		t.Fatal("source type mismatch silently referenced")
	}
	d := screen()
	d.Nodes[0].PointID = p.ID
	d, e = s.Screens.Save(d)
	if e != nil {
		t.Fatal(e)
	}
	r = Request{Bundle: Bundle{Format: Format, Version: 1, Bindings: []json.RawMessage{raw(Binding{ScreenKey: "s", NodeID: "n", Property: "point_id"})}}, ScreenTargets: map[string]Target{"s": {ID: d.ID, Mode: "update", Revision: raw(d.Revision)}}}
	pre, e = s.Preview(context.Background(), r)
	if e != nil || len(pre.Remaining) > 0 {
		t.Fatal(e, pre)
	}
	r.PreviewToken = pre.PreviewToken
	if _, e = s.Commit(context.Background(), r); e != nil {
		t.Fatal(e)
	}
	d, _ = s.Screens.Get(d.ID)
	if d.Nodes[0].PointID != p.ID {
		t.Fatal("blank operation cleared")
	}
}

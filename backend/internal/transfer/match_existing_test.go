package transfer

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func matchFixture(t *testing.T) (*Service, Request, points.Definition) {
	t.Helper()
	s := setup(t)
	s.Sources = func() []map[string]string { return []map[string]string{{"id": "actual"}} }
	p, e := s.Points.Create(points.CreateInput{Name: "existing", Station: "owner", SourceType: "mqtt", SourceID: "actual", SourcePath: "KIO.full.path", Topic: "live/topic", DataType: "FLOAT", Unit: "MPa"})
	if e != nil {
		t.Fatal(e)
	}
	r := request()
	r.VariableTargets["v"] = Target{Mode: "match_existing"}
	r.SourceMap = map[string]string{"alias": "actual"}
	r.StationMap = nil
	r.Bundle.Variables = []json.RawMessage{raw(Variable{Key: "v", Definition: points.CreateInput{Name: "different", Station: "archive", SourceType: "mqtt", SourceID: "alias", SourcePath: p.SourcePath, DataType: "FLOAT"}})}
	return s, r, p
}

func TestMatchExistingReferencePreservesConfiguration(t *testing.T) {
	s, r, p := matchFixture(t)
	r.StationMap = map[string]string{"A": "A"}
	before := s.Points.List()
	plan, e := s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) > 0 {
		t.Fatalf("%v %+v", e, plan)
	}
	it := plan.Items[0]
	if it.Status != "unchanged" || len(it.Candidates) != 1 || !it.Candidates[0].Compatible {
		t.Fatalf("%+v", it)
	}
	r.PreviewToken = plan.PreviewToken
	if _, e = s.Commit(context.Background(), r); e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(before, s.Points.List()) {
		t.Fatal("reference changed existing configuration")
	}
	docs, _ := s.Screens.ListAll()
	d, _ := s.Screens.Get(docs[0].ID)
	if d.Nodes[0].PointID != p.ID {
		t.Fatal("not bound to original identity")
	}
	again, e := s.Preview(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	r.PreviewToken = again.PreviewToken
	if _, e = s.Commit(context.Background(), r); e != nil {
		t.Fatal(e)
	}
	next, _ := s.Screens.Get(d.ID)
	if next.Revision != d.Revision {
		t.Fatal("repeat rewrote screen")
	}
}

func TestMatchExistingConflictsAndAmbiguity(t *testing.T) {
	for _, field := range []string{"data_type", "unit", "scale_factor", "offset", "source", "missing", "topic", "ambiguous"} {
		t.Run(field, func(t *testing.T) {
			s, r, p := matchFixture(t)
			r.Bundle.Screens = nil
			r.Bundle.Bindings = nil
			var v Variable
			json.Unmarshal(r.Bundle.Variables[0], &v)
			switch field {
			case "data_type":
				v.Definition.DataType = "INT"
			case "unit":
				v.Definition.Unit = "bar"
			case "scale_factor":
				x := 2.0
				v.Definition.ScaleFactor = &x
			case "offset":
				v.Definition.Offset = 3
			case "source":
				r.SourceMap["alias"] = "absent"
			case "missing":
				v.Definition.SourcePath = "KIO.missing"
			case "topic":
				v.Definition.Topic = "wrong/topic"
			case "ambiguous":
				_, e := s.Points.Create(points.CreateInput{Name: "second", Station: p.Station, SourceType: "mqtt", SourceID: p.SourceID, SourcePath: p.SourcePath, Topic: "another/topic", DataType: p.DataType})
				if e != nil {
					t.Fatal(e)
				}
			}
			r.Bundle.Variables[0] = raw(v)
			plan, e := s.Preview(context.Background(), r)
			if e != nil || len(plan.Remaining) != 1 || plan.Items[0].Status != "unresolved" {
				t.Fatalf("%v %+v", e, plan)
			}
		})
	}
}

func TestMatchExistingUnknownConversionAndPermission(t *testing.T) {
	s, r, p := matchFixture(t)
	r.Bundle.Screens = nil
	r.Bundle.Bindings = nil
	// Omitted conversion fields are unknown rather than defaults from CreateInput.
	r.Bundle.Variables = []json.RawMessage{raw(map[string]any{"key": "v", "definition": map[string]any{"source_type": "mqtt", "source_id": "alias", "source_path": p.SourcePath, "data_type": "FLOAT"}})}
	x := 2.0
	updated, e := s.Points.Update(p.ID, points.CreateInput{Name: p.Name, Station: p.Station, DataType: p.DataType, SourceType: p.SourceType, SourceID: p.SourceID, SourcePath: p.SourcePath, Topic: p.Topic, Unit: p.Unit, ScaleFactor: &x, Offset: 7})
	if e != nil {
		t.Fatal(e)
	}
	plan, e := s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) > 0 {
		t.Fatalf("%v %+v", e, plan)
	}
	// Matching helper must not expose inaccessible candidates even to its caller.
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return true }, StationID: func(string) string { return "denied" }})
	var v Variable
	json.Unmarshal(r.Bundle.Variables[0], &v)
	it, id := s.matchExisting(ctx, v, r.SourceMap, []points.Definition{updated}, map[string]bool{"actual": true}, false)
	if id != "" || len(it.Candidates) != 0 || it.After != nil {
		t.Fatalf("permission leak %+v", it)
	}
	if _, e = s.Preview(ctx, r); e == nil {
		t.Fatal("non-engineer bypass")
	}
	visible := updated
	visible.ID = "visible"
	visible.Station = "allowed"
	ctx = authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return true }, Grants: authorization.Grants{StationIDs: []string{"allowed"}}, StationID: func(name string) string { return name }})
	it, id = s.matchExisting(ctx, v, r.SourceMap, []points.Definition{updated, visible}, map[string]bool{"actual": true}, false)
	if id != "" || len(it.Candidates) != 1 || it.Candidates[0].Definition.ID != "visible" {
		t.Fatalf("hidden match created false uniqueness %+v", it)
	}
}

func TestMatchExistingPreviewChangeRejected(t *testing.T) {
	s, r, p := matchFixture(t)
	r.Bundle.Screens = nil
	r.Bundle.Bindings = nil
	plan, e := s.Preview(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	r.PreviewToken = plan.PreviewToken
	_, e = s.Points.Update(p.ID, points.CreateInput{Name: "changed metadata", Station: p.Station, DataType: p.DataType, SourceType: p.SourceType, SourceID: p.SourceID, SourcePath: p.SourcePath, Topic: p.Topic})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Commit(context.Background(), r); e == nil {
		t.Fatal("stale candidate token accepted")
	}
}

func TestMatchExistingExplicitTopicAndLegacyAuto(t *testing.T) {
	s, r, p := matchFixture(t)
	r.Bundle.Screens = nil
	r.Bundle.Bindings = nil
	_, e := s.Points.Create(points.CreateInput{Name: "same path different topic", Station: p.Station, SourceType: "mqtt", SourceID: p.SourceID, SourcePath: p.SourcePath, Topic: "different", DataType: p.DataType})
	if e != nil {
		t.Fatal(e)
	}
	var v Variable
	_ = json.Unmarshal(r.Bundle.Variables[0], &v)
	v.Definition.Topic = p.Topic
	r.Bundle.Variables[0] = raw(v)
	plan, e := s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) > 0 || len(plan.Items[0].Candidates) != 1 {
		t.Fatalf("explicit topic %v %+v", e, plan)
	}
	// The pre-existing auto mode must still reject an incomplete topic identity.
	v.Definition.Topic = ""
	r.Bundle.Variables[0] = raw(v)
	delete(r.VariableTargets, "v")
	r.StationMap = map[string]string{"archive": "archive"}
	plan, e = s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) != 1 || plan.Items[0].Status != "unresolved" {
		t.Fatalf("legacy auto broadened %v %+v", e, plan)
	}
}

func TestMatchExistingDeliveredPackage623Variables(t *testing.T) {
	matchDeliveredPackage623(t, filepath.Join("..", "..", "..", "outputs", "process-kingio-bound-20261029", "import-request.json"))
}
func TestScanExistingStepByStepPackage623Variables(t *testing.T) {
	matchDeliveredPackage623(t, filepath.Join("..", "..", "..", "outputs", "process-step-by-step-20261029", "扫描变量后导入工艺.json"))
}
func matchDeliveredPackage623(t *testing.T, path string) {
	data, e := os.ReadFile(path)
	if os.IsNotExist(e) {
		t.Skip("optional delivered package absent")
	}
	if e != nil {
		t.Fatal(e)
	}
	var r Request
	if e = json.Unmarshal(data, &r); e != nil {
		t.Fatal(e)
	}
	if r.Bundle.Format == "" {
		var wrapper struct {
			RetryRequest Request `json:"retry_request"`
		}
		if e = json.Unmarshal(data, &wrapper); e != nil {
			t.Fatal(e)
		}
		r = wrapper.RetryRequest
	}
	rawBundle, _ := json.Marshal(r.Bundle)
	decoded, err := Decode(rawBundle, "json", "")
	if err != nil {
		t.Fatal("production Decode", err)
	}
	if len(decoded.Variables) != 385 || len(decoded.Screens) != 28 || len(decoded.Bindings) != 912 {
		t.Fatal("delivered dimensions changed")
	}
	r.Bundle = decoded
	s := setup(t)
	s.Sources = func() []map[string]string { return []map[string]string{{"id": "scanned"}} }
	r.SourceMap = map[string]string{"kingio-original": "scanned"}
	r.CreateStations = nil
	var inputs []points.CreateInput
	for _, raw := range r.Bundle.Variables {
		var v Variable
		if e = json.Unmarshal(raw, &v); e != nil {
			t.Fatal(e)
		}
		in := v.Definition
		in.SourceID = "scanned"
		in.Topic = "KingIO/scanned"
		in.Station = "existing-owner"
		inputs = append(inputs, in)
		r.VariableTargets[v.Key] = Target{Mode: "match_existing"}
	}
	if len(inputs) != 385 {
		t.Fatalf("expected385 got%d", len(inputs))
	}
	for len(inputs) < 623 {
		i := len(inputs)
		inputs = append(inputs, points.CreateInput{Name: fmt.Sprint("unrelated", i), Station: "other-owner", DataType: "FLOAT", SourceType: "mqtt", SourceID: "scanned", SourcePath: fmt.Sprint("unrelated.", i), Topic: "KingIO/scanned"})
	}
	originals, e := s.Points.CreateBatch(inputs)
	if e != nil {
		t.Fatal(e)
	}
	plan, e := s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) > 0 {
		t.Fatalf("preview %v %+v", e, plan.Remaining)
	}
	r.PreviewToken = plan.PreviewToken
	result, e := s.Commit(context.Background(), r)
	if e != nil || len(result.Remaining) > 0 {
		t.Fatalf("commit %v %+v", e, result.Remaining)
	}
	if !reflect.DeepEqual(originals, s.Points.List()) {
		t.Fatal("623 existing variables changed")
	}
	ids := map[string]bool{}
	for _, p := range originals {
		ids[p.ID] = true
	}
	docs, e := s.Screens.ListAll()
	if e != nil || len(docs) != 28 {
		t.Fatalf("screens %d %v", len(docs), e)
	}
	count := 0
	revs := map[string]int64{}
	for _, summary := range docs {
		d, _ := s.Screens.Get(summary.ID)
		revs[d.ID] = d.Revision
		for _, n := range d.Nodes {
			if n.PointID != "" {
				count++
				if !ids[n.PointID] {
					t.Fatal("binding created identity")
				}
			}
		}
	}
	if count != 471 {
		t.Fatalf("bindings%d", count)
	}
	plan, e = s.Preview(context.Background(), r)
	if e != nil || len(plan.Remaining) > 0 {
		t.Fatalf("repeat preview %v %+v", e, plan.Remaining)
	}
	r.PreviewToken = plan.PreviewToken
	if _, e = s.Commit(context.Background(), r); e != nil {
		t.Fatal(e)
	}
	for _, summary := range docs {
		d, _ := s.Screens.Get(summary.ID)
		if d.Revision != revs[d.ID] {
			t.Fatal("repeat changed screen")
		}
	}
	if !reflect.DeepEqual(originals, s.Points.List()) {
		t.Fatal("repeat changed variable configurations")
	}
}

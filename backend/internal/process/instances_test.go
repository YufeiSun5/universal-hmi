package process

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSharedLayoutBindingsRevisionAndDelete(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	template := document()
	template.ID = "public"
	template.Station = ""
	template.Nodes = []Node{element("value", "value")}
	template, err = s.Save(template)
	if err != nil {
		t.Fatal(err)
	}
	lookup := func(id string) (string, bool) {
		return map[string]string{"pa": "A", "pb": "B"}[id], id == "pa" || id == "pb"
	}
	instances := []Document{}
	for _, station := range []string{"A", "B"} {
		id := "pa"
		if station == "B" {
			id = "pb"
		}
		d := document()
		d.ID = station
		d.Station = station
		d.TemplateID = template.ID
		d.TemplateRevision = template.Revision
		d.Nodes = []Node{}
		d.Bindings = map[string]ElementBinding{"value": {PointID: id}}
		saved, e := s.SaveWithPoints(d, lookup)
		if e != nil {
			t.Fatal(e)
		}
		instances = append(instances, saved)
	}
	wrong := instances[0]
	wrong.Bindings = map[string]ElementBinding{"value": {PointID: "pb"}}
	if _, e := s.SaveWithPoints(wrong, lookup); !errors.Is(e, ErrInvalid) {
		t.Fatal("cross station accepted", e)
	}
	template.Nodes[0].X += 20
	template, err = s.Save(template)
	if err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{"A", "B"} {
		d, e := s.Get(id)
		if e != nil || d.Nodes[0].X != template.Nodes[0].X || d.Nodes[0].PointID != instances[i].Nodes[0].PointID || d.TemplateRevision != 2 {
			t.Fatal(d, e)
		}
	}
	if _, e := s.SaveWithPoints(instances[0], lookup); !errors.Is(e, ErrConflict) {
		t.Fatal("stale template accepted", e)
	}
	if e := s.Delete("public", 2); !errors.Is(e, ErrInUse) {
		t.Fatal("used public deleted", e)
	}
	b, e := os.ReadFile(filepath.Join(dir, "A.json"))
	if e != nil {
		t.Fatal(e)
	}
	var stored Document
	if e = json.Unmarshal(b, &stored); e != nil || len(stored.Nodes) != 0 || len(stored.Assets) != 0 {
		t.Fatal("layout copied", e)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	d, e := s.Get("A")
	if e != nil || d.Nodes[0].PointID != "pa" {
		t.Fatal(d, e)
	}
	if e = s.Delete("A", 1); e != nil {
		t.Fatal(e)
	}
	if e = s.Delete("B", 1); e != nil {
		t.Fatal(e)
	}
	if e = s.Delete("public", 2); e != nil {
		t.Fatal(e)
	}
}

func TestSharedConditionMeaningAndOrder(t *testing.T) {
	a, b := 1.0, 2.0
	rule := &ArrowRule{Match: "all", Conditions: []ArrowCondition{{Slot: "温度", Operator: ">", Value: &a}, {Slot: "压力", Operator: "<", Value: &b}}}
	bindings := []ArrowCondition{{Slot: "压力", Operator: "<", Value: &b, PointID: "pressure"}, {Slot: "温度", Operator: ">", Value: &a, PointID: "temperature"}}
	r := boundRule(rule, bindings)
	if r.Conditions[0].PointID != "temperature" || r.Conditions[1].PointID != "pressure" {
		t.Fatal(r)
	}
	rule.Conditions[0].Value = &b
	r = boundRule(rule, bindings)
	if r.Conditions[0].PointID != "" || r.Conditions[1].PointID != "pressure" {
		t.Fatal("changed comparison retained binding", r)
	}
}

// Run from backend/.local: validates the deliverable against an isolated exact export.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"github.com/YufeiSun5/universal-hmi/backend/internal/transfer"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

type stationStore struct{ data []byte }

func (s *stationStore) LoadConfig(_ string, v any) error {
	if s.data == nil {
		return nil
	}
	return json.Unmarshal(s.data, v)
}
func (s *stationStore) SaveConfig(_ string, v any) error {
	b, e := json.Marshal(v)
	s.data = b
	return e
}
func must(e error) {
	if e != nil {
		panic(e)
	}
}
func read(p string, v any) { b, e := os.ReadFile(p); must(e); must(json.Unmarshal(b, v)) }
func main() {
	root := os.Args[1]
	var original transfer.Bundle
	read("D:/Users/SunYufei/Downloads/process-bundle.json", &original)
	tmp, e := os.MkdirTemp("", "process-complete-1105-")
	must(e)
	defer os.RemoveAll(tmp)
	defs := []points.Definition{}
	lookup := map[string]points.Definition{}
	for _, raw := range original.Variables {
		var v struct {
			Key        string
			Definition points.Definition
		}
		must(json.Unmarshal(raw, &v))
		v.Definition.ID = strings.TrimPrefix(v.Key, "var_")
		defs = append(defs, v.Definition)
		lookup[v.Definition.ID] = v.Definition
	}
	b, e := json.Marshal(defs)
	must(e)
	must(os.WriteFile(filepath.Join(tmp, "points.json"), b, 0600))
	ps, e := points.Open(filepath.Join(tmp, "points.json"))
	must(e)
	ss, e := process.Open(filepath.Join(tmp, "screens"))
	must(e)
	binds := map[string]string{}
	for _, raw := range original.Bindings {
		var v transfer.Binding
		must(json.Unmarshal(raw, &v))
		if v.Property != "point_id" || v.Operation != "set" {
			panic("unexpected original binding")
		}
		binds[v.ScreenKey+"/"+v.NodeID] = strings.TrimPrefix(v.VariableKey, "var_")
	}
	before := map[string]process.Document{}
	for _, raw := range original.Screens {
		var s transfer.Screen
		must(json.Unmarshal(raw, &s))
		d := s.Document
		d.ID = strings.TrimPrefix(s.Key, "screen_")
		for i, n := range d.Nodes {
			d.Nodes[i].PointID = binds[s.Key+"/"+n.ID]
		}
		saved, e := ss.SaveAuthorizedPoints(d, func(id string) (string, bool) { p, ok := lookup[id]; return p.Station, ok })
		must(e)
		before[saved.ID] = saved
	}
	svc := transfer.New(ps, ss)
	svc.Sources = func() []map[string]string { return []map[string]string{{"id": "source-1793013239860"}} }
	svc.Stations = stations.New(&stationStore{}, func() ([]string, error) {
		names := []string{}
		for _, d := range before {
			names = append(names, d.Station)
		}
		for _, p := range ps.List() {
			names = append(names, p.Station)
		}
		return names, nil
	})
	var w struct {
		Request transfer.Request `json:"retry_request"`
	}
	read(filepath.Join(root, "outputs/工艺图完整导入-20261105/01-完整31张工艺图与绑定.json"), &w)
	var expected []struct {
		ScreenID      string `json:"screen_id"`
		Name          string
		TargetStation string `json:"target_station"`
		Existing      bool
		Key           string
	}
	read(filepath.Join(root, "outputs/工艺图完整导入-20261105/核验资料/画面引用核对.json"), &expected)
	initial := ps.List()
	commit := func() {
		p, e := svc.Preview(context.Background(), w.Request)
		must(e)
		if len(p.Remaining) > 0 {
			panic(fmt.Sprintf("preview: %+v", p.Remaining))
		}
		r := w.Request
		r.PreviewToken = p.PreviewToken
		result, e := svc.Commit(context.Background(), r)
		must(e)
		if len(result.Remaining) > 0 {
			panic(fmt.Sprintf("commit: %+v", result.Remaining))
		}
	}
	commit()
	list, e := ss.ListAll()
	must(e)
	if len(list) != 31 {
		panic("screen count")
	}
	if !reflect.DeepEqual(initial, ps.List()) {
		panic("variables changed")
	}
	wanted := map[string]string{}
	for _, raw := range w.Request.Bundle.Bindings {
		var b transfer.Binding
		must(json.Unmarshal(raw, &b))
		if b.Operation == "set" {
			wanted[b.ScreenKey+"/"+b.NodeID] = strings.TrimPrefix(b.VariableKey, "var_")
		}
	}
	after := map[string]process.Document{}
	bound, blank, unchanged, changedRefs := 0, 0, 0, 0
	for _, r := range expected {
		d, e := ss.Get(r.ScreenID)
		must(e)
		if d.Name != r.Name || d.Station != r.TargetStation {
			panic("identity changed")
		}
		after[d.ID] = d
		for _, n := range d.Nodes {
			if n.Kind == "value" {
				if n.PointID != wanted[r.Key+"/"+n.ID] {
					panic("incorrect binding")
				}
				if n.PointID == "" {
					blank++
				} else {
					bound++
				}
			}
		}
		if old, ok := before[d.ID]; ok {
			if reflect.DeepEqual(old, d) {
				unchanged++
			} else {
				if d.Name != "张屯换热站 · 工艺" {
					panic("unexpected existing change: " + d.Name)
				}
				compare := d
				compare.Revision = old.Revision
				compare.Nodes = append([]process.Node(nil), d.Nodes...)
				for i, n := range compare.Nodes {
					if n.PointID != old.Nodes[i].PointID {
						changedRefs++
					}
					compare.Nodes[i].PointID = old.Nodes[i].PointID
				}
				if !reflect.DeepEqual(compare, old) {
					panic("layout or metadata changed")
				}
			}
		}
	}
	if bound != 901 || blank != 2 || unchanged != 27 || changedRefs != 4 {
		panic(fmt.Sprintf("coverage %d/%d/%d/%d", bound, blank, unchanged, changedRefs))
	}
	commit()
	list, e = ss.ListAll()
	must(e)
	if len(list) != 31 {
		panic("repeat duplicate")
	}
	for _, m := range list {
		d, e := ss.Get(m.ID)
		must(e)
		if !reflect.DeepEqual(after[d.ID], d) {
			panic("repeat mutation")
		}
	}
	if !reflect.DeepEqual(initial, ps.List()) {
		panic("repeat variable mutation")
	}
	report := map[string]any{"status": "passed", "isolated_preview_commit_repeat": true, "existing_ids_preserved": 28, "screens_added": 3, "screens_after": 31, "unchanged_existing_documents": 27, "changed_zhangtun_bindings": 4, "variables_unchanged": len(initial), "bound_readings": bound, "blank_readings": blank, "onsite_applied": false}
	b, e = json.MarshalIndent(report, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(root, "outputs/工艺图完整导入-20261105/核验资料/验证记录.json"), b, 0600))
	fmt.Println(string(b))
}

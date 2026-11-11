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
	tmp, e := os.MkdirTemp("", "process-state-1105-")
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

	loadRequest := func(path string) transfer.Request {
		var w struct {
			Request transfer.Request `json:"retry_request"`
		}
		read(filepath.Join(root, path), &w)
		return w.Request
	}
	baseline := loadRequest("outputs/工艺图完整导入-20261105/01-完整31张工艺图与绑定.json")
	update := loadRequest("outputs/工艺状态液位更新-20261105/01-31张工艺图状态液位更新.json")
	rollback := loadRequest("outputs/工艺状态液位更新-20261105/回退/恢复更新前31张工艺图.json")
	initial := ps.List()
	commit := func(r transfer.Request) {
		p, e := svc.Preview(context.Background(), r)
		must(e)
		if len(p.Remaining) > 0 {
			panic(fmt.Sprintf("preview: %d remaining; %s: %s", len(p.Remaining), p.Remaining[0].Key, p.Remaining[0].Message))
		}
		r.PreviewToken = p.PreviewToken
		result, e := svc.Commit(context.Background(), r)
		must(e)
		if len(result.Remaining) > 0 {
			panic(fmt.Sprintf("commit: %d remaining", len(result.Remaining)))
		}
	}
	snapshot := func() map[string]process.Document {
		result := map[string]process.Document{}
		list, e := ss.ListAll()
		must(e)
		if len(list) != 31 {
			panic("screen count")
		}
		for _, s := range list {
			d, e := ss.Get(s.ID)
			must(e)
			result[d.ID] = d
		}
		return result
	}
	commit(baseline)
	base := snapshot()
	commit(update)
	after := snapshot()
	lamps, levels, unchangedReadings, removed := 0, 0, 0, 0
	for id, d := range after {
		old := base[id]
		prior := map[string]process.Node{}
		for _, n := range old.Nodes {
			prior[n.ID] = n
		}
		for _, n := range d.Nodes {
			a, exists := prior[n.ID]
			delete(prior, n.ID)
			if !exists {
				if n.Kind == "level" {
					a = prior[strings.TrimPrefix(n.ID, "level-")]
					delete(prior, a.ID)
					if a.Kind != "rect" || !strings.HasPrefix(n.ID, "level-ks-Rect63-") || *n.LevelDisplay.Minimum != 0 || *n.LevelDisplay.Maximum != 3 || n.Width != 8 || n.X != a.X || n.Y != a.Y || n.Height != a.Height {
						panic("invalid level conversion")
					}
					if !strings.Contains(lookup[n.PointID].SourcePath, "水位") {
						panic("wrong water source")
					}
					levels++
					continue
				}
				if n.Kind != "ellipse" || n.StateDisplay == nil || !strings.HasPrefix(n.ID, "state-") || lookup[n.PointID].DataType != "BOOL" {
					panic("unexpected new node")
				}
				lamps++
				continue
			}

			if !reflect.DeepEqual(a, n) {
				panic("existing node mutated: " + d.Name + "/" + n.ID)
			}
			if n.Kind == "value" {
				unchangedReadings++
			}
		}
		for _, n := range prior {
			if n.Kind != "ellipse" || n.PointID != "" || n.Label != "状态灯（无实时状态）" {
				panic("removed real content")
			}
			removed++
		}
		d.Nodes = old.Nodes
		d.Revision = old.Revision
		if !reflect.DeepEqual(d, old) {
			panic("document identity/metadata changed")
		}
	}
	if lamps != 81 || levels != 31 || unchangedReadings != 903 || removed != 62 {
		panic(fmt.Sprintf("coverage %d/%d/%d/%d", lamps, levels, unchangedReadings, removed))
	}
	commit(update)
	if !reflect.DeepEqual(after, snapshot()) {
		panic("repeat import mutated state")
	}
	if !reflect.DeepEqual(initial, ps.List()) {
		panic("variables changed")
	}
	commit(rollback)
	restored := snapshot()
	for id, d := range restored {
		old := base[id]
		d.Revision = old.Revision
		if !reflect.DeepEqual(d, old) {
			panic("rollback failed")
		}
	}
	if !reflect.DeepEqual(initial, ps.List()) {
		panic("rollback variables changed")
	}
	report := map[string]any{"status": "passed", "baseline_then_update_repeat_rollback": true, "screens": 31, "lamps": lamps, "levels": levels, "original_readings_unchanged": unchangedReadings, "replaced_unbound_model_lamps": removed, "variables_unchanged": len(initial), "onsite_applied": false}
	b, e = json.MarshalIndent(report, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(root, "outputs/工艺状态液位更新-20261105/核对资料/验证记录.json"), b, 0600))
	fmt.Println(string(b))
}

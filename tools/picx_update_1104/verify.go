// Copy into backend/.local before running: public service verification in a temporary project.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/transfer"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func read(path string, v any) {
	data, err := os.ReadFile(path)
	must(err)
	must(json.Unmarshal(data, v))
}
func request(path string) transfer.Request {
	var wrapper struct {
		Request transfer.Request `json:"retry_request"`
	}
	read(path, &wrapper)
	return wrapper.Request
}
func commit(service *transfer.Service, r transfer.Request) {
	p, err := service.Preview(context.Background(), r)
	must(err)
	if len(p.Remaining) != 0 {
		panic(fmt.Sprintf("preview unresolved: %+v", p.Remaining[:1]))
	}
	r.PreviewToken = p.PreviewToken
	result, err := service.Commit(context.Background(), r)
	must(err)
	if len(result.Remaining) != 0 {
		panic(fmt.Sprintf("commit unresolved: %+v", result.Remaining))
	}
}
func main() {
	root := os.Args[1]
	var snapshot struct {
		Variables []struct {
			Key        string
			Definition points.Definition
		}
	}
	read("D:/Users/SunYufei/Downloads/process-variables.json", &snapshot)
	var initial []points.Definition
	for _, v := range snapshot.Variables {
		d := v.Definition
		d.ID = strings.TrimPrefix(v.Key, "var_")
		initial = append(initial, d)
	}
	tmp, err := os.MkdirTemp("", "hmi1104-verify-")
	must(err)
	defer os.RemoveAll(tmp)
	data, err := json.Marshal(initial)
	must(err)
	must(os.WriteFile(filepath.Join(tmp, "points.json"), data, 0600))
	ps, err := points.Open(filepath.Join(tmp, "points.json"))
	must(err)
	ss, err := process.Open(filepath.Join(tmp, "screens"))
	must(err)
	svc := transfer.New(ps, ss)
	svc.Sources = func() []map[string]string { return []map[string]string{{"id": "source-1793013239860"}} }
	base := filepath.Join(root, "outputs/现场导入-1103n")
	catchup := len(os.Args) > 2 && os.Args[2] == "catchup"
	if catchup {
		prior := filepath.Join(root, "outputs/现场导入-1103-KS-KIO/现场5082变量核对版")
		for _, pattern := range []string{"第1步*.json", "第2步*.json"} {
			matches, err := filepath.Glob(filepath.Join(prior, pattern))
			must(err)
			if len(matches) != 1 {
				panic("ambiguous older baseline")
			}
			commit(svc, request(matches[0]))
		}
		commit(svc, request(filepath.Join(root, "outputs/庄河1104更新包/补充资料-未更新1103n时使用/先补齐1103n的73个候选变量.json")))
	} else {
		commit(svc, request(filepath.Join(base, "完整资料/01-全量变量匹配与补齐.json")))
		commit(svc, request(filepath.Join(base, "完整资料/02-全部工艺图与绑定.json")))
	}
	beforePoints := ps.List()
	oldMeta, err := ss.ListAll()
	must(err)
	oldDocs := map[string]process.Document{}
	for _, m := range oldMeta {
		d, err := ss.Get(m.ID)
		must(err)
		oldDocs[m.ID] = d
	}
	if len(oldDocs) != 31 {
		panic("wrong baseline screen count")
	}
	delta := request(filepath.Join(root, "outputs/庄河1104更新包/01-工艺画面增量更新.json"))
	full := request(filepath.Join(root, ".local/update-1104/full-request.json"))
	if catchup {
		delta = full
	}
	// Missing imported identity must be reported, never silently created.
	missing := delta
	missing.ImportIdentity = "deliberately-absent-identity"
	p, err := svc.Preview(context.Background(), missing)
	must(err)
	if len(p.Remaining) == 0 {
		panic("missing original screen was not reported")
	}
	commit(svc, delta)
	if !reflect.DeepEqual(beforePoints, ps.List()) {
		panic("update modified point definitions")
	}
	current, err := ss.ListAll()
	must(err)
	if len(current) != 31 {
		panic("update created duplicate screens")
	}
	pointPaths := map[string]string{}
	byID := map[string]points.Definition{}
	for _, d := range ps.List() {
		pointPaths[d.ID] = d.SourcePath
		byID[d.ID] = d
	}
	for _, d := range initial {
		if !reflect.DeepEqual(d, byID[d.ID]) {
			panic("original field point changed: " + d.ID)
		}
	}
	variablePaths := map[string]string{}
	for _, raw := range full.Bundle.Variables {
		var v transfer.Variable
		must(json.Unmarshal(raw, &v))
		variablePaths[v.Key] = v.Definition.SourcePath
	}
	expected := map[string]string{}
	for _, raw := range full.Bundle.Bindings {
		var b transfer.Binding
		must(json.Unmarshal(raw, &b))
		if b.Operation == "set" {
			expected[b.ScreenKey+"/"+b.NodeID] = variablePaths[b.VariableKey]
		}
	}
	updated := map[string]bool{}
	for _, raw := range delta.Bundle.Screens {
		var s transfer.Screen
		must(json.Unmarshal(raw, &s))
		updated[s.Document.Station] = true
	}
	byStation := map[string]process.Document{}
	unchanged := 0
	for _, m := range current {
		d, err := ss.Get(m.ID)
		must(err)
		old, ok := oldDocs[m.ID]
		if !ok {
			panic("changed stable screen identity")
		}
		if !updated[d.Station] {
			if !reflect.DeepEqual(old, d) {
				panic("unselected screen changed")
			}
			unchanged++
		}
		byStation[d.Station] = d
	}
	bound, empty := 0, 0
	for _, raw := range full.Bundle.Screens {
		var wanted transfer.Screen
		must(json.Unmarshal(raw, &wanted))
		actual, ok := byStation[wanted.Document.Station]
		if !ok {
			panic("missing station")
		}
		wanted.Document.ID = actual.ID
		wanted.Document.Revision = actual.Revision
		actualNodes := map[string]process.Node{}
		for _, n := range actual.Nodes {
			actualNodes[n.ID] = n
		}
		for i, n := range wanted.Document.Nodes {
			a, ok := actualNodes[n.ID]
			if !ok {
				panic("missing node")
			}
			if n.Kind == "value" {
				if pointPaths[a.PointID] != expected[wanted.Key+"/"+n.ID] {
					panic("wrong saved KIO path: " + wanted.Document.Station + "/" + n.ID)
				}
				if a.PointID == "" {
					empty++
				} else {
					bound++
				}
			}
			wanted.Document.Nodes[i].PointID = a.PointID
		}
		if !reflect.DeepEqual(wanted.Document, actual) {
			panic("saved content differs from full candidate: " + actual.Station)
		}
	}
	expectedUnchanged := 11
	if catchup {
		expectedUnchanged = 0
	}
	if bound != 901 || empty != 2 || unchanged != expectedUnchanged {
		panic(fmt.Sprintf("wrong coverage: %d/%d/%d", bound, empty, unchanged))
	}
	commit(svc, delta)
	if !reflect.DeepEqual(beforePoints, ps.List()) {
		panic("repeat modified variables")
	}
	repeated, err := ss.ListAll()
	must(err)
	if len(repeated) != 31 {
		panic("repeat duplicated screens")
	}
	for _, m := range repeated {
		d, err := ss.Get(m.ID)
		must(err)
		if !reflect.DeepEqual(d, byStation[d.Station]) {
			panic("repeat changed saved document")
		}
	}
	data, err = json.Marshal(ps.List())
	must(err)
	must(os.WriteFile(filepath.Join(root, ".local/update-1104/verified-points.json"), data, 0600))
	report := map[string]any{"preview_commit_repeat": "passed", "missing_original_identity_blocked": "passed", "unchanged_screens_preserved": unchanged, "stable_screen_ids_preserved": 31, "point_definitions_preserved": len(beforePoints), "original_field_variables_preserved": len(initial), "saved_bound_readings": bound, "saved_blank_readings": empty, "production_connections": false}
	data, err = json.MarshalIndent(report, "", "  ")
	must(err)
	name := "import-verification.json"
	if catchup {
		name = "catchup-verification.json"
	}
	must(os.WriteFile(filepath.Join(root, ".local/update-1104/"+name), data, 0600))
	fmt.Println(string(data))
	if !catchup {
		commit(svc, request(filepath.Join(root, "outputs/庄河1104更新包/回退到1103n/01-工艺图回退.json")))
		rolled, err := ss.ListAll()
		must(err)
		if len(rolled) != 31 {
			panic("rollback changed screen count")
		}
		for _, m := range rolled {
			d, err := ss.Get(m.ID)
			must(err)
			old := oldDocs[m.ID]
			old.Revision = d.Revision
			if !reflect.DeepEqual(old, d) {
				panic("rollback mismatch: " + d.Station)
			}
		}
		if !reflect.DeepEqual(beforePoints, ps.List()) {
			panic("rollback modified point definitions")
		}
		must(os.WriteFile(filepath.Join(root, ".local/update-1104/rollback-verification.json"), []byte(`{"rollback_to_1103n":"passed","stable_screen_ids":31,"point_definitions_preserved":true}`), 0600))
		fmt.Println("rollback: passed")
	}
}

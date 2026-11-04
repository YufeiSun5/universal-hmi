// Stage inside backend/.local to verify delivery through the public domain services.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/transfer"
)

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func bytes(p string) []byte { b, e := os.ReadFile(p); must(e); return b }
func main() {
	dir := os.Args[1]
	var wrapped struct {
		Request transfer.Request `json:"retry_request"`
	}
	must(json.Unmarshal(bytes(filepath.Join(dir, "导入请求-匹配已有变量.json")), &wrapped))
	r := wrapped.Request
	seed := r
	updating := len(os.Args) > 2
	if updating {
		var prior struct {
			Request transfer.Request `json:"retry_request"`
		}
		must(json.Unmarshal(bytes(filepath.Join(os.Args[2], "导入请求-匹配已有变量.json")), &prior))
		seed = prior.Request
	}
	for _, name := range []string{"screens.json", "confirmed-bindings.json"} {
		b, e := transfer.Decode(bytes(filepath.Join(dir, name)), "json", "")
		must(e)
		if len(b.Screens) != 31 {
			panic("wrong screen count")
		}
		for _, raw := range b.Screens {
			var s transfer.Screen
			must(json.Unmarshal(raw, &s))
			must(process.Validate(s.Document))
			if s.Document.Background == nil || s.Document.Background.Color != "#F0F3F5" {
				panic("wrong theme")
			}
			for _, n := range s.Document.Nodes {
				if n.PointID != "" {
					panic("source leaked runtime ID")
				}
			}
		}
	}
	temp, e := os.MkdirTemp("", "pic-refresh-verify-")
	must(e)
	defer os.RemoveAll(temp)
	ps, e := points.Open(filepath.Join(temp, "points.json"))
	must(e)
	sc, e := process.Open(filepath.Join(temp, "screens"))
	must(e)
	service := transfer.New(ps, sc)
	service.Sources = func() []map[string]string { return []map[string]string{{"id": "fixture-source"}} }
	for _, raw := range seed.Bundle.Variables {
		var v transfer.Variable
		must(json.Unmarshal(raw, &v))
		input := v.Definition
		input.Station = "IO-01"
		input.SourceID = "fixture-source"
		input.Topic = "fixture/topic"
		_, e = ps.Create(input)
		must(e)
	}
	before := ps.List()
	r.SourceMap = map[string]string{"kingio-confirmed": "fixture-source"}
	oldIDs := map[string]bool{}
	if updating {
		seed.SourceMap = r.SourceMap
		p, err := service.Preview(context.Background(), seed)
		must(err)
		if len(p.Remaining) != 0 {
			panic("seed preview unresolved")
		}
		seed.PreviewToken = p.PreviewToken
		result, err := service.Commit(context.Background(), seed)
		must(err)
		if len(result.Remaining) != 0 {
			panic("seed commit unresolved")
		}
		old, err := sc.ListAll()
		must(err)
		for _, item := range old {
			oldIDs[item.ID] = true
		}
	}
	plan, e := service.Preview(context.Background(), r)
	must(e)
	if len(plan.Remaining) > 0 {
		b, _ := json.Marshal(plan.Remaining)
		panic(string(b))
	}
	r.PreviewToken = plan.PreviewToken
	result, e := service.Commit(context.Background(), r)
	must(e)
	if len(result.Remaining) > 0 {
		panic("commit had remaining items")
	}
	if !reflect.DeepEqual(before, ps.List()) {
		panic("existing definitions changed")
	}
	list, e := sc.ListAll()
	must(e)
	if len(list) != 31 {
		panic("wrong saved count")
	}
	bound := 0
	for _, meta := range list {
		if updating && !oldIDs[meta.ID] {
			panic("update created a duplicate screen")
		}
		d, e := sc.Get(meta.ID)
		must(e)
		for _, n := range d.Nodes {
			if updating && (n.ID == "extra-title" || n.ID == "source-note" || n.Text == "其他测点") {
				panic("supplementary text survived")
			}
			if n.PointID != "" {
				bound++
			}
		}
	}
	repeat, e := service.Preview(context.Background(), r)
	must(e)
	if len(repeat.Remaining) > 0 {
		panic("repeat unresolved")
	}
	for _, item := range repeat.Items {
		if item.Kind == "screen" && updating {
			if item.Status != "ready" && item.Status != "unchanged" {
				panic("repeat screen not ready")
			}
			continue
		}
		if item.Kind != "binding" && item.Status != "unchanged" {
			panic("repeat changed identity")
		}
	}
	report := map[string]any{"schema_decode": "passed", "screen_validate": "passed", "isolated_preview_commit_repeat": "passed", "screens": len(list), "bindings": bound, "existing_variables_preserved": len(before), "real_source_connected": false}
	if updating {
		report["updated_existing_screen_ids"] = len(oldIDs)
	}
	out, e := json.MarshalIndent(report, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(dir, "import-verification.json"), out, 0600))
	fmt.Println(string(out))
}

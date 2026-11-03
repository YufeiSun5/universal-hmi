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
	for _, raw := range r.Bundle.Variables {
		var v transfer.Variable
		must(json.Unmarshal(raw, &v))
		input := v.Definition
		input.Station = "source-owner"
		input.SourceID = "fixture-source"
		input.Topic = "fixture/topic"
		_, e = ps.Create(input)
		must(e)
	}
	before := ps.List()
	r.SourceMap = map[string]string{"kingio-confirmed": "fixture-source"}
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
		d, e := sc.Get(meta.ID)
		must(e)
		for _, n := range d.Nodes {
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
		if item.Kind != "binding" && item.Status != "unchanged" {
			panic("repeat changed identity")
		}
	}
	report := map[string]any{"schema_decode": "passed", "screen_validate": "passed", "isolated_preview_commit_repeat": "passed", "screens": len(list), "bindings": bound, "existing_variables_preserved": len(before), "real_source_connected": false}
	out, e := json.MarshalIndent(report, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(dir, "import-verification.json"), out, 0600))
	fmt.Println(string(out))
}

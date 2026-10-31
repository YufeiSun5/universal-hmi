// Invoked through process_transfer_finalize.ps1, which stages this review-only
// command inside the Go module so it can use the actual internal transfer codec.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"

	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/transfer"
	"github.com/xuri/excelize/v2"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func read(path string) []byte { b, e := os.ReadFile(path); must(e); return b }
func hash(b []byte) string    { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func canonical(b transfer.Bundle, kind string) []byte {
	groups := [][]json.RawMessage{b.Screens, b.Variables, b.Bindings}
	out := map[string][]string{}
	for i, name := range []string{"screens", "variables", "bindings"} {
		if kind != "bundle" && kind != name {
			continue
		}
		out[name] = []string{}
		for _, r := range groups[i] {
			var v any
			switch i {
			case 0:
				v = &transfer.Screen{}
			case 1:
				v = &transfer.Variable{}
			case 2:
				v = &transfer.Binding{}
			}
			must(json.Unmarshal(r, v))
			raw, e := json.Marshal(v)
			must(e)
			out[name] = append(out[name], string(raw))
		}
		sort.Strings(out[name])
	}
	raw, e := json.Marshal(out)
	must(e)
	return raw
}
func main() {
	if len(os.Args) != 2 {
		panic("usage: finalizer OUTPUT_DIRECTORY")
	}
	dir := os.Args[1]
	workbook := filepath.Join(dir, "现场工艺导入工作簿.xlsx")
	f, e := excelize.OpenFile(workbook)
	must(e)
	before, e := f.GetSheetVisible("_payload")
	must(e)
	tables := map[string][][]string{}
	for _, name := range f.GetSheetList() {
		rows, e := f.GetRows(name, excelize.Options{RawCellValue: true})
		must(e)
		tables[name] = rows
	}
	if before {
		must(f.SetSheetVisible("_payload", false))
		f.SetActiveSheet(0)
		must(f.Save())
	}
	must(f.Close())
	f, e = excelize.OpenFile(workbook)
	must(e)
	defer f.Close()
	visible, e := f.GetSheetVisible("_payload")
	must(e)
	if visible {
		panic("_payload remains visible")
	}
	for name, old := range tables {
		rows, e := f.GetRows(name, excelize.Options{RawCellValue: true})
		must(e)
		if !reflect.DeepEqual(old, rows) {
			panic("worksheet contents changed: " + name)
		}
	}
	for _, name := range []string{"画面", "变量", "绑定", "使用说明"} {
		v, e := f.GetSheetVisible(name)
		must(e)
		if !v {
			panic("reader sheet hidden: " + name)
		}
	}
	base, e := transfer.Decode(read(filepath.Join(dir, "bundle.json")), "json", "")
	must(e)
	for _, r := range base.Screens {
		var s transfer.Screen
		must(json.Unmarshal(r, &s))
		must(process.Validate(s.Document))
	}
	checks := []map[string]any{}
	files := []struct{ name, format, kind string }{{"bundle.json", "json", "bundle"}, {"screens.json", "json", "screens"}, {"variables.json", "json", "variables"}, {"bindings.json", "json", "bindings"}, {"现场工艺导入工作簿.xlsx", "xlsx", "bundle"}, {"画面.csv", "csv", "screens"}, {"变量.csv", "csv", "variables"}, {"绑定.csv", "csv", "bindings"}}
	for _, file := range files {
		data := read(filepath.Join(dir, file.name))
		b, e := transfer.Decode(data, file.format, file.kind)
		must(e)
		actual, expected := canonical(b, file.kind), canonical(base, file.kind)
		if !reflect.DeepEqual(actual, expected) {
			panic("actual transfer.Decode content differs from bundle: " + file.name)
		}
		checks = append(checks, map[string]any{"file": file.name, "passed": true, "sha256": hash(data), "semantic_sha256": hash(actual), "screens": len(b.Screens), "variables": len(b.Variables), "bindings": len(b.Bindings)})
	}
	report := map[string]any{"tool": "tools/process_transfer_finalize.go", "codec": "backend/internal/transfer.Decode", "payload_visible_before": before, "payload_visible_after": visible, "worksheet_values_unchanged": true, "process_validate_screens": len(base.Screens), "checks": checks}
	data, e := json.MarshalIndent(report, "", "  ")
	must(e)
	must(os.WriteFile(filepath.Join(dir, "finalization-verification.json"), append(data, '\n'), 0644))
	fmt.Println(string(data))
}

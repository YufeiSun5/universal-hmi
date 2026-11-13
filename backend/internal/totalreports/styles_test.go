package totalreports

import (
	"bytes"
	"github.com/xuri/excelize/v2"
	"testing"
)

func TestSourceColorsSurviveAnnualSheetAndExport(t *testing.T) {
	s, ctx := fixture(t)
	tpl := testTemplate()
	tpl.Styles = map[string]CellStyle{"h0_3": {BG: "#FFFF00", FG: "#FF0000", Bold: true}, "b3": {BG: "#FFFF00", FG: "#000000"}, "d3": {BG: "#BBD6EC", FG: "#000000"}}
	if e := s.SaveTemplate(ctx, tpl); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, "electricity", 2027)
	if e != nil {
		t.Fatal(e)
	}
	for _, cell := range d.Sheet()["celldata"].([]map[string]any) {
		if cell["c"] == 3 && cell["r"] == 0 {
			v := cell["v"].(map[string]any)
			if v["bg"] != "#FFFF00" || v["fc"] != "#FF0000" {
				t.Fatal(v)
			}
		}
	}
	b, e := s.Export(ctx, "electricity", 2027)
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(b))
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	for a, want := range map[string]string{"D1": "FFFF00", "D3": "FFFF00", "D4": "BBD6EC"} {
		id, e := f.GetCellStyle("总体报表", a)
		if e != nil {
			t.Fatal(e)
		}
		style, e := f.GetStyle(id)
		if e != nil || len(style.Fill.Color) != 1 || style.Fill.Color[0] != want {
			t.Fatal(a, style, e)
		}
	}
	tpl.Styles["d3"] = CellStyle{BG: "url(evil)", FG: "#000000"}
	if e = s.SaveTemplate(ctx, tpl); e == nil {
		t.Fatal("unvalidated style accepted")
	}
}
func TestToolbarFormatSharesCellLeaseRevisionAndRollback(t *testing.T) {
	s, ctx := fixture(t)
	cp, e := s.CreateCheckpoint(ctx, "electricity", 2026, 0)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "format-window", Addresses: []string{"D4"}}); e != nil {
		t.Fatal(e)
	}
	format := CellFormat{"bg": "#123456", "fc": "#FF0000", "bl": float64(1), "fs": float64(14), "ht": float64(2), "nf": "0.00"}
	patch := Patch{ID: "toolbar-format-1", Client: "format-window", Changes: []Change{{Address: "D4", Value: "12.3", Expected: 0, Format: format}}}
	v, e := s.Patch(ctx, "electricity", 2026, patch)
	if e != nil {
		t.Fatal(e)
	}
	delta, e := s.Changes(ctx, "electricity", 2026, 0)
	if e != nil || !sameFormat(delta.Cells[0].Format, format) {
		t.Fatal(delta, e)
	}
	// A value-only client must preserve formatting rather than erase it.
	patch.ID = "toolbar-value-2"
	patch.Changes[0].Expected = v.Revision
	patch.Changes[0].Value = "25"
	patch.Changes[0].Format = nil
	v, e = s.Patch(ctx, "electricity", 2026, patch)
	if e != nil || !sameFormat(v.Cells[0].Format, format) {
		t.Fatal(v, e)
	}
	b, e := s.Export(ctx, "electricity", 2026)
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(b))
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	id, _ := f.GetCellStyle("总体报表", "D4")
	style, e := f.GetStyle(id)
	if e != nil || !style.Font.Bold || style.Font.Color != "FF0000" || style.Fill.Color[0] != "123456" {
		t.Fatal(style, e)
	}
	if _, e = s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "format-window"}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Rollback(ctx, "electricity", 2026, Rollback{ID: "format-rollback", Checkpoint: cp.ID, Expected: v.Revision}); e != nil {
		t.Fatal(e)
	}
	delta, e = s.Changes(ctx, "electricity", 2026, v.Revision)
	if e != nil || len(delta.Cells) != 1 || len(delta.Cells[0].Format) != 0 || delta.Cells[0].Value != "" {
		t.Fatal(delta, e)
	}
}

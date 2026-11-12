package totalreports

import (
	"bytes"
	"github.com/xuri/excelize/v2"
	"testing"
)

func TestSeasonHeaderFitsAndExportKeepsSameLayout(t *testing.T) {
	d := Document{Kind: "heat", Year: 2026, Template: Template{Columns: 5, HeaderRows: 2, Widths: map[string]float64{"3": 40, "4": 40}, Cells: []TemplateCell{{R: 0, C: 3, V: "较长站点名称及设备编号（12345678901234567890）"}}, Merges: []Merge{{R: 0, C: 3, RS: 1, CS: 2}}}}
	w, h := d.seasonalLayout()
	if w["3"] < 100 || h["0"] <= 28 || d.Template.Widths["3"] != 40 {
		t.Fatal("header geometry did not expand or modified frozen template", w, h)
	}
	d.Template.Rows = 20
	w, h = d.seasonalLayout()
	if w["3"] != 40 || len(h) != 0 {
		t.Fatal("standalone original geometry was changed", w, h)
	}
	s, ctx := fixture(t)
	before, err := s.Document(ctx, "electricity", 2026)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Export(ctx, "electricity", 2026)
	if err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	id, _ := f.GetCellStyle("总体报表", "D2")
	style, err := f.GetStyle(id)
	if err != nil || style.Alignment == nil || !style.Alignment.WrapText {
		t.Fatal("exported header does not wrap", style, err)
	}
	width, _ := f.GetColWidth("总体报表", "D")
	height, _ := f.GetRowHeight("总体报表", 2)
	w, h = before.seasonalLayout()
	if width < (w["3"]-5)/7-.01 || height < h["1"]*.75-.01 {
		t.Fatal("export smaller than online geometry", width, height)
	}
	after, err := s.Document(ctx, "electricity", 2026)
	if err != nil || digest(before) != digest(after) {
		t.Fatal("layout/export changed stored annual data", err)
	}
}

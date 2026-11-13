package totalreports

import (
	"bytes"
	"encoding/base64"
	"testing"

	"github.com/xuri/excelize/v2"
)

func TestOriginalHiddenRowsAndColumnsInExistingPage(t *testing.T) {
	s, ctx := fixture(t)
	f := excelize.NewFile()
	defer f.Close()
	dateStyle, err := f.NewStyle(&excelize.Style{NumFmt: 57})
	if err != nil {
		t.Fatal(err)
	}
	for _, err := range []error{
		f.SetCellValue("Sheet1", "A1", "原稿隐藏列"),
		f.SetCellValue("Sheet1", "C3", 7),
		f.SetCellFormula("Sheet1", "E4", "C3*2"),
		f.SetColVisible("Sheet1", "C:D", false),
		f.SetRowVisible("Sheet1", 3, false),
		f.SetCellValue("Sheet1", "E1", 46296),
		f.SetCellStyle("Sheet1", "E1", "E1", dateStyle),
	} {
		if err != nil {
			t.Fatal(err)
		}
	}
	b, err := f.WriteToBuffer()
	if err != nil {
		t.Fatal(err)
	}
	kind, err := s.ImportPage(ctx, PageImport{ID: "hidden-original", Name: "隐藏原稿", Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(b.Bytes())})
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.Document(ctx, kind, 2026)
	if err != nil {
		t.Fatal(err)
	}
	// Existing persisted templates have no visibility fields. Opening a fresh
	// service must still recover visibility without a reimport or data revision.
	s2, err := Open(s.db)
	if err != nil {
		t.Fatal(err)
	}
	sheet, err := s2.Sheet(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	config := sheet["config"].(map[string]any)
	if d.Template.Formats["E1"]["nf"] != `yyyy"年"m"月"` {
		t.Fatal("Chinese year/month header lost its format", d.Template.Formats["E1"])
	}
	cols, rows := config["colhidden"].(map[string]int), config["rowhidden"].(map[string]int)
	if len(cols) != 2 || cols["2"] != 0 || cols["3"] != 0 || len(rows) != 1 || rows["2"] != 0 {
		t.Fatal(config)
	}
	found := false
	for _, c := range d.resolved() {
		if c.R == 2 && c.C == 2 && c.V != nil {
			found = true
		}
	}
	if !found {
		t.Fatal("hidden input removed")
	}
	exported, err := s2.Export(ctx, kind, 2026)
	if err != nil {
		t.Fatal(err)
	}
	x, err := excelize.OpenReader(bytes.NewReader(exported))
	if err != nil {
		t.Fatal(err)
	}
	defer x.Close()
	v, err := x.GetColVisible("Sheet1", "C")
	if err != nil || v {
		t.Fatal("export unhid input column", v, err)
	}
	formula, err := x.GetCellFormula("Sheet1", "E4")
	if err != nil || formula != "C3*2" {
		t.Fatal("hidden dependency changed", formula, err)
	}
	d2, err := s2.Document(ctx, kind, 2026)
	if err != nil || d2.Revision != d.Revision {
		t.Fatal("display created a data edit", err)
	}
}

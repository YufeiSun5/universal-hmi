package totalreports

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func TestLargeCustomPageCheckpointCanBeRestored(t *testing.T) {
	cells := make([]Cell, 5000)
	for i := range cells {
		cells[i] = Cell{Address: address(i/100, i%100), Value: strings.Repeat("x", 1000)}
	}
	var b bytes.Buffer
	z := gzip.NewWriter(&b)
	if e := json.NewEncoder(z).Encode(cells); e != nil {
		t.Fatal(e)
	}
	if e := z.Close(); e != nil {
		t.Fatal(e)
	}
	decoded, e := decodeCheckpoint(b.Bytes())
	if e != nil || len(decoded) != len(cells) || decoded[4999].Value != cells[4999].Value {
		t.Fatal("large valid checkpoint cannot restore", e)
	}
}

func TestUploadedPageStylesFormulasAnnualIsolationAndRollback(t *testing.T) {
	s, ctx := fixture(t)
	f := excelize.NewFile()
	defer f.Close()
	f.SetCellValue("Sheet1", "A1", "新报表")
	f.MergeCell("Sheet1", "A1", "C1")
	f.SetCellValue("Sheet1", "A2", 12.5)
	f.SetCellFormula("Sheet1", "B2", "=A2*2")
	nf := "0.00"
	style, _ := f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true, Color: "FF0000", Size: 14}, Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"CCFFCC"}}, CustomNumFmt: &nf})
	f.SetCellStyle("Sheet1", "A2", "A2", style)
	b, _ := f.WriteToBuffer()
	in := PageImport{ID: "test-upload-01", Name: "月度统计", Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(b.Bytes())}
	if _, e := s.ImportPage(actor(true, false, true), in); !errors.Is(e, authorization.ErrDenied) {
		t.Fatalf("editor must not create: %v", e)
	}
	kind, e := s.ImportPage(ctx, in)
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	if d.Template.Rows != 2 || d.Template.Columns != 3 || d.Template.Name != in.Name || d.Template.Formats["A2"]["fc"] != "#FF0000" {
		t.Fatalf("lost workbook layout/style: %+v", d.Template)
	}
	if editable(d.Template, 2026)["B1"] || !editable(d.Template, 2026)["A2"] {
		t.Fatal("merged cells or custom inputs wrong")
	}
	cp, e := s.CreateCheckpoint(ctx, kind, 2026, 0)
	if e != nil {
		t.Fatal(e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "custom-client", Addresses: []string{"A2"}})
	saved, e := s.Patch(ctx, kind, 2026, Patch{ID: "page-change-01", Client: "custom-client", Changes: []Change{{Address: "A2", Value: "20", Expected: 0}}})
	if e != nil {
		t.Fatal(e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "custom-client"})
	other, _ := s.Document(ctx, kind, 2027)
	for _, c := range other.Cells {
		if c.Address == "A2" && c.Value != "12.5" {
			t.Fatal("year leaked", c)
		}
	}
	_, e = s.Rollback(ctx, kind, 2026, Rollback{ID: "page-rollback-01", Checkpoint: cp.ID, Expected: saved.Revision})
	if e != nil {
		t.Fatal(e)
	}
	exported, e := s.Export(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	book, e := excelize.OpenReader(bytes.NewReader(exported))
	if e != nil {
		t.Fatal(e)
	}
	defer book.Close()
	if v, _ := book.GetCellValue("总体报表", "A2", excelize.Options{RawCellValue: true}); v != "12.5" {
		t.Fatal("restore", v)
	}
	if formula, _ := book.GetCellFormula("总体报表", "B2"); formula != "=A2*2" {
		t.Fatal("formula", formula)
	}
	sid, _ := book.GetCellStyle("总体报表", "A2")
	st, _ := book.GetStyle(sid)
	if st.Font.Color != "FF0000" || !st.Font.Bold {
		t.Fatal("export lost font", st)
	}
	// Retry must not replace an already edited page definition.
	in.Name = "changed"
	if _, e = s.ImportPage(ctx, in); e != nil {
		t.Fatal(e)
	}
	again, _ := s.Document(ctx, kind, 2028)
	if again.Template.Name != "月度统计" {
		t.Fatal("retry overwrote page")
	}
	f.SetCellFormula("Sheet1", "B2", "='Other'!A1")
	b, _ = f.WriteToBuffer()
	in.ID = "test-upload-02"
	in.Data = base64.StdEncoding.EncodeToString(b.Bytes())
	if _, e = s.ImportPage(ctx, in); e == nil {
		t.Fatal("cross-sheet reference silently accepted")
	}
}

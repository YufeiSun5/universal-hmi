package totalreports

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

const preservationSheet = "采暖计划 '26"

func TestSeasonOriginalKeepsFormattedMargins(t *testing.T) {
	f := excelize.NewFile()
	defer f.Close()
	if e := f.SetCellValue("Sheet1", "A1", "report"); e != nil {
		t.Fatal(e)
	}
	if e := f.SetCellStyle("Sheet1", "CB382", "CB382", 0); e != nil {
		t.Fatal(e)
	}
	if e := f.SetSheetDimension("Sheet1", "A1:CB382"); e != nil {
		t.Fatal(e)
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		t.Fatal(e)
	}
	in := WorkbookUpload{Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(b.Bytes()), RepeatRow: 33}
	if _, _, e = prepareOriginal(Template{Columns: 47, HeaderRows: 12}, in); e != nil {
		t.Fatal(e)
	}
	in.RepeatRow = 0
	if _, _, e = prepareOriginal(Template{Rows: 382, Columns: 80}, in); e == nil {
		t.Fatal("custom page limit was relaxed")
	}
}

func preservationWorkbook(t *testing.T) []byte {
	t.Helper()
	f := excelize.NewFile()
	defer f.Close()
	check := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	check(f.SetSheetName("Sheet1", preservationSheet))
	check(f.SetCellValue(preservationSheet, "A1", "计划"))
	check(f.SetCellValue(preservationSheet, "B2", 10))
	check(f.SetCellFormula(preservationSheet, "C2", `=IF(B2>10,"通过","错误")`))
	check(f.SetCellValue(preservationSheet, "D8", "备注"))
	check(f.MergeCell(preservationSheet, "A1", "D1"))
	id, e := f.NewStyle(&excelize.Style{Border: []excelize.Border{{Type: "left", Color: "112233", Style: 2}, {Type: "right", Color: "445566", Style: 4}, {Type: "top", Color: "778899", Style: 5}, {Type: "bottom", Color: "AABBCC", Style: 6}}, Font: &excelize.Font{Family: "SimSun", Size: 13, Bold: true, Color: "112233", Underline: "double"}, Alignment: &excelize.Alignment{Horizontal: "right", Vertical: "top", TextRotation: 20, ShrinkToFit: true}, NumFmt: 4})
	check(e)
	check(f.SetCellStyle(preservationSheet, "B2", "C2", id))
	check(f.SetRowHeight(preservationSheet, 1, 34))
	check(f.SetRowHeight(preservationSheet, 2, 27))
	check(f.SetRowHeight(preservationSheet, 8, 42))
	check(f.SetColWidth(preservationSheet, "B", "B", 18.5))
	check(f.SetPanes(preservationSheet, &excelize.Panes{Freeze: true, XSplit: 2, YSplit: 3, TopLeftCell: "C4", ActivePane: "bottomRight", Selection: []excelize.Selection{{SQRef: "C4", ActiveCell: "C4", Pane: "bottomRight"}}}))
	check(f.SetHeaderFooter(preservationSheet, &excelize.HeaderFooterOptions{OddHeader: "&L计划&C年度汇总&R&D", OddFooter: "&L内部&C第&P页 / &N页", DifferentFirst: true, FirstHeader: "&C封面", FirstFooter: "&R第一页"}))
	orientation, size, fitWidth, fitHeight, scale := "landscape", 9, 1, 0, uint(85)
	check(f.SetPageLayout(preservationSheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight, AdjustTo: &scale}))
	left, right, top, bottom := 0.25, 0.35, 0.45, 0.55
	check(f.SetPageMargins(preservationSheet, &excelize.PageLayoutMarginsOptions{Left: &left, Right: &right, Top: &top, Bottom: &bottom}))
	quoted := "'" + strings.ReplaceAll(preservationSheet, "'", "''") + "'"
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: quoted + "!$A$1:$D$8", Scope: preservationSheet}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: quoted + "!$1:$1", Scope: preservationSheet}))
	check(f.InsertPageBreak(preservationSheet, "A5"))
	check(f.InsertPageBreak(preservationSheet, "D1"))
	dxf, e := f.NewConditionalStyle(&excelize.Style{Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"00FF00"}}})
	check(e)
	check(f.SetConditionalFormat(preservationSheet, "C2", []excelize.ConditionalFormatOptions{{Type: "formula", Criteria: `C2="通过"`, Format: &dxf}}))
	b, e := f.WriteToBuffer()
	check(e)
	return b.Bytes()
}

// Compare the native OOXML settings, including manual page breaks for which
// the library has no corresponding public getter.
func preservedXML(t *testing.T, data []byte) map[string][]string {
	t.Helper()
	z, e := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if e != nil {
		t.Fatal(e)
	}
	wanted := map[string]bool{"sheetViews": true, "sheetFormatPr": true, "cols": true, "conditionalFormatting": true, "pageMargins": true, "pageSetup": true, "headerFooter": true, "rowBreaks": true, "colBreaks": true, "printOptions": true, "definedNames": true, "mergeCells": true}
	result := map[string][]string{}
	for _, file := range z.File {
		if file.Name != "xl/worksheets/sheet1.xml" && file.Name != "xl/workbook.xml" {
			continue
		}
		r, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		d := xml.NewDecoder(r)
		depth := 0
		active := ""
		for {
			token, err := d.Token()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
			switch v := token.(type) {
			case xml.StartElement:
				if depth == 0 && wanted[v.Name.Local] {
					active = file.Name + ":" + v.Name.Local
					depth = 1
				} else if depth > 0 {
					depth++
				}
				if depth > 0 {
					result[active] = append(result[active], fmt.Sprintf("%v", v))
				}
			case xml.EndElement:
				if depth > 0 {
					result[active] = append(result[active], fmt.Sprintf("%v", v))
					depth--
				}
			case xml.CharData:
				if depth > 0 && strings.TrimSpace(string(v)) != "" {
					result[active] = append(result[active], string(v))
				}
			}
		}
		r.Close()
	}
	return result
}

func TestExportPreservesNativeWorkbookSettingsAfterEditsAndRollback(t *testing.T) {
	s, ctx := fixture(t)
	source := preservationWorkbook(t)
	kind, e := s.ImportPage(ctx, PageImport{ID: "native-layout-test", Name: "年度计划", Sheet: preservationSheet, Data: base64.StdEncoding.EncodeToString(source)})
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	if d.Template.Original == nil || d.Template.Workbook != nil {
		t.Fatal("missing immutable source or leaked workbook bytes")
	}
	cp, e := s.CreateCheckpoint(ctx, kind, 2026, 0)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "native-client", Addresses: []string{"B2"}}); e != nil {
		t.Fatal(e)
	}
	// Like the browser, a value-only edit sends a complete normalized format.
	base := CellFormat{"bg": "#FFFFFF", "fc": "#112233", "ff": "SimSun", "fs": float64(13), "bl": float64(1), "it": float64(0), "un": float64(1), "cl": float64(0), "ht": float64(2), "vt": float64(1), "tb": float64(0), "nf": "#,##0.00"}
	saved, e := s.Patch(ctx, kind, 2026, Patch{ID: "original-value-edit", Client: "native-client", Changes: []Change{{Address: "B2", Value: "25", Expected: 0, Format: base}}})
	if e != nil {
		t.Fatal(e)
	}
	verify := func(want string, changedStyle bool) {
		t.Helper()
		out, e := s.Export(ctx, kind, 2026)
		if e != nil {
			t.Fatal(e)
		}
		before, after := preservedXML(t, source), preservedXML(t, out)
		if !reflect.DeepEqual(before, after) {
			for k, v := range before {
				if !reflect.DeepEqual(v, after[k]) {
					t.Errorf("native property changed: %s\nbefore %v\nafter %v", k, v, after[k])
				}
			}
			t.FailNow()
		}
		original, e := openOriginal(source)
		if e != nil {
			t.Fatal(e)
		}
		defer original.Close()
		book, e := openOriginal(out)
		if e != nil {
			t.Fatal(e)
		}
		defer book.Close()
		if len(book.GetSheetList()) != 1 || book.GetSheetList()[0] != preservationSheet {
			t.Fatal("sheet name changed")
		}
		for _, r := range []int{1, 2, 8} {
			a, _ := original.GetRowHeight(preservationSheet, r)
			b, _ := book.GetRowHeight(preservationSheet, r)
			if a != b {
				t.Fatal("row height changed", r, a, b)
			}
		}
		id, _ := original.GetCellStyle(preservationSheet, "B2")
		beforeStyle, _ := original.GetStyle(id)
		id, _ = book.GetCellStyle(preservationSheet, "B2")
		afterStyle, _ := book.GetStyle(id)
		if !reflect.DeepEqual(beforeStyle.Border, afterStyle.Border) || !reflect.DeepEqual(beforeStyle.Alignment, afterStyle.Alignment) {
			t.Fatal("border, rotation or shrink-to-fit changed", beforeStyle, afterStyle)
		}
		if !changedStyle && !reflect.DeepEqual(beforeStyle, afterStyle) {
			t.Fatal("value-only edit altered original style", beforeStyle, afterStyle)
		}
		if changedStyle && afterStyle.Font.Color != "FF0000" {
			t.Fatal("explicit font edit lost")
		}
		v, e := book.CalcCellValue(preservationSheet, "C2")
		if e != nil || v != want {
			t.Fatal("formula no longer reacts to edited value", v, e)
		}
	}
	verify("通过", false)
	base["fc"] = "#FF0000"
	saved, e = s.Patch(ctx, kind, 2026, Patch{ID: "original-format-edit", Client: "native-client", Changes: []Change{{Address: "B2", Value: "25", Expected: saved.Revision, Format: base}}})
	if e != nil {
		t.Fatal(e)
	}
	verify("通过", true)
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "native-client"})
	if _, e = s.Rollback(ctx, kind, 2026, Rollback{ID: "original-rollback", Checkpoint: cp.ID, Expected: saved.Revision}); e != nil {
		t.Fatal(e)
	}
	verify("错误", false)
}

func TestAttachOriginalPreservesOldAnnualDataAndRejectsWrongScope(t *testing.T) {
	s, ctx := fixture(t)
	data := preservationWorkbook(t)
	kind, e := s.ImportPage(ctx, PageImport{ID: "legacy-native-page", Name: "旧页", Sheet: preservationSheet, Data: base64.StdEncoding.EncodeToString(data)})
	if e != nil {
		t.Fatal(e)
	}
	// Simulate the v76 format, which stored parsed cells but not the workbook.
	var raw string
	s.db.QueryRow(`SELECT data FROM total_report_templates WHERE kind=?`, kind).Scan(&raw)
	var old Template
	json.Unmarshal([]byte(raw), &old)
	old.Original = nil
	b, _ := json.Marshal(old)
	s.db.Exec(`UPDATE total_report_templates SET data=? WHERE kind=?`, string(b), kind)
	d, _ := s.Document(ctx, kind, 2026)
	s.Document(ctx, kind, 2027)
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "legacy-client", Addresses: []string{"B2"}})
	_, e = s.Patch(ctx, kind, 2026, Patch{ID: "legacy-value-edit", Client: "legacy-client", Changes: []Change{{Address: "B2", Value: "88", Expected: 0}}})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Export(ctx, kind, 2026); e == nil {
		t.Fatal("legacy source-less page silently exported an approximation")
	}
	upload := WorkbookUpload{Sheet: preservationSheet, Data: base64.StdEncoding.EncodeToString(data)}
	if e = s.AttachOriginal(actor(true, false, true), kind, upload); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("editor attached source without developer permission", e)
	}
	if e = s.AttachOriginal(ctx, kind, upload); e != nil {
		t.Fatal(e)
	}
	if e = s.AttachOriginal(ctx, kind, upload); e != nil {
		t.Fatal("exact retry", e)
	}
	for _, year := range []int{2026, 2027} {
		after, e := s.Document(ctx, kind, year)
		if e != nil || after.Template.Original == nil {
			t.Fatal("legacy year not upgraded", year, e)
		}
		for _, c := range after.Cells {
			if c.Address == "B2" {
				want := "10"
				if year == 2026 {
					want = "88"
				}
				if c.Value != want {
					t.Fatal("attachment overwrote inputs", year, c)
				}
			}
		}
		if templateLayoutID(after.Template) != templateLayoutID(d.Template) {
			t.Fatal("attachment changed frozen template")
		}
	}
}

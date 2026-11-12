package totalreports

import (
	"context"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/xuri/excelize/v2"
)

func genericPage(t *testing.T, s *Service, ctx context.Context) string {
	t.Helper()
	f := excelize.NewFile()
	defer f.Close()
	f.SetCellValue("Sheet1", "A1", "完整表头")
	f.SetCellValue("Sheet1", "A2", "2026-11-05")
	f.SetCellValue("Sheet1", "A3", "2026-11-06")
	f.SetCellValue("Sheet1", "B2", 5)
	f.SetCellFormula("Sheet1", "C2", `=B2+$B$1+B$1+$B2+IF(A2="B2",0,0)`)
	f.SetCellValue("Sheet1", "H8", "区域外保留")
	style, _ := f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true, Color: "FF0000"}, Border: []excelize.Border{{Type: "bottom", Color: "00AA00", Style: 2}}})
	f.SetCellStyle("Sheet1", "B2", "B2", style)
	f.SetRowHeight("Sheet1", 2, 35)
	b, _ := f.WriteToBuffer()
	kind, e := s.ImportPage(ctx, PageImport{ID: "generic-page-01", Name: "通用测试", Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(b.Bytes())})
	if e != nil {
		t.Fatal(e)
	}
	return kind
}

type genericReader struct {
	counterFixture
	duringRead func()
	last       externaldata.ReportValueRequest
}

func (r *genericReader) Stations(context.Context, string) ([]externaldata.Station, error) {
	return []externaldata.Station{{Code: "zone", Name: "站区"}}, nil
}
func (r *genericReader) ReportPoints(context.Context, string, string) ([]externaldata.Point, error) {
	return []externaldata.Point{{Code: "heat", Name: "热量", Unit: "GJ"}}, nil
}
func (r *genericReader) ReportValues(_ context.Context, in externaldata.ReportValueRequest) ([]externaldata.ReportValue, error) {
	r.last = in
	if r.duringRead != nil {
		r.duringRead()
	}
	out := make([]externaldata.ReportValue, len(in.Targets))
	for i, v := range in.Targets {
		value := "0"
		if i > 0 {
			value = "123.25"
		}
		out[i] = externaldata.ReportValue{Target: v.From, Value: &value}
	}
	return out, nil
}
func testBinding() HistoryBinding {
	return HistoryBinding{ID: "generic-binding", Range: "D2:D3", Screen: "source", Station: "zone", Point: "heat", Unit: "GJ", Mode: "nearest", Start: "{year}-11-05", Direction: "down", StepDays: 1, Time: "08:15", WindowMinutes: 12}
}
func TestGenericBindingPreviewSaveRefreshAndIsolation(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	reader := &genericReader{}
	s.SetCounterReader(reader)
	d, _ := s.Document(ctx, kind, 2026)
	b := testBinding()
	preview, e := s.PreviewHistory(ctx, kind, 2026, b)
	if e != nil || len(preview) != 2 || preview[0].From != "2026-11-05T08:15:00+08:00" || *preview[0].Value != "0" {
		t.Fatal(preview, e)
	}
	unchanged, _ := s.Document(ctx, kind, 2026)
	if unchanged.Revision != d.Revision || len(unchanged.Template.History) != 0 {
		t.Fatal("preview mutated document")
	}
	if _, e = s.SaveHistoryBinding(actor(true, false, true), kind, 2026, HistoryBindingChange{Expected: d.Revision, Binding: b, Confirm: true}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("editor configured source", e)
	}
	got, e := s.SaveHistoryBinding(ctx, kind, 2026, HistoryBindingChange{Expected: d.Revision, Binding: b, Confirm: true})
	if e != nil {
		t.Fatal(e)
	}
	current, _ := s.Document(ctx, kind, 2026)
	if editable(current.Template, 2026)["D2"] {
		t.Fatal("bound cell editable")
	}
	other, _ := s.Document(ctx, kind, 2027)
	if len(other.Template.History) != 0 {
		t.Fatal("configuration leaked to other year")
	}
	if _, e = s.SaveHistoryBinding(ctx, kind, 2026, HistoryBindingChange{Expected: d.Revision, Binding: b, Confirm: true}); !errors.Is(e, ErrConflict) {
		t.Fatal("stale config accepted", e)
	}
	refreshed, e := s.RefreshHistory(ctx, kind, 2026)
	if e != nil || len(refreshed.Cells) != 2 || refreshed.Revision <= got.Revision {
		t.Fatal(refreshed, e)
	}
	current, _ = s.Document(ctx, kind, 2026)
	values := map[string]string{}
	for _, c := range current.Cells {
		values[c.Address] = c.Value
	}
	if values["D2"] != "0" || values["D3"] != "123.25" || values["B2"] != "5" || values["H8"] != "区域外保留" {
		t.Fatal(values)
	}
	reader.duringRead = func() { s.db.Exec(`UPDATE total_report_docs SET revision=revision+1 WHERE doc=?`, kind+"/2026") }
	if _, e = s.RefreshHistory(ctx, kind, 2026); !errors.Is(e, ErrConflict) {
		t.Fatal("racing edit accepted", e)
	}
}
func TestGenericBindingDateReferencesAndOverlaps(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	s.SetCounterReader(&genericReader{})
	b := testBinding()
	b.DateCell = "A2"
	b.OffsetDays = 1
	v, e := s.PreviewHistory(ctx, kind, 2026, b)
	if e != nil || v[1].From != "2026-11-07T08:15:00+08:00" {
		t.Fatal(v, e)
	}
	d, _ := s.Document(ctx, kind, 2026)
	d.Template.History = []HistoryBinding{b, b}
	if validateHistory(d.Template, 2026) == nil {
		t.Fatal("overlap accepted")
	}
	b.Mode = "daily_usage"
	if _, e = s.PreviewHistory(ctx, kind, 2026, b); e == nil {
		t.Fatal("nonmidnight settlement accepted")
	}
}
func TestFragmentPreviewRelativeReferencesAndAtomicApply(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	p, e := s.ExportFragment(ctx, kind, 2026, "B2:C2")
	if e != nil {
		t.Fatal(e)
	}
	bytes, _ := base64.StdEncoding.DecodeString(p.Workbook.Data)
	f, e := openOriginal(bytes)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	if v, _ := f.GetCellValue("Sheet1", "H8"); v != "" {
		t.Fatal("partial export leaked outside data")
	}
	d, _ := s.Document(ctx, kind, 2026)
	in := FragmentImport{Expected: d.Revision, Fragment: p, Target: "D4", Mode: "all", Confirm: true}
	preview, e := s.PreviewFragment(ctx, kind, 2026, in)
	if e != nil || preview.Range != "D4:E4" || len(preview.Warnings) == 0 {
		t.Fatal(preview, e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "other-editor", Addresses: []string{"D4"}})
	if _, e = s.ApplyFragment(ctx, kind, 2026, in); !errors.Is(e, ErrLocked) {
		t.Fatal("import overwrote lease", e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "other-editor"})
	_, e = s.ApplyFragment(ctx, kind, 2026, in)
	if e != nil {
		t.Fatal(e)
	}
	d, _ = s.Document(ctx, kind, 2026)
	values := map[string]string{}
	for _, c := range d.Cells {
		values[c.Address] = c.Value
	}
	want := `=D4+$B$1+D$1+$B4+IF(C4="B2",0,0)`
	if values["E4"] != want || values["D4"] != "5" || values["H8"] != "区域外保留" {
		t.Fatal(values["E4"], values["D4"], values["H8"])
	}
	data, e := s.Export(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	out, e := openOriginal(data)
	if e != nil {
		t.Fatal(e)
	}
	defer out.Close()
	id, _ := out.GetCellStyle("Sheet1", "D4")
	style, _ := out.GetStyle(id)
	if !style.Font.Bold || style.Font.Color != "FF0000" || len(style.Border) == 0 {
		t.Fatal("native style lost", style)
	}
	if _, e = s.ApplyFragment(ctx, kind, 2026, in); !errors.Is(e, ErrConflict) {
		t.Fatal("stale import accepted", e)
	}
}
func TestFragmentSelectiveImportAndWholeRoundtrip(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	p, e := s.ExportFragment(ctx, kind, 2026, "B2:C2")
	if e != nil {
		t.Fatal(e)
	}
	d, _ := s.Document(ctx, kind, 2026)
	in := FragmentImport{Expected: d.Revision, Fragment: p, Target: "D4", Mode: "format", Confirm: true}
	if _, e = s.ApplyFragment(ctx, kind, 2026, in); e != nil {
		t.Fatal(e)
	}
	d, _ = s.Document(ctx, kind, 2026)
	for _, c := range d.Cells {
		if c.Address == "D4" && c.Value != "" {
			t.Fatal("format imported data")
		}
	}
	whole, e := s.ExportFragment(ctx, kind, 2026, "")
	if e != nil {
		t.Fatal(e)
	}
	newKind, e := s.ImportFragmentPage(ctx, FragmentPage{ID: "generic-copy-01", Name: "完整复制", Fragment: whole})
	if e != nil {
		t.Fatal(e)
	}
	copy, e := s.Document(ctx, newKind, 2026)
	if e != nil || copy.Template.Rows != 8 || copy.Template.Columns != 8 {
		t.Fatal(copy, e)
	}
	broken := whole
	broken.History = []HistoryBinding{testBinding()}
	broken.History[0].Range = "Z99:Z100"
	if _, e = s.ImportFragmentPage(ctx, FragmentPage{ID: "generic-invalid-01", Name: "不得留下半张表", Fragment: broken}); e == nil {
		t.Fatal("invalid binding imported")
	}
	catalog, _ := s.Catalog(ctx)
	for _, v := range catalog {
		if v["kind"] == "page_generic-invalid-01" {
			t.Fatal("failed import partially persisted")
		}
	}
}

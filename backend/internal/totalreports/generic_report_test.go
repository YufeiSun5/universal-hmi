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
	for i := range whole.Cells {
		if whole.Cells[i].Address == "A1" {
			whole.Cells[i].Value = "配置文件改过的表头"
		}
	}
	newKind, e := s.ImportFragmentPage(ctx, FragmentPage{ID: "generic-copy-01", Name: "完整复制", Fragment: whole})
	if e != nil {
		t.Fatal(e)
	}
	copy, e := s.Document(ctx, newKind, 2026)
	if e != nil || copy.Template.Rows != 8 || copy.Template.Columns != 8 {
		t.Fatal(copy, e)
	}
	if copy.Cells[0].Address == "" {
		t.Fatal("empty copy")
	}
	found := false
	for _, c := range copy.Cells {
		if c.Address == "A1" {
			found = c.Value == "配置文件改过的表头"
		}
	}
	if !found {
		t.Fatal("configuration changes lost to embedded workbook")
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

func TestPartialDateBindingKeepsOriginalDates(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	s.SetCounterReader(&genericReader{})
	b := testBinding()
	b.DateCell = "A2"
	b.OffsetDays = 1
	d, _ := s.Document(ctx, kind, 2026)
	if _, e := s.SaveHistoryBinding(ctx, kind, 2026, HistoryBindingChange{Binding: b, Expected: d.Revision, Confirm: true}); e != nil {
		t.Fatal(e)
	}
	p, e := s.ExportFragment(ctx, kind, 2026, "D3:D3")
	if e != nil || len(p.History) != 1 {
		t.Fatal(p, e)
	}
	if p.History[0].DateCell != "A3" || p.History[0].OffsetDays != 1 {
		t.Fatal("offset applied twice", p.History)
	}
	preview, e := s.PreviewHistory(ctx, kind, 2026, p.History[0])
	if e != nil || preview[0].From != "2026-11-07T08:15:00+08:00" {
		t.Fatal(preview, e)
	}
}

func TestGenericDateFormulaParameterAndDesignRestore(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	s.SetCounterReader(&genericReader{})
	d, _ := s.Document(ctx, kind, 2026)
	for i := range d.Cells {
		if d.Cells[i].Address == "A2" {
			d.Cells[i].Value = "=DATE(2026,11,5)"
		}
	}
	b := testBinding()
	b.DateCell = "A2"
	b.DateFixed = true
	_, targets, e := bindingTargets(d, b)
	if e != nil || targets[1].From != "2026-11-06T08:15:00+08:00" {
		t.Fatal(targets, e)
	}
	saved, e := s.SaveHistoryBinding(ctx, kind, 2026, HistoryBindingChange{Expected: d.Revision, Binding: b, Confirm: true})
	if e != nil {
		t.Fatal(e)
	}
	versions, e := s.DesignHistory(ctx, kind, 2026)
	if e != nil || len(versions) != 1 {
		t.Fatal(versions, e)
	}
	if _, e = s.RestoreDesign(actor(true, true, true), kind, 2026, DesignRestore{Revision: versions[0].Revision, Expected: saved.Revision, Confirm: true}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("runtime user restored design", e)
	}
	if _, e = s.RestoreDesign(ctx, kind, 2026, DesignRestore{Revision: versions[0].Revision, Expected: saved.Revision, Confirm: true}); e != nil {
		t.Fatal(e)
	}
	d, _ = s.Document(ctx, kind, 2026)
	if len(d.Template.History) != 0 || !editable(d.Template, 2026)["D2"] {
		t.Fatal("design restore did not remove binding")
	}
	versions, e = s.DesignHistory(ctx, kind, 2026)
	if e != nil || len(versions) != 2 {
		t.Fatal("current version not preserved", versions, e)
	}
}

func TestWholeReportCopyPreservesUnusedNativeMargins(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	p, e := s.ExportFragment(ctx, kind, 2026, "")
	if e != nil {
		t.Fatal(e)
	}
	bytes, _ := base64.StdEncoding.DecodeString(p.Workbook.Data)
	f, e := openOriginal(bytes)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	id, _ := f.NewStyle(&excelize.Style{Border: []excelize.Border{{Type: "bottom", Color: "123456", Style: 1}}})
	f.SetCellStyle("Sheet1", "CB382", "CB382", id)
	buf, _ := f.WriteToBuffer()
	p.Workbook.Data = base64.StdEncoding.EncodeToString(buf.Bytes())
	copy, e := s.ImportFragmentPage(ctx, FragmentPage{ID: "copy-margins-01", Name: "保留打印原稿", Fragment: p})
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, copy, 2026)
	if e != nil || d.Template.Rows != 8 || d.Template.Columns != 8 || !d.Template.OriginalMargins {
		t.Fatal(d.Template, e)
	}
	bytes, e = s.Export(ctx, copy, 2026)
	if e != nil {
		t.Fatal(e)
	}
	out, e := openOriginal(bytes)
	if e != nil {
		t.Fatal(e)
	}
	defer out.Close()
	id, _ = out.GetCellStyle("Sheet1", "CB382")
	style, _ := out.GetStyle(id)
	if len(style.Border) == 0 {
		t.Fatal("native margin style lost")
	}
}

func TestGenericDesignOperationsRequireEngineering(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	runtime := actor(true, true, true)
	operations := []func() error{
		func() error { _, e := s.PreviewHistory(runtime, kind, 2026, testBinding()); return e },
		func() error { _, e := s.HistoryCatalog(runtime, "", ""); return e },
		func() error { _, e := s.PreviewFragment(runtime, kind, 2026, FragmentImport{}); return e },
		func() error { _, e := s.ApplyFragment(runtime, kind, 2026, FragmentImport{}); return e },
		func() error { _, e := s.ImportFragmentPage(runtime, FragmentPage{}); return e },
		func() error { _, e := s.DesignHistory(runtime, kind, 2026); return e },
		func() error { _, e := s.RestoreDesign(runtime, kind, 2026, DesignRestore{}); return e },
	}
	for i, operation := range operations {
		if e := operation(); !errors.Is(e, authorization.ErrDenied) {
			t.Fatalf("operation %d escaped engineering permission: %v", i, e)
		}
	}
}

func TestPartialConditionalFormatPreservesOutside(t *testing.T) {
	f := excelize.NewFile()
	defer f.Close()
	id, e := f.NewConditionalStyle(&excelize.Style{Font: &excelize.Font{Color: "FF0000"}})
	if e != nil {
		t.Fatal(e)
	}
	if e = f.SetConditionalFormat("Sheet1", "A1:A5", []excelize.ConditionalFormatOptions{{Type: "formula", Criteria: "A1>10", Format: &id}}); e != nil {
		t.Fatal(e)
	}
	if e = clearRegionConditions(f, "Sheet1", cellRect{2, 0, 2, 0}); e != nil {
		t.Fatal(e)
	}
	rules, e := f.GetConditionalFormats("Sheet1")
	if e != nil {
		t.Fatal(e)
	}
	if len(rules) != 2 || len(rules["A1:A2"]) != 1 || len(rules["A4:A5"]) != 1 || rules["A4:A5"][0].Criteria != "A4>10" {
		t.Fatal(rules)
	}
}

func TestRelocationKeepsNamesAndStringLiterals(t *testing.T) {
	got, _, e := relocateFormula(`=SUM(a1,$B$2,DATA1,ABC123_NAME)+IF(A1="a1",0,1)`, 1, 1, cellRect{0, 0, 2, 2})
	if e != nil || got != `=SUM(B2,$B$2,DATA1,ABC123_NAME)+IF(B2="a1",0,1)` {
		t.Fatal(got, e)
	}
}

package totalreports

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func managementWorkbook(t *testing.T, small bool) WorkbookUpload {
	t.Helper()
	f := excelize.NewFile()
	defer f.Close()
	f.SetCellValue("Sheet1", "A1", "计划")
	if small {
		f.SetCellValue("Sheet1", "A2", 5)
		f.SetCellFormula("Sheet1", "B2", "A2*3")
		f.SetColVisible("Sheet1", "B", false)
	} else {
		f.SetCellValue("Sheet1", "A4", 8)
		f.SetCellFormula("Sheet1", "C4", "A4*2")
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		t.Fatal(e)
	}
	return WorkbookUpload{Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(b.Bytes())}
}
func managementPage(t *testing.T, s *Service, ctx context.Context) string {
	t.Helper()
	w := managementWorkbook(t, false)
	k, e := s.ImportPage(ctx, PageImport{ID: "managed-page", Name: "采暖计划", Sheet: w.Sheet, Data: w.Data})
	if e != nil {
		t.Fatal(e)
	}
	for _, y := range []int{2025, 2026} {
		if _, e = s.Document(ctx, k, y); e != nil {
			t.Fatal(e)
		}
	}
	return k
}
func TestReplacePagePreviewConflictBackupRestoreAndYearIsolation(t *testing.T) {
	s, ctx := fixture(t)
	kind := managementPage(t, s, ctx)
	if _, e := s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "editing-client", Addresses: []string{"A4"}}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Patch(ctx, kind, 2026, Patch{ID: "manual-value", Client: "editing-client", Changes: []Change{{Address: "A4", Value: "99", Expected: 0}}}); e != nil {
		t.Fatal(e)
	}
	in := PageReplace{Workbook: managementWorkbook(t, true), Expected: 1}
	p, e := s.ReplacePage(ctx, kind, 2026, in, false)
	if e != nil || p.OldRows != 4 || p.Rows != 2 || p.Columns != 2 || p.EditedCells != 1 {
		t.Fatal(p, e)
	}
	before, _ := s.Document(ctx, kind, 2026)
	if before.Template.Rows != 4 || before.Revision != 1 {
		t.Fatal("preview mutated", before)
	}
	in.Token = p.Token
	in.Confirm = true
	if _, e = s.ReplacePage(ctx, kind, 2026, in, true); !errors.Is(e, ErrLocked) {
		t.Fatal("must reject active lease", e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "editing-client"})
	tampered := in
	tampered.Workbook = managementWorkbook(t, false)
	if _, e = s.ReplacePage(ctx, kind, 2026, tampered, true); !errors.Is(e, ErrConflict) {
		t.Fatal("changed file accepted", e)
	}
	if _, e = s.ReplacePage(actor(true, true, true), kind, 2026, in, true); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("operator replaced", e)
	}
	if _, e = s.ReplacePage(ctx, kind, 2026, in, true); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, kind, 2026)
	if e != nil || d.Revision != 2 || d.Template.Rows != 2 || d.Template.Name != "采暖计划" || len(d.Cells) != 4 {
		t.Fatal("replacement", d, e)
	}
	for _, y := range []int{2025, 2027} {
		old, e := s.Document(ctx, kind, y)
		if e != nil || old.Template.Rows != 4 {
			t.Fatal("other year changed", y, e)
		}
	}
	exported, e := s.Export(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(exported))
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	if v, _ := f.GetCellFormula("Sheet1", "B2"); v != "A2*3" {
		t.Fatal("formula", v)
	}
	if visible, _ := f.GetColVisible("Sheet1", "B"); visible {
		t.Fatal("hidden lost")
	}
	if v, _ := f.GetCellValue("Sheet1", "A4"); v != "" {
		t.Fatal("stale cell exported", v)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "stale-client", Addresses: []string{"A2"}})
	if _, e = s.Patch(ctx, kind, 2026, Patch{ID: "stale-change", Client: "stale-client", Changes: []Change{{Address: "A2", Value: "42", Expected: 0}}}); !errors.Is(e, ErrConflict) {
		t.Fatal("stale zero edit accepted", e)
	}
	s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "stale-client"})
	if _, e = s.ReplacePage(ctx, kind, 2026, in, true); !errors.Is(e, ErrConflict) {
		t.Fatal("stale revision accepted", e)
	}
	versions, e := s.DesignHistory(ctx, kind, 2026)
	if e != nil || len(versions) != 1 || versions[0].Revision != 1 {
		t.Fatal(versions, e)
	}
	checkpoints, e := s.Checkpoints(ctx, kind, 2026, 0)
	if e != nil {
		t.Fatal(e)
	}
	for _, cp := range checkpoints {
		if cp.Revision == 1 {
			if _, e = s.Rollback(ctx, kind, 2026, Rollback{ID: "old-layout-rollback", Checkpoint: cp.ID, Expected: 2}); e == nil {
				t.Fatal("old coordinates restored into replacement layout")
			}
		}
	}
	if _, e = s.RestoreDesign(ctx, kind, 2026, DesignRestore{Revision: 1, Expected: 2, Confirm: true}); e != nil {
		t.Fatal(e)
	}
	d, e = s.Document(ctx, kind, 2026)
	if e != nil || d.Template.Rows != 4 {
		t.Fatal("restore layout", e)
	}
	values := map[string]string{}
	for _, c := range d.Cells {
		values[c.Address] = c.Value
	}
	if values["A4"] != "99" || values["C4"] != "=A4*2" {
		t.Fatal("restore saved values/formula", values)
	}
	if _, e = s.RestoreDesign(ctx, kind, 2026, DesignRestore{Revision: 2, Expected: 3, Confirm: true}); e != nil {
		t.Fatal(e)
	}
	d, e = s.Document(ctx, kind, 2026)
	if e != nil || d.Template.Rows != 2 || len(d.Cells) != 4 {
		t.Fatal("restore smaller left cells", len(d.Cells), e)
	}
}

func TestPageDeleteRestoreAllYearsPermissionsAndRestart(t *testing.T) {
	s, ctx := fixture(t)
	kind := managementPage(t, s, ctx)
	info, e := s.PageInfo(ctx, kind)
	if e != nil || len(info.Years) != 2 {
		t.Fatal(info, e)
	}
	action := PageAction{Token: info.Token, Confirm: true}
	if _, e = s.SetPageDeleted(actor(true, true, true), kind, action, true); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("operator deleted", e)
	}
	if _, e = s.SetPageDeleted(ctx, "electricity", action, true); e == nil {
		t.Fatal("builtin deleted")
	}
	if _, e = s.Acquire(ctx, kind, 2025, LeaseRequest{Client: "other-year", Addresses: []string{"A4"}}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.SetPageDeleted(ctx, kind, action, true); !errors.Is(e, ErrLocked) {
		t.Fatal("other year's editor ignored", e)
	}
	if _, e = s.Patch(ctx, kind, 2025, Patch{ID: "other-year-edit", Client: "other-year", Changes: []Change{{Address: "A4", Value: "77", Expected: 0}}}); e != nil {
		t.Fatal(e)
	}
	s.Acquire(ctx, kind, 2025, LeaseRequest{Client: "other-year"})
	if _, e = s.SetPageDeleted(ctx, kind, action, true); !errors.Is(e, ErrConflict) {
		t.Fatal("stale delete preview accepted", e)
	}
	info, _ = s.PageInfo(ctx, kind)
	action.Token = info.Token
	if _, e = s.SetPageDeleted(ctx, kind, action, true); e != nil {
		t.Fatal(e)
	}
	s, e = Open(s.db)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.CheckpointDirty(ctx); e != nil {
		t.Fatal("deleted page blocked checkpoint scheduler", e)
	}
	items, _ := s.Catalog(ctx)
	for _, x := range items {
		if x["kind"] == kind {
			t.Fatal("deleted catalog item")
		}
	}
	if _, e = s.Document(ctx, kind, 2026); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted read", e)
	}
	if _, e = s.Document(ctx, kind, 2028); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted new year", e)
	}
	if _, e = s.Export(ctx, kind, 2026); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted export", e)
	}
	if _, e = s.Changes(ctx, kind, 2026, 0); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted changes", e)
	}
	if _, e = s.Leases(ctx, kind, 2026); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted leases", e)
	}
	if _, e = s.Acquire(ctx, kind, 2026, LeaseRequest{Client: "new-editor", Addresses: []string{"A4"}}); !errors.Is(e, ErrMissing) {
		t.Fatal("deleted acquire", e)
	}
	if _, e = s.ArchivedPages(actor(true, true, true)); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("operator archive access", e)
	}
	archived, e := s.ArchivedPages(ctx)
	if e != nil || len(archived) != 1 || archived[0].Kind != kind {
		t.Fatal(archived, e)
	}
	// Import retries must not silently resurrect an archived identity.
	w := managementWorkbook(t, false)
	s.ImportPage(ctx, PageImport{ID: "managed-page", Name: "changed", Sheet: w.Sheet, Data: w.Data})
	if _, e = s.Document(ctx, kind, 2026); !errors.Is(e, ErrMissing) {
		t.Fatal("retry resurrected", e)
	}
	info, _ = s.PageInfo(ctx, kind)
	action.Token = info.Token
	noRollback := authorization.WithActor(ctx, authorization.Actor{ID: "engineer", Grants: authorization.Grants{Roles: []string{"engineer"}, AllStations: true}, Valid: func() bool { return true }})
	if _, e = s.SetPageDeleted(noRollback, kind, action, false); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("restore without rollback grant", e)
	}
	if _, e = s.SetPageDeleted(ctx, kind, action, false); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, kind, 2025)
	if e != nil {
		t.Fatal(e)
	}
	found := false
	for _, c := range d.Cells {
		if c.Address == "A4" && c.Value == "77" {
			found = true
		}
	}
	if !found {
		t.Fatal("archived data lost")
	}
	if _, e = s.SetPageDeleted(ctx, kind, action, true); !errors.Is(e, ErrConflict) {
		t.Fatal("old archive token reused", e)
	}
}

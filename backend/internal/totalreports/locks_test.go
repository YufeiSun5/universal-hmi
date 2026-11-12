package totalreports

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
	"testing"
	"time"
)

func namedActor(id, name string) context.Context {
	return authorization.WithActor(context.Background(), authorization.Actor{ID: id, DisplayName: name, ReadOnly: true, Grants: authorization.Grants{Roles: []string{"operator"}, AllStations: true, TotalReportsEdit: true, TotalReportsRollback: true, Export: true}, Valid: func() bool { return true }})
}

func TestRuntimeOriginalExportUsesAccountGrant(t *testing.T) {
	s, engineer := fixture(t)
	kind, err := s.ImportPage(engineer, PageImport{ID: "runtime-export", Name: "Runtime export", Sheet: preservationSheet, Data: base64.StdEncoding.EncodeToString(preservationWorkbook(t))})
	if err != nil {
		t.Fatal(err)
	}
	for _, allowed := range []bool{false, true} {
		original := authorization.Grants{Roles: []string{"viewer"}, AllStations: true, Export: allowed}
		a := authorization.Actor{ID: "runtime-reader", ReadOnly: true, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}, GrantLimits: &original, Valid: func() bool { return true }}
		ctx := authorization.WithActor(context.Background(), a)
		d, e := s.Document(ctx, kind, 2026)
		if e != nil || d.CanExport != allowed || d.CanEdit {
			t.Fatal(d.CanExport, d.CanEdit, e)
		}
		data, e := s.Export(ctx, kind, 2026)
		if allowed {
			if e != nil || len(data) == 0 {
				t.Fatal(e)
			}
		} else if !errors.Is(e, authorization.ErrDenied) {
			t.Fatal("ungranted runtime export allowed", e)
		}
		if _, e = s.ImportPage(ctx, PageImport{}); !errors.Is(e, authorization.ErrDenied) {
			t.Fatal("export enabled page import", e)
		}
	}
}
func TestEditingLeasesEnforceOwnerTabExpiryAndRollback(t *testing.T) {
	s, _ := fixture(t)
	a, b := namedActor("a", "编辑甲"), namedActor("b", "编辑乙")
	selected := LeaseRequest{"client-a", []string{"D3"}}
	if _, e := s.Acquire(a, "electricity", 2026, selected); e != nil {
		t.Fatal(e)
	}
	visible, e := s.Leases(b, "electricity", 2026)
	if e != nil || len(visible) != 1 || visible[0].Name != "编辑甲" {
		t.Fatal(visible, e)
	}
	if _, e = s.Acquire(b, "electricity", 2026, LeaseRequest{"client-b", []string{"D3", "D4"}}); !errors.Is(e, ErrConflict) {
		t.Fatal("conflicting range acquired", e)
	}
	visible, _ = s.Leases(b, "electricity", 2026)
	if len(visible) != 1 {
		t.Fatal("partial range acquired", visible)
	}
	// Even the same authenticated account in another tab must respect the lock.
	if _, e = s.Acquire(a, "electricity", 2026, LeaseRequest{"client-other-tab", []string{"D3"}}); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	patch := Patch{ID: "operation-lock", Client: "client-a", Changes: []Change{{"D3", "文字", 0, nil}}}
	if _, e = s.Patch(b, "electricity", 2026, patch); !errors.Is(e, ErrConflict) {
		t.Fatal("forged client ID accepted", e)
	}
	saved, e := s.Patch(a, "electricity", 2026, patch)
	if e != nil {
		t.Fatal(e)
	}
	cp, e := s.CreateCheckpoint(a, "electricity", 2026, saved.Revision)
	if e != nil {
		t.Fatal(e)
	}
	patch.ID = "operation-second"
	patch.Changes = []Change{{"D3", "新文字", saved.Revision, nil}}
	saved, e = s.Patch(a, "electricity", 2026, patch)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Rollback(b, "electricity", 2026, Rollback{ID: "rollback-locked", Checkpoint: cp.ID, Expected: saved.Revision}); !errors.Is(e, ErrConflict) {
		t.Fatal("rollback ignored active editing lock", e)
	}
	now := s.now()
	s.now = func() time.Time { return now.Add(46 * time.Second) }
	if _, e = s.Patch(a, "electricity", 2026, Patch{ID: "operation-expired", Client: "client-a", Changes: []Change{{"D3", "过期", saved.Revision, nil}}}); !errors.Is(e, ErrConflict) {
		t.Fatal("expired lease accepted", e)
	}
	if _, e = s.Acquire(b, "electricity", 2026, LeaseRequest{"client-b", []string{"D3"}}); e != nil {
		t.Fatal("expired lease not reclaimed", e)
	}
	if _, e = s.Acquire(a, "electricity", 2026, LeaseRequest{Client: "client-a"}); e != nil {
		t.Fatal(e)
	}
	visible, _ = s.Leases(a, "electricity", 2026)
	if len(visible) != 1 || visible[0].Actor != "b" {
		t.Fatal("one client released other's lock", visible)
	}
}
func TestTextAndFormulaEditsExportAndRollback(t *testing.T) {
	s, ctx := fixture(t)
	cp, e := s.CreateCheckpoint(ctx, "electricity", 2026, 0)
	if e != nil {
		t.Fatal(e)
	}
	save(t, s, ctx, "text-change", "D2", "可改的表头", 0)
	v := save(t, s, ctx, "formula-change", "E4", "=SUM(2,3)", 0)
	data, e := s.Export(ctx, "electricity", 2026)
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(data))
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	label, _ := f.GetCellValue("总体报表", "D2")
	formula, _ := f.GetCellFormula("总体报表", "E4")
	value, e := f.CalcCellValue("总体报表", "E4")
	if label != "可改的表头" || formula != "SUM(2,3)" && formula != "=SUM(2,3)" || value != "5" || e != nil {
		t.Fatal(label, formula, value, e)
	}
	if _, e = s.Rollback(ctx, "electricity", 2026, Rollback{ID: "rollback-text-formula", Checkpoint: cp.ID, Expected: v.Revision}); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, "electricity", 2026)
	if e != nil {
		t.Fatal(e)
	}
	for _, c := range d.resolved() {
		if c.R == 1 && c.C == 3 && c.V != "表底" {
			t.Fatal(c)
		}
		if c.R == 3 && c.C == 4 && c.F != `=IF(OR(D4="",D3=""),"",(D4-D3)*D$1)` {
			t.Fatal(c)
		}
	}
	// Plain strings are XLSX strings, not formulas, even when they look like CSV formulas.
	save(t, s, ctx, "literal-text", "D5", "@SUM(1,2)", 0)
	if _, e = s.Export(actor(true, false, true), "electricity", 2026); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("export grant bypassed", e)
	}
}
func TestAutoHeatMeterCannotBeEditedOrLocked(t *testing.T) {
	s, ctx := fixture(t)
	template := testTemplate()
	template.Kind = "heat"
	template.Daily[0].Editable = false
	template.Bindings = []HeatBinding{{Column: 3, Station: "s", Point: "heat", Unit: "GJ"}}
	if e := s.SaveTemplate(ctx, template); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Document(ctx, "heat", 2026); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Acquire(ctx, "heat", 2026, LeaseRequest{"heat-client", []string{"D3"}}); e == nil {
		t.Fatal("automatic reading lock accepted")
	}
	if _, e := s.Patch(ctx, "heat", 2026, Patch{ID: "heat-manual-edit", Client: "heat-client", Changes: []Change{{"D3", "123", 0, nil}}}); e == nil {
		t.Fatal("automatic reading edit accepted")
	}
	if _, e := s.Acquire(ctx, "heat", 2026, LeaseRequest{"heat-client", []string{"E4", "D2"}}); e != nil {
		t.Fatal("heat formulas and labels must remain editable", e)
	}
}

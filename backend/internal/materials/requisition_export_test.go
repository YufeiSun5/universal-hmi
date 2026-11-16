package materials

import (
	"bytes"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
	"image/color"
	"strings"
	"testing"
)

func TestRequisitionExportRequiresCompleteWorkflow(t *testing.T) {
	s := testService(t, false)
	ctx := testContext("exporter", requisitionGrants())
	sign(t, s, ctx, color.NRGBA{A: 255})
	var items []ApplicationExportItem
	for i := 0; i < 2; i++ {
		v := must(s.Submit(ctx, requisitionInput()))(t)
		for _, stage := range []string{"review", "approval", "receipt"} {
			if _, _, e := s.ExportApplication(ctx, v.ID, 0); e == nil {
				t.Fatalf("export accepted at %s", stage)
			}
			if _, _, e := s.ExportApplications(ctx, ApplicationExportInput{Items: append(items, ApplicationExportItem{ID: v.ID, Version: v.Version})}); e == nil {
				t.Fatalf("mixed batch accepted at %s", stage)
			}
			decision := "approved"
			if stage == "receipt" {
				decision = "received"
			}
			v = must(s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: v.Version, Stage: stage, Decision: decision}))(t)
		}
		items = append(items, ApplicationExportItem{ID: v.ID, Version: v.Version})
	}
	data, name, e := s.ExportApplications(ctx, ApplicationExportInput{Items: items})
	if e != nil || !strings.HasSuffix(name, ".xlsx") {
		t.Fatal(name, e)
	}
	f := must(excelize.OpenReader(bytes.NewReader(data)))(t)
	defer f.Close()
	sheets := f.GetSheetList()
	if len(sheets) != 2 {
		t.Fatal(sheets)
	}
	for _, sheet := range sheets {
		if v := must(f.GetCellValue(sheet, requisitionCell(5, newRequisitionGrid(defaultRequisitionTemplate().widths).table[1].first)))(t); v != "弯头" {
			t.Fatal(v)
		}
		cells := must(f.GetPictureCells(sheet))(t)
		count := 0
		for _, cell := range cells {
			count += len(must(f.GetPictures(sheet, cell))(t))
		}
		if count != 4 {
			t.Fatal("missing signatures", sheet, count)
		}
	}
	for _, invalid := range [][]ApplicationExportItem{nil, {items[0], items[0]}, {{ID: items[0].ID, Version: 2}}, {{ID: "missing", Version: 1}}, make([]ApplicationExportItem, 51)} {
		if _, _, e := s.ExportApplications(ctx, ApplicationExportInput{Items: invalid}); e == nil {
			t.Fatal("invalid selection exported", invalid)
		}
	}
	if _, _, e := s.ExportApplications(testContext("denied", authorization.Grants{}), ApplicationExportInput{Items: items}); e == nil {
		t.Fatal("permission bypass")
	}
	rejected := must(s.Submit(ctx, requisitionInput()))(t)
	rejected = must(s.Approve(ctx, rejected.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "review", Decision: "rejected", Reason: "修改"}))(t)
	in := requisitionInput()
	in.ID = rejected.ID
	in.Version = 1
	resubmitted := must(s.Submit(ctx, in))(t)
	if _, _, e := s.ExportApplication(ctx, resubmitted.ID, 1); e == nil {
		t.Fatal("rejected historical version exported")
	}
}

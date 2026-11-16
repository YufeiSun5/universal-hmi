package materials

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"image/color"
	"os"
	"sync"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func requisitionGrants() authorization.Grants {
	g := allGrants()
	g.MaterialsReview = true
	g.MaterialsReceive = true
	return g
}
func requisitionInput() ApplicationInput {
	return ApplicationInput{Mutation: operation(), Workflow: 2, Requisition: Requisition{Project: "隔离测试工程", Contractor: "测试施工单位", Lines: []RequisitionLine{{Name: "弯头", Specification: "DN100", Unit: "个", Quantity: "22", NeededAt: json.RawMessage(`{"说明":"尽快","批次":[1,2]}`)}}}}
}

func TestNewApplicationsCannotBypassFourStages(t *testing.T) {
	s := testService(t, false)
	ctx := testContext("compiler", requisitionGrants())
	in := ApplicationInput{Mutation: operation(), Text: "旧客户端省略workflow"}
	if _, e := s.Submit(ctx, in); !errors.Is(e, ErrSignature) {
		t.Fatal("unsigned compilation accepted", e)
	}
	sign(t, s, ctx, color.NRGBA{A: 255})
	v := must(s.Submit(ctx, in))(t)
	if v.Workflow != 2 || v.Status != "review" {
		t.Fatal("legacy creation bypass", v)
	}
	if _, e := s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}); !errors.Is(e, ErrConflict) {
		t.Fatal("missing stage bypass", e)
	}
	if _, e := s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "receipt", Decision: "received"}); !errors.Is(e, ErrConflict) {
		t.Fatal("skipped approval", e)
	}
	v = must(s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "review", Decision: "approved"}))(t)
	v = must(s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "approval", Decision: "approved"}))(t)
	if _, e := s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "receipt", Decision: "rejected", Reason: "物资无退回动作"}); e == nil {
		t.Fatal("receipt rejected")
	}
}

func TestRequisitionSelfLifecycle(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(fmt.Sprint(pg), func(t *testing.T) {
			s := testService(t, pg)
			ctx := testContext("same-user", requisitionGrants())
			sig := sign(t, s, ctx, color.NRGBA{A: 255})
			in := requisitionInput()
			v := must(s.Submit(ctx, in))(t)
			if v.Status != "review" || len(v.Steps) != 1 || v.Steps[0].SignatureID != sig.AssetID {
				t.Fatalf("submit %+v", v)
			}
			// A retry returns the original result, without generating another application.
			retry := must(s.Submit(ctx, in))(t)
			if retry.ID != v.ID {
				t.Fatal("duplicate submission")
			}
			for _, stage := range []string{"review", "approval", "receipt"} {
				todo := must(s.Applications(ctx, Filter{Status: "todo"}))(t)
				if todo.Total != 1 {
					t.Fatalf("todo at %s: %+v", stage, todo)
				}
				decision := "approved"
				if stage == "receipt" {
					decision = "received"
				}
				v = must(s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: v.Version, Stage: stage, Decision: decision}))(t)
			}
			if v.Status != "closed" || len(v.Steps) != 4 {
				t.Fatalf("close %+v", v)
			}
			for _, step := range v.Steps {
				if step.ActorID != "same-user" || step.SignatureID != sig.AssetID {
					t.Fatal("actor/signature drift")
				}
			}
			if must(s.Applications(ctx, Filter{Status: "todo"}))(t).Total != 0 {
				t.Fatal("closed left in todo")
			}
			detail := must(s.Application(ctx, v.ID, Filter{}))(t)
			if len(detail.Versions) != 1 || string(detail.Application.Requisition.Lines[0].NeededAt) != string(in.Requisition.Lines[0].NeededAt) {
				t.Fatal("JSON lost")
			}
			chain := must(s.Chain(ctx, "application", v.ID, Filter{}))(t)
			if chain.Nodes.Total != 4 {
				t.Fatalf("chain %+v", chain)
			}
			for i, node := range chain.Nodes.Items {
				if len(node.Application.Steps) != 1 || node.Application.Steps[0].ID != v.Steps[i].ID {
					t.Fatal("chain snapshot")
				}
			}
			// Updating the personal signature must not change any historical export.
			sign(t, s, ctx, color.NRGBA{R: 255, A: 255})
			data, _, e := s.ExportApplication(ctx, v.ID, 1)
			if e != nil {
				t.Fatal(e)
			}
			file := must(excelize.OpenReader(bytes.NewReader(data)))(t)
			defer file.Close()
			cells := must(file.GetPictureCells("请购单"))(t)
			pictures := 0
			for _, cell := range cells {
				pictures += len(must(file.GetPictures("请购单", cell))(t))
			}
			if pictures != 4 {
				t.Fatalf("signatures %d", pictures)
			}
			if val := must(file.GetCellValue("请购单", requisitionCell(5, newRequisitionGrid(defaultRequisitionTemplate().widths).table[5].first)))(t); val != string(in.Requisition.Lines[0].NeededAt) {
				t.Fatalf("JSON export %s", val)
			}
			var count int
			if e := s.db.QueryRow("SELECT COUNT(*) FROM materials_documents").Scan(&count); e != nil || count != 0 {
				t.Fatal("receipt wrote inventory", count, e)
			}
			must(Open(s.db, s.files))(t)
			reopened := must(s.Application(ctx, v.ID, Filter{}))(t)
			if len(reopened.Application.Steps) != 4 {
				t.Fatal("restart lost steps")
			}
		})
	}
}

func TestRequisitionReturnConcurrencyAndPermissions(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(fmt.Sprint(pg), func(t *testing.T) { testRequisitionReturnConcurrencyAndPermissions(t, pg) })
	}
}
func testRequisitionReturnConcurrencyAndPermissions(t *testing.T, pg bool) {
	s := testService(t, pg)
	owner := testContext("owner", requisitionGrants())
	sign(t, s, owner, color.NRGBA{A: 255})
	v := must(s.Submit(owner, requisitionInput()))(t)
	reviewOnly := authorization.Grants{MaterialsReview: true}
	reviewers := []string{"reviewer-a", "reviewer-b"}
	for _, name := range reviewers {
		ctx := testContext(name, reviewOnly)
		sign(t, s, ctx, color.NRGBA{A: 255})
		if must(s.Applications(ctx, Filter{Status: "todo"}))(t).Total != 1 {
			t.Fatal("role queue")
		}
	}
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for _, name := range reviewers {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			_, e := s.Approve(testContext(name, reviewOnly), v.ID, ApprovalInput{Mutation: operation(), Version: v.Version, Stage: "review", Decision: "approved"})
			errs <- e
		}(name)
	}
	wg.Wait()
	close(errs)
	success, conflict := 0, 0
	for e := range errs {
		if e == nil {
			success++
		} else if errors.Is(e, ErrConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal(success, conflict)
	}
	if _, e := s.Approve(testContext(reviewers[0], reviewOnly), v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "approval", Decision: "approved"}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("reviewer approved", e)
	}
	v = must(s.Approve(owner, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "approval", Decision: "rejected", Reason: "数量需调整"}))(t)
	in := requisitionInput()
	in.ID = v.ID
	in.Version = 1
	in.Requisition.Lines[0].Quantity = "30"
	v = must(s.Submit(owner, in))(t)
	if v.Version != 2 || v.Status != "review" || len(v.Steps) != 1 {
		t.Fatal("resubmit inherited approvals")
	}
	d := must(s.Application(owner, v.ID, Filter{}))(t)
	if len(d.Versions) != 2 || d.Versions[0].Status != "rejected" || len(d.Versions[0].Steps) != 3 {
		t.Fatal("history lost")
	}
	if _, e := s.Approve(owner, v.ID, ApprovalInput{Mutation: operation(), Version: 1, Stage: "review", Decision: "approved"}); !errors.Is(e, ErrConflict) {
		t.Fatal("stale version", e)
	}
	if _, e := s.Application(testContext("outsider", authorization.Grants{}), v.ID, Filter{}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("ungranted read", e)
	}
	receiver := testContext("receiver", authorization.Grants{MaterialsReceive: true})
	if must(s.Applications(receiver, Filter{}))(t).Total != 1 {
		t.Fatal("all applications invisible")
	}
	if must(s.Applications(receiver, Filter{Status: "todo"}))(t).Total != 0 {
		t.Fatal("wrong stage visible in todo")
	}
	if _, _, e := s.Asset(receiver, d.Versions[0].Steps[0].SignatureID); e != nil {
		t.Fatal("historical signature", e)
	}
	if _, _, e := s.Asset(testContext("outsider", authorization.Grants{}), d.Versions[0].Steps[0].SignatureID); !errors.Is(e, ErrMissing) {
		t.Fatal("signature leaked", e)
	}
}

func TestRequisitionImportDynamicRows(t *testing.T) {
	f := excelize.NewFile()
	defer f.Close()
	sheet := "Sheet1"
	f.MergeCell(sheet, "A3", "G3")
	f.SetCellStr(sheet, "A3", "工程项目名称：测试工程    工程编号：       请购时间:     施工单位:测试单位")
	headers := []any{"序号", "器材名称", "型号与规格", "单位", "数量", "需求时间", "备注"}
	f.SetSheetRow(sheet, "A4", &headers)
	for i := 0; i < 8; i++ {
		row := []any{i + 1, "弯头", "DN100", "个", 22, "有", "保留原文"}
		f.SetSheetRow(sheet, fmt.Sprintf("A%d", i+5), &row)
	}
	for i := 13; i < 30; i++ {
		f.SetCellInt(sheet, fmt.Sprintf("A%d", i), int64(i-4))
	}
	f.SetCellStr(sheet, "A30", "批准：")
	f.SetCellStr(sheet, "C30", "审核：")
	f.SetCellStr(sheet, "E30", "物资：")
	f.SetCellStr(sheet, "G30", "编制：")
	f.NewSheet("空白页")
	b := must(f.WriteToBuffer())(t)
	v := must(parseRequisition(b.Bytes(), ""))(t)
	if len(v.Requisition.Lines) != 8 || v.Requisition.Project != "测试工程" || v.Requisition.Contractor != "测试单位" || v.Requisition.ProjectNumber != "" || v.Requisition.RequestedAt != "" || string(v.Requisition.Lines[0].NeededAt) != `"有"` {
		t.Fatalf("parse %+v", v)
	}
	// The provided customer file is opt-in local evidence and never committed.
	if path := os.Getenv("HMI_REQUISITION_SAMPLE"); path != "" {
		data := must(os.ReadFile(path))(t)
		v := must(parseRequisition(data, ""))(t)
		if len(v.Requisition.Lines) != 8 {
			t.Fatalf("sample lines %d", len(v.Requisition.Lines))
		}
	}
	s := testService(t, false)
	ctx := testContext("compiler", requisitionGrants())
	sign(t, s, ctx, color.NRGBA{A: 255})
	imported := must(s.ImportRequisition(ctx, RequisitionImportInput{AssetInput: AssetInput{Mutation: operation(), Name: "sample.xlsx", Data: b.Bytes()}}))(t)
	vapp := must(s.Submit(ctx, ApplicationInput{Mutation: operation(), Workflow: 2, Requisition: imported.Requisition}))(t)
	reader := testContext("receiver", authorization.Grants{MaterialsReceive: true})
	asset, data, e := s.Asset(reader, vapp.Requisition.AssetIDs[0])
	if e != nil || asset.Kind != "attachment" || !bytes.Equal(data, b.Bytes()) {
		t.Fatal("original attachment", e)
	}
	f.SetCellStr(sheet, "A30", "")
	f.SetCellStr(sheet, "C30", "")
	f.SetCellStr(sheet, "E30", "")
	f.SetCellStr(sheet, "G30", "")
	b = must(f.WriteToBuffer())(t)
	if _, e := parseRequisition(b.Bytes(), ""); e == nil {
		t.Fatal("missing footer silently accepted")
	}
}

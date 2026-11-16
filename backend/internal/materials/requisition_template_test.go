package materials

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/color"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/xuri/excelize/v2"
)

func closeRequisition(t *testing.T, s *Service, in ApplicationInput) Application {
	t.Helper()
	ctx := testContext("template-user", requisitionGrants())
	sign(t, s, ctx, color.NRGBA{A: 255})
	v := must(s.Submit(ctx, in))(t)
	for _, stage := range []string{"review", "approval", "receipt"} {
		decision := "approved"
		if stage == "receipt" {
			decision = "received"
		}
		v = must(s.Approve(ctx, v.ID, ApprovalInput{Mutation: operation(), Version: v.Version, Stage: stage, Decision: decision}))(t)
	}
	return v
}

func TestRequisitionTemplateRoundTrip(t *testing.T) {
	s := testService(t, false)
	ctx := testContext("template-user", requisitionGrants())
	source := excelize.NewFile()
	defer source.Close()
	source.MergeCell("Sheet1", "A2", "G2")
	source.SetCellStr("Sheet1", "A2", "原公司年度物资请购计划表")
	source.MergeCell("Sheet1", "A3", "G3")
	source.SetCellStr("Sheet1", "A3", "工程项目名称：原工程    工程编号：X-10    请购时间：随时    施工单位：施工单位")
	headers := []any{"序号", "器材名称", "型号与规格", "单位", "数量", "需求时间", "备注"}
	source.SetSheetRow("Sheet1", "A4", &headers)
	line := []any{1, "原材料", "DN100", "个", "22", "有", "原备注"}
	source.SetSheetRow("Sheet1", "A5", &line)
	source.SetColWidth("Sheet1", "B", "B", 23)
	style := must(source.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "宋体", Size: 11, Bold: true}, Border: []excelize.Border{{Type: "bottom", Color: "000000", Style: 1}}}))(t)
	source.SetCellStyle("Sheet1", "A4", "G24", style)
	source.SetCellStr("Sheet1", "A25", "批准：")
	source.SetCellStr("Sheet1", "C25", "审核：")
	source.SetCellStr("Sheet1", "E25", "物资：")
	source.SetCellStr("Sheet1", "G25", "编制：")
	sourceBytes := must(source.WriteToBuffer())(t)
	imported := must(s.ImportRequisition(ctx, RequisitionImportInput{AssetInput: AssetInput{Mutation: operation(), Name: "original.xlsx", Data: sourceBytes.Bytes()}}))(t)
	in := ApplicationInput{Mutation: operation(), Requisition: imported.Requisition, Text: "说明不得成为物资行"}
	// Header labels inside a free-form field and every JSON kind survive export.
	in.Requisition.Project = "含 施工单位： 字样的工程"
	values := []json.RawMessage{json.RawMessage(`{"批次":[1,2],"要求":"尽快"}`), json.RawMessage(`["第一批","下周"]`), json.RawMessage(`12.25`), json.RawMessage(`true`), json.RawMessage(`null`), json.RawMessage(`"{\"原文\":1}"`)}
	in.Requisition.Lines = nil
	for i, value := range values {
		in.Requisition.Lines = append(in.Requisition.Lines, RequisitionLine{Name: fmt.Sprintf("物料%d", i), Specification: "DN100", Unit: "个", Quantity: "22.0001", NeededAt: value, Notes: strings.Repeat("长备注", 120)})
	}
	v := closeRequisition(t, s, in)
	for _, status := range []string{"", "closed"} {
		found := must(s.Applications(ctx, Filter{Search: "X-10", Status: status}))(t)
		if found.Total != 1 || found.Items[0].ID != v.ID {
			t.Fatal("project number search", status, found)
		}
		if missing := must(s.Applications(ctx, Filter{Search: "X-99", Status: status}))(t); missing.Total != 0 {
			t.Fatal("wrong project matched", missing)
		}
	}
	data, _, e := s.ExportApplication(ctx, v.ID, 0)
	if e != nil {
		t.Fatal(e)
	}
	book := must(excelize.OpenReader(bytes.NewReader(data)))(t)
	defer book.Close()
	if title := must(book.GetCellValue("请购单", "A2"))(t); title != "原公司年度物资请购计划表" {
		t.Fatal(title)
	}
	if width := must(book.GetColWidth("请购单", "B"))(t); width != 23 {
		t.Fatal("source width lost", width)
	}
	st := must(book.GetStyle(must(book.GetCellStyle("请购单", "B5"))(t)))(t)
	if st.Font == nil || !st.Font.Bold || st.Font.Family != "宋体" {
		t.Fatal("source font lost", st)
	}
	for _, cell := range []string{"A25", "C25", "E25", "G25"} {
		label := must(book.GetCellValue("请购单", cell))(t)
		if !signatureLabel.MatchString(label) {
			t.Fatal("footer layout", cell, label)
		}
	}
	pictures := must(book.GetPictureCells("请购单"))(t)
	if len(pictures) != 4 {
		t.Fatal(pictures)
	}
	for _, cell := range pictures {
		if cell != "A25" && cell != "C25" && cell != "E25" && cell != "G25" {
			t.Fatal("signature not on label row", cell)
		}
	}
	rows := must(book.GetRows("请购单"))(t)
	for _, row := range rows {
		for _, cell := range row {
			if strings.Contains(cell, "template-user") || strings.Contains(cell, "申请单号：") {
				t.Fatal("export contains extra identity text", cell)
			}
		}
	}
	parsed := must(parseRequisition(data, ""))(t)
	if parsed.Requisition.Project != in.Requisition.Project || parsed.Text != in.Text || !reflect.DeepEqual(parsed.Requisition.Lines, in.Requisition.Lines) {
		t.Fatalf("round trip mismatch\n%+v\n%+v", parsed, in)
	}
	// Visible user edits override internal type notes and are never replaced by stale data.
	book.SetCellStr("请购单", "F5", "明天上午")
	book.SetCellStr("请购单", "B5", "用户修改物料")
	book.SetCellStr("请购单", "A3", "工程项目名称：新工程    工程编号：NEW    请购时间：明天    施工单位：新单位")
	edited := must(book.WriteToBuffer())(t)
	again := must(s.ImportRequisition(ctx, RequisitionImportInput{AssetInput: AssetInput{Mutation: operation(), Name: "edited.xlsx", Data: edited.Bytes()}}))(t)
	if again.Requisition.Project != "新工程" || again.Requisition.Lines[0].Name != "用户修改物料" || string(again.Requisition.Lines[0].NeededAt) != `"明天上午"` {
		t.Fatal("edits lost", again)
	}
	fresh := must(s.Submit(ctx, ApplicationInput{Mutation: operation(), Requisition: again.Requisition, Text: again.Text}))(t)
	if fresh.Status != "review" || fresh.Version != 1 || len(fresh.Steps) != 1 {
		t.Fatal("old approvals imported", fresh)
	}
	// The exported file also becomes the next application's presentation template.
	closed := closeRequisition(t, s, ApplicationInput{Mutation: operation(), Requisition: again.Requisition, Text: again.Text})
	batch, _, e := s.ExportApplications(ctx, ApplicationExportInput{Items: []ApplicationExportItem{{ID: v.ID, Version: 1}, {ID: closed.ID, Version: 1}}})
	if e != nil {
		t.Fatal(e)
	}
	choices := must(parseRequisition(batch, ""))(t)
	if len(choices.Sheets) != 2 || choices.Sheet != "" {
		t.Fatal(choices)
	}
	for _, sheet := range choices.Sheets {
		item := must(parseRequisition(batch, sheet))(t)
		if len(item.Requisition.Lines) != len(values) {
			t.Fatal("batch reimport", sheet, item)
		}
	}
}

func TestRequisitionTextOnlyTemplate(t *testing.T) {
	s := testService(t, false)
	ctx := testContext("template-user", requisitionGrants())
	v := closeRequisition(t, s, ApplicationInput{Mutation: operation(), Text: "仅文字申请"})
	data, _, e := s.ExportApplication(ctx, v.ID, 0)
	if e != nil {
		t.Fatal(e)
	}
	parsed := must(parseRequisition(data, ""))(t)
	if len(parsed.Requisition.Lines) != 0 || parsed.Text != v.Text {
		t.Fatal(parsed)
	}
}

func TestRequisitionOriginalSampleRoundTrip(t *testing.T) {
	path := os.Getenv("HMI_REQUISITION_SAMPLE")
	if path == "" {
		t.Skip("local customer sample")
	}
	s := testService(t, false)
	ctx := testContext("template-user", requisitionGrants())
	original := must(os.ReadFile(path))(t)
	imported := must(s.ImportRequisition(ctx, RequisitionImportInput{AssetInput: AssetInput{Mutation: operation(), Name: "sample.xlsx", Data: original}}))(t)
	v := closeRequisition(t, s, ApplicationInput{Mutation: operation(), Requisition: imported.Requisition})
	data, _, e := s.ExportApplication(ctx, v.ID, 0)
	if e != nil {
		t.Fatal(e)
	}
	again := must(parseRequisition(data, ""))(t)
	if len(again.Requisition.Lines) != 8 || !reflect.DeepEqual(again.Requisition.Lines, imported.Requisition.Lines) {
		t.Fatal("customer roundtrip mismatch")
	}
	if out := os.Getenv("HMI_REQUISITION_EXPORT_SAMPLE"); out != "" {
		if e := os.WriteFile(out, data, 0600); e != nil {
			t.Fatal(e)
		}
	}
}

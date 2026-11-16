package materials

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"math"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
)

type RequisitionImportInput struct {
	AssetInput
	Sheet string `json:"sheet,omitempty"`
}
type RequisitionImport struct {
	Requisition Requisition `json:"requisition"`
	Sheets      []string    `json:"sheets"`
	Sheet       string      `json:"sheet"`
	Warnings    []string    `json:"warnings"`
	Asset       *Asset      `json:"asset,omitempty"`
}

var projectLabels = regexp.MustCompile(`(工程项目名称|工程编号|请购时间|施工单位)\s*[:：]\s*`)
var signatureLabel = regexp.MustCompile(`^(批准|审核|物资(?:已阅)?|编制)\s*[:：]`)

func signatureBoundary(row []string) bool {
	for _, value := range row {
		value = strings.TrimSpace(value)
		if value != "" {
			return signatureLabel.MatchString(value)
		}
	}
	return false
}

func parseRequisition(data []byte, chosen string) (RequisitionImport, error) {
	out := RequisitionImport{Sheets: []string{}, Warnings: []string{}}
	if len(data) == 0 || len(data) > MaxImageBytes {
		return out, invalid("Excel最多10 MiB")
	}
	f, e := excelize.OpenReader(bytes.NewReader(data), excelize.Options{UnzipSizeLimit: 64 * 1024 * 1024, UnzipXMLSizeLimit: 8 * 1024 * 1024})
	if e != nil {
		return out, invalid("请选择有效的.xlsx文件")
	}
	defer f.Close()
	type table struct {
		sheet   string
		rows    [][]string
		header  int
		columns map[string]int
	}
	tables := []table{}
	for _, sheet := range f.GetSheetList() {
		if chosen != "" && sheet != chosen {
			continue
		}
		it, e := f.Rows(sheet)
		if e != nil {
			return out, e
		}
		rows := [][]string{}
		header := -1
		columns := map[string]int{}
		for it.Next() {
			if len(rows) >= 2000 {
				it.Close()
				return out, invalid("工作表最多2000行")
			}
			cells, e := it.Columns()
			if e != nil {
				it.Close()
				return out, e
			}
			if len(cells) > 64 {
				it.Close()
				return out, invalid("工作表最多64列")
			}
			rows = append(rows, cells)
			if header >= 0 && signatureBoundary(cells) {
				break
			}
			if header < 0 {
				cols := map[string]int{}
				for col, value := range cells {
					v := strings.Join(strings.Fields(value), "")
					switch v {
					case "器材名称", "物资名称", "物料名称":
						cols["name"] = col
					case "型号与规格", "规格型号", "规格":
						cols["specification"] = col
					case "单位":
						cols["unit"] = col
					case "数量":
						cols["quantity"] = col
					case "需求时间":
						cols["needed_at"] = col
					case "备注":
						cols["notes"] = col
					}
				}
				_, name := cols["name"]
				_, quantity := cols["quantity"]
				if name && quantity {
					header = len(rows) - 1
					columns = cols
				}
			}
		}
		e = it.Error()
		it.Close()
		if e != nil {
			return out, e
		}
		if header >= 0 {
			tables = append(tables, table{sheet, rows, header, columns})
			out.Sheets = append(out.Sheets, sheet)
		}
	}
	if len(tables) == 0 {
		return out, invalid("未识别到器材名称、数量表头")
	}
	if len(tables) > 1 {
		return out, nil
	}
	t := tables[0]
	out.Sheet = t.sheet
	r := Requisition{Lines: []RequisitionLine{}, AssetIDs: []string{}}
	for _, row := range t.rows[:t.header] {
		text := strings.Join(row, " ")
		matches := projectLabels.FindAllStringSubmatchIndex(text, -1)
		for i, m := range matches {
			end := len(text)
			if i+1 < len(matches) {
				end = matches[i+1][0]
			}
			value := strings.TrimSpace(text[m[1]:end])
			switch text[m[2]:m[3]] {
			case "工程项目名称":
				r.Project = value
			case "工程编号":
				r.ProjectNumber = value
			case "请购时间":
				r.RequestedAt = value
			case "施工单位":
				r.Contractor = value
			}
		}
	}
	footer := false
	for i, row := range t.rows[t.header+1:] {
		if signatureBoundary(row) {
			footer = true
			break
		}
		get := func(key string) string {
			col, ok := t.columns[key]
			if !ok || col >= len(row) {
				return ""
			}
			return strings.TrimSpace(row[col])
		}
		l := RequisitionLine{Name: get("name"), Specification: get("specification"), Unit: get("unit"), Quantity: get("quantity"), Notes: get("notes")}
		needed := get("needed_at")
		if l.Name == "" && l.Specification == "" && l.Unit == "" && l.Quantity == "" && l.Notes == "" && needed == "" {
			continue
		}
		l.NeededAt, _ = json.Marshal(needed)
		r.Lines = append(r.Lines, l)
		if l.Name == "" || l.Unit == "" {
			out.Warnings = append(out.Warnings, fmt.Sprintf("原表第%d行名称或单位不完整，请补充", t.header+i+2))
		}
		if _, e := units(l.Quantity, true); e != nil {
			out.Warnings = append(out.Warnings, fmt.Sprintf("原表第%d行数量需要复核", t.header+i+2))
		}
		if len(r.Lines) > 1000 {
			return out, invalid("明细最多1000行")
		}
	}
	if !footer {
		return out, invalid("未找到批准／审核／物资／编制签字区域，请检查工作表")
	}
	if len(r.Lines) == 0 {
		return out, invalid("未找到有效物资明细")
	}
	out.Requisition = r
	return out, nil
}
func (s *Service) ImportRequisition(ctx context.Context, in RequisitionImportInput) (RequisitionImport, error) {
	if _, e := actor(ctx, "request"); e != nil {
		return RequisitionImport{}, e
	}
	if !strings.EqualFold(filepath.Ext(in.Name), ".xlsx") {
		return RequisitionImport{}, invalid("请选择.xlsx文件")
	}
	out, e := parseRequisition(in.Data, in.Sheet)
	if e != nil || out.Sheet == "" {
		return out, e
	}
	in.Kind = "attachment"
	asset, e := s.Upload(ctx, in.AssetInput)
	if e != nil {
		return out, e
	}
	out.Asset = &asset
	out.Requisition.AssetIDs = []string{asset.ID}
	out.Requisition.Attachments = []Asset{asset}
	return out, nil
}

func jsonDisplay(v json.RawMessage) string {
	if len(v) == 0 || string(v) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(v, &text) == nil {
		return text
	}
	return string(v)
}
func exportApplicationTime(value string) string {
	t, e := time.Parse(time.RFC3339Nano, value)
	if e != nil {
		return value
	}
	return t.In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02 15:04")
}
func requisitionStatus(status string) string {
	return map[string]string{"review": "待审核", "approval": "待批准", "receipt": "待物资已阅", "closed": "已闭环", "rejected": "已退回", "pending": "待审批", "approved": "已通过"}[status]
}
func (s *Service) ExportApplication(ctx context.Context, key string, version int64) ([]byte, string, error) {
	detail, e := s.Application(ctx, key, Filter{})
	if e != nil {
		return nil, "", e
	}
	v := detail.Application
	if version > 0 {
		found := false
		for _, old := range detail.Versions {
			if old.Version == version {
				v.ApplicationVersion = old
				found = true
				break
			}
		}
		if !found {
			return nil, "", ErrMissing
		}
	}
	if !applicationExportable(v.ApplicationVersion) {
		return nil, "", invalid("只有走完流程的申请才能导出")
	}
	f := excelize.NewFile()
	defer f.Close()
	if e = f.SetSheetName("Sheet1", "请购单"); e != nil {
		return nil, "", e
	}
	if e = s.writeApplicationSheet(ctx, f, "请购单", v); e != nil {
		return nil, "", e
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, "", e
	}
	return b.Bytes(), fmt.Sprintf("%s-v%d.xlsx", v.Number, v.Version), nil
}

func applicationExportable(v ApplicationVersion) bool {
	return v.Status == "closed" || (v.Workflow != 2 && v.Status == "approved")
}

type ApplicationExportItem struct {
	ID      string `json:"id"`
	Version int64  `json:"version"`
}
type ApplicationExportInput struct {
	Items []ApplicationExportItem `json:"items"`
}

// ExportApplications validates the complete selection before creating a workbook.
// Closed versions are immutable; the selected version prevents stale list exports.
func (s *Service) ExportApplications(ctx context.Context, in ApplicationExportInput) ([]byte, string, error) {
	if len(in.Items) < 1 || len(in.Items) > 50 {
		return nil, "", invalid("请选择1至50张已完成申请")
	}
	seen := map[string]bool{}
	records := make([]Application, 0, len(in.Items))
	lines := 0
	for _, item := range in.Items {
		if e := ctx.Err(); e != nil {
			return nil, "", e
		}
		if item.ID == "" || item.Version < 1 || seen[item.ID] {
			return nil, "", invalid("申请编号或版本无效，不能重复选择")
		}
		seen[item.ID] = true
		detail, e := s.Application(ctx, item.ID, Filter{})
		if e != nil {
			return nil, "", e
		}
		v := detail.Application
		if v.Version != item.Version {
			return nil, "", ErrConflict
		}
		if !applicationExportable(v.ApplicationVersion) {
			return nil, "", invalid("只有走完流程的申请才能导出")
		}
		lines += len(v.Requisition.Lines)
		if lines > 10000 {
			return nil, "", invalid("一次最多导出10000条明细，请分批选择")
		}
		records = append(records, v)
	}
	f := excelize.NewFile()
	defer f.Close()
	for i, v := range records {
		if e := ctx.Err(); e != nil {
			return nil, "", e
		}
		sheet := fmt.Sprintf("%02d-%s", i+1, v.Number)
		if len([]rune(sheet)) > 31 {
			sheet = string([]rune(sheet)[:31])
		}
		var e error
		if i == 0 {
			e = f.SetSheetName("Sheet1", sheet)
		} else {
			_, e = f.NewSheet(sheet)
		}
		if e != nil {
			return nil, "", e
		}
		if e = s.writeApplicationSheet(ctx, f, sheet, v); e != nil {
			return nil, "", e
		}
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, "", e
	}
	return b.Bytes(), "requisitions-" + time.Now().UTC().Format("20060102-150405") + ".xlsx", nil
}

func (s *Service) writeApplicationSheet(ctx context.Context, f *excelize.File, sheet string, v Application) error {
	var first error
	check := func(e error) {
		if first == nil {
			first = e
		}
	}
	put := func(row, col int, text string) {
		cell, _ := excelize.CoordinatesToCellName(col, row)
		check(f.SetCellStr(sheet, cell, text))
	}
	merged := func(row int, text string) {
		check(f.MergeCell(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("G%d", row)))
		put(row, 1, text)
	}
	normal, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 10, Color: "293D4B"}, Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}, Border: []excelize.Border{{Type: "bottom", Color: "D4DDE5", Style: 1}}})
	check(e)
	header, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 10, Bold: true, Color: "293D4B"}, Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"E8EFF5"}}, Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}})
	check(e)
	title, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 19, Bold: true, Color: "293D4B"}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center"}})
	check(e)
	merged(1, "工程物资请购单")
	check(f.SetCellStyle(sheet, "A1", "G1", title))
	check(f.SetRowHeight(sheet, 1, 38))
	merged(2, fmt.Sprintf("申请单号：%s    第%d版    %s", v.Number, v.Version, requisitionStatus(v.Status)))
	merged(3, "工程项目名称："+v.Requisition.Project)
	merged(4, "工程编号："+v.Requisition.ProjectNumber+"    请购时间："+v.Requisition.RequestedAt)
	merged(5, "施工单位："+v.Requisition.Contractor)
	for i, text := range []string{"序号", "器材名称", "型号与规格", "单位", "数量", "需求时间", "备注"} {
		put(6, i+1, text)
	}
	widths := []float64{6, 24, 19, 8, 12, 22, 32}
	for i, w := range widths {
		col, _ := excelize.ColumnNumberToName(i + 1)
		check(f.SetColWidth(sheet, col, col, w))
	}
	row := 7
	for i, l := range v.Requisition.Lines {
		values := []string{strconv.Itoa(i + 1), l.Name, l.Specification, l.Unit, l.Quantity, jsonDisplay(l.NeededAt), l.Notes}
		parts := make([][]exportTextPart, len(values))
		count := 1
		for col, text := range values {
			parts[col] = exportTextParts(text, int(widths[col])-1, 12)
			if len(parts[col]) > count {
				count = len(parts[col])
			}
		}
		for part := 0; part < count; part++ {
			maxLines := 1
			for col, chunks := range parts {
				if part < len(chunks) {
					put(row, col+1, chunks[part].Text)
					if chunks[part].Lines > maxLines {
						maxLines = chunks[part].Lines
					}
				}
			}
			if part == 0 {
				if q, e := strconv.ParseFloat(l.Quantity, 64); e == nil {
					check(f.SetCellValue(sheet, fmt.Sprintf("E%d", row), q))
				}
			}
			check(f.SetRowHeight(sheet, row, math.Max(30, float64(maxLines)*15+10)))
			row++
		}
	}
	for _, part := range exportTextParts("申请说明："+v.Text, 118, 12) {
		merged(row, part.Text)
		check(f.SetRowHeight(sheet, row, math.Max(30, float64(part.Lines)*15+8)))
		row++
	}
	check(f.SetCellStyle(sheet, "A2", fmt.Sprintf("G%d", row), normal))
	check(f.SetCellStyle(sheet, "A6", "G6", header))
	check(f.SetRowHeight(sheet, 6, 28))
	for _, stage := range []struct{ key, label string }{{"compile", "编制"}, {"review", "审核"}, {"approval", "批准"}, {"receipt", "物资已阅"}} {
		var step ApplicationStep
		for _, candidate := range v.Steps {
			if candidate.Stage == stage.key {
				step = candidate
			}
		}
		// Historical single-stage applications retain their actual signature only.
		if v.Workflow != 2 && stage.key == "approval" {
			step = ApplicationStep{Actor: v.Approver, Created: v.Decided, SignatureID: v.SignatureID}
		}
		merged(row, stage.label+"："+step.Actor+"    "+exportApplicationTime(step.Created))
		check(f.SetRowHeight(sheet, row, 26))
		row++
		if step.SignatureID != "" {
			asset, data, e := s.loadAsset(s.db, step.SignatureID)
			if e != nil {
				return e
			}
			cfg, _, e := image.DecodeConfig(bytes.NewReader(data))
			if e != nil {
				return e
			}
			scale := math.Min(145/float64(cfg.Width), 45/float64(cfg.Height))
			check(f.AddPictureFromBytes(sheet, fmt.Sprintf("B%d", row), &excelize.Picture{Extension: "." + strings.TrimPrefix(asset.MIME, "image/"), File: data, Format: &excelize.GraphicOptions{ScaleX: scale, ScaleY: scale, OffsetX: 4, OffsetY: 4}}))
			check(f.SetRowHeight(sheet, row, 42))
			row++
		}
		if step.Decision == "rejected" {
			for _, p := range exportTextParts("退回原因："+step.Reason, 118, 12) {
				merged(row, p.Text)
				check(f.SetRowHeight(sheet, row, math.Max(30, float64(p.Lines)*15+8)))
				row++
			}
		}
	}
	check(f.SetCellStyle(sheet, "A2", fmt.Sprintf("G%d", row-1), normal))
	check(f.SetCellStyle(sheet, "A6", "G6", header))
	for metaRow := 2; metaRow <= 5; metaRow++ {
		text, e := f.GetCellValue(sheet, fmt.Sprintf("A%d", metaRow))
		check(e)
		lines := 1
		for _, part := range exportTextParts(text, 118, 1000) {
			lines = part.Lines
		}
		check(f.SetRowHeight(sheet, metaRow, math.Max(26, float64(lines)*15+8)))
	}
	orientation := "portrait"
	size, fitWidth, fitHeight := 9, 1, 0
	check(f.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight}))
	fit := true
	check(f.SetSheetProps(sheet, &excelize.SheetPropsOptions{FitToPage: &fit}))
	margin, verticalMargin, footer := .3, .4, .2
	check(f.SetPageMargins(sheet, &excelize.PageLayoutMarginsOptions{Left: &margin, Right: &margin, Top: &verticalMargin, Bottom: &verticalMargin, Header: &footer, Footer: &footer}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: fmt.Sprintf("'%s'!$A$1:$G$%d", sheet, row-1), Scope: sheet}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: fmt.Sprintf("'%s'!$6:$6", sheet), Scope: sheet}))
	check(f.SetHeaderFooter(sheet, &excelize.HeaderFooterOptions{OddFooter: "&L" + v.Number + "&R第 &P 页 / 共 &N 页"}))
	if first != nil {
		return first
	}
	return ctx.Err()
}

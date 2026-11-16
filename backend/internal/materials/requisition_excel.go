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
	Text        string      `json:"text,omitempty"`
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
		metadataColumn, e := requisitionMetadataColumn(f, sheet)
		if e != nil {
			return out, e
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
			if metadataColumn > 0 && len(cells) >= metadataColumn {
				cells = cells[:metadataColumn-1]
			}
			rows = append(rows, cells)
			if header < 0 {
				cols := requisitionColumns(cells)
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
	values, e := requisitionValues(f, t.sheet)
	if e != nil {
		return out, e
	}
	r := Requisition{Lines: []RequisitionLine{}, AssetIDs: []string{}, TemplateSheet: t.sheet}
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
	// Exported metadata preserves free-form strings containing header labels.
	// A visible Excel edit invalidates the note and uses the normal parser.
	for i := 0; i < t.header; i++ {
		if note, ok := values[requisitionCell(i+1, 1)]; ok {
			var meta Requisition
			if json.Unmarshal(note.Value, &meta) == nil && len(note.Value) <= 12000 {
				r.Project, r.ProjectNumber, r.RequestedAt, r.Contractor = meta.Project, meta.ProjectNumber, meta.RequestedAt, meta.Contractor
			}
		}
	}
	footer := false
	for i, row := range t.rows[t.header+1:] {
		if signatureBoundary(row) {
			footer = true
			for _, extra := range t.rows[t.header+i+2:] {
				if len(extra) > 0 && strings.HasPrefix(extra[0], "申请说明：") {
					out.Text = strings.TrimPrefix(extra[0], "申请说明：")
					break
				}
			}
			break
		}
		get := func(key string) string {
			col, ok := t.columns[key]
			if !ok || col >= len(row) {
				return ""
			}
			return row[col]
		}
		l := RequisitionLine{Name: get("name"), Specification: get("specification"), Unit: get("unit"), Quantity: get("quantity"), Notes: get("notes")}
		needed := get("needed_at")
		if l.Name == "" && l.Specification == "" && l.Unit == "" && l.Quantity == "" && l.Notes == "" && needed == "" {
			continue
		}
		l.NeededAt, _ = json.Marshal(needed)
		if col, ok := t.columns["needed_at"]; ok {
			if note, found := values[requisitionCell(t.header+i+2, col+1)]; found && len(note.Value) <= 4000 && json.Valid(note.Value) && requisitionJSONMatches(note.Value, needed) {
				l.NeededAt = note.Value
			}
		}
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
		out.Warnings = append(out.Warnings, "模板中没有物资明细，可填写清单或申请说明后提交")
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
	out.Requisition.TemplateAssetID = asset.ID
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
	data, e := finishRequisitionWorkbook(f)
	if e != nil {
		return nil, "", e
	}
	return data, fmt.Sprintf("%s-v%d.xlsx", v.Number, v.Version), nil
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
	data, e := finishRequisitionWorkbook(f)
	if e != nil {
		return nil, "", e
	}
	return data, "requisitions-" + time.Now().UTC().Format("20060102-150405") + ".xlsx", nil
}

func (s *Service) writeApplicationSheet(ctx context.Context, f *excelize.File, sheet string, v Application) error {
	t, e := s.applicationTemplate(v.Requisition)
	if e != nil {
		return e
	}
	grid := newRequisitionGrid(t.widths)
	lastColumn, _ := excelize.ColumnNumberToName(len(grid.widths))
	var first error
	check := func(e error) {
		if first == nil {
			first = e
		}
	}
	put := func(row, col int, text string) { check(f.SetCellStr(sheet, requisitionCell(row, col), text)) }
	merged := func(row int, text string) {
		check(f.MergeCell(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("%s%d", lastColumn, row)))
		put(row, 1, text)
	}
	style := func(raw *excelize.Style) int {
		// Wrap instead of truncating long edited values. Never copy cell formulas.
		copy := *raw
		if raw.Alignment != nil {
			a := *raw.Alignment
			a.WrapText = true
			copy.Alignment = &a
		} else {
			copy.Alignment = &excelize.Alignment{Vertical: "center", WrapText: true}
		}
		id, e := f.NewStyle(&copy)
		check(e)
		return id
	}
	title := *t.titleStyle
	title.Alignment = &excelize.Alignment{Horizontal: "center", Vertical: "center", ShrinkToFit: true}
	titleStyle, e := f.NewStyle(&title)
	check(e)
	metaStyle := style(t.metaStyle)
	merged(2, strings.TrimSpace(t.title))
	check(f.SetCellStyle(sheet, "A2", lastColumn+"2", titleStyle))
	check(f.SetRowHeight(sheet, 2, 36))
	meta := templateMeta(v.Requisition)
	merged(3, meta)
	check(f.SetCellStyle(sheet, "A3", lastColumn+"3", metaStyle))
	check(addRequisitionValue(f, sheet, "A3", meta, Requisition{Project: v.Requisition.Project, ProjectNumber: v.Requisition.ProjectNumber, RequestedAt: v.Requisition.RequestedAt, Contractor: v.Requisition.Contractor}))
	totalWidth := 0.0
	for _, w := range t.widths {
		totalWidth += w
	}
	heightFor := func(text string, width float64) float64 {
		count := 1
		for _, p := range exportTextParts(text, int(width), 10000) {
			count = p.Lines
		}
		return math.Min(409, math.Max(20, float64(count)*14+5))
	}
	check(f.SetRowHeight(sheet, 3, heightFor(meta, totalWidth)))
	if len([]rune(meta)) <= 120 {
		compact := *t.metaStyle
		compact.Alignment = &excelize.Alignment{Vertical: "center", ShrinkToFit: true}
		compactStyle, e := f.NewStyle(&compact)
		check(e)
		check(f.SetCellStyle(sheet, "A3", lastColumn+"3", compactStyle))
		check(f.SetRowHeight(sheet, 3, 22))
	}
	for i, width := range grid.widths {
		col, _ := excelize.ColumnNumberToName(i + 1)
		check(f.SetColWidth(sheet, col, col, width))
	}
	mergeSpan := func(row int, span requisitionSpan) {
		if span.first < span.last {
			check(f.MergeCell(sheet, requisitionCell(row, span.first), requisitionCell(row, span.last)))
		}
	}
	lineStyles := make([]int, 7)
	for i := range t.keys {
		span := grid.table[i]
		mergeSpan(4, span)
		put(4, span.first, t.labels[i])
		check(f.SetCellStyle(sheet, requisitionCell(4, span.first), requisitionCell(4, span.last), style(t.headerStyles[i])))
		lineStyles[i] = style(t.lineStyles[i])
	}
	check(f.SetRowHeight(sheet, 4, 20))
	count := len(v.Requisition.Lines)
	if count < t.minRows {
		count = t.minRows
	}
	if count < 1 {
		count = 1
	}
	for i := 0; i < count; i++ {
		if e := ctx.Err(); e != nil {
			return e
		}
		row := i + 5
		values := map[string]string{"index": strconv.Itoa(i + 1)}
		var l RequisitionLine
		if i < len(v.Requisition.Lines) {
			l = v.Requisition.Lines[i]
			values = map[string]string{"index": strconv.Itoa(i + 1), "name": l.Name, "specification": l.Specification, "unit": l.Unit, "quantity": l.Quantity, "needed_at": jsonDisplay(l.NeededAt), "notes": l.Notes}
		}
		height := math.Max(20, t.rowHeight)
		for col, key := range t.keys {
			span := grid.table[col]
			mergeSpan(row, span)
			cell := requisitionCell(row, span.first)
			put(row, span.first, values[key])
			check(f.SetCellStyle(sheet, cell, requisitionCell(row, span.last), lineStyles[col]))
			height = math.Max(height, heightFor(values[key], t.widths[col]-1))
			if key == "needed_at" && i < len(v.Requisition.Lines) && len(l.NeededAt) > 0 {
				var text string
				if json.Unmarshal(l.NeededAt, &text) != nil || string(l.NeededAt) == "null" {
					check(addRequisitionValue(f, sheet, cell, values[key], l.NeededAt))
				}
			}
		}
		check(f.SetRowHeight(sheet, row, math.Min(409, height)))
	}
	footer := 5 + count
	signatureStyle, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "宋体", Size: 11, Color: "000000"}, Alignment: &excelize.Alignment{Vertical: "center"}})
	check(e)
	check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", footer), fmt.Sprintf("%s%d", lastColumn, footer), signatureStyle))
	check(f.SetRowHeight(sheet, footer, 38))
	for i, stage := range []struct{ key, label string }{{"approval", "批准"}, {"review", "审核"}, {"receipt", "物资"}, {"compile", "编制"}} {
		label, signatureCell := grid.labels[i], grid.signatures[i]
		mergeSpan(footer, label)
		mergeSpan(footer, signatureCell)
		put(footer, label.first, stage.label+"：")
		signature := ""
		for _, step := range v.Steps {
			if step.Stage == stage.key {
				signature = step.SignatureID
			}
		}
		if v.Workflow != 2 && stage.key == "approval" {
			signature = v.SignatureID
		}
		if signature == "" {
			continue
		}
		asset, data, e := s.loadAsset(s.db, signature)
		if e != nil {
			return e
		}
		cfg, _, e := image.DecodeConfig(bytes.NewReader(data))
		if e != nil {
			return e
		}
		scale := math.Min(math.Max(12, math.Min(125, grid.signatureWidth*7-8))/float64(cfg.Width), 40/float64(cfg.Height))
		offsetY := int((38*96/72 - float64(cfg.Height)*scale) / 2)
		check(f.AddPictureFromBytes(sheet, requisitionCell(footer, signatureCell.first), &excelize.Picture{Extension: "." + strings.TrimPrefix(asset.MIME, "image/"), File: data, Format: &excelize.GraphicOptions{ScaleX: scale, ScaleY: scale, OffsetX: 4, OffsetY: offsetY, Positioning: "oneCell"}}))
	}
	end := footer
	if v.Text != "" {
		end += 2
		merged(end, "申请说明："+v.Text)
		check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", end), fmt.Sprintf("%s%d", lastColumn, end), metaStyle))
		check(f.SetRowHeight(sheet, end, heightFor(v.Text, totalWidth)))
	}
	orientation := "portrait"
	size, fitWidth, fitHeight := 9, 1, 0
	check(f.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight}))
	fit := true
	check(f.SetSheetProps(sheet, &excelize.SheetPropsOptions{FitToPage: &fit}))
	margin, verticalMargin := .3, .4
	check(f.SetPageMargins(sheet, &excelize.PageLayoutMarginsOptions{Left: &margin, Right: &margin, Top: &verticalMargin, Bottom: &verticalMargin, Horizontally: &fit}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: fmt.Sprintf("'%s'!$A$2:$%s$%d", sheet, lastColumn, end), Scope: sheet}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: fmt.Sprintf("'%s'!$4:$4", sheet), Scope: sheet}))
	if first != nil {
		return first
	}
	return ctx.Err()
}

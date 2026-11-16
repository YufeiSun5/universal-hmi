package materials

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/xuri/excelize/v2"
)

// Only presentation is copied from an uploaded template: no formulas, links,
// macros, old signatures, or approval state are transferred to the new workbook.
type requisitionTemplate struct {
	title                    string
	keys, labels             []string
	widths                   []float64
	titleStyle, metaStyle    *excelize.Style
	headerStyles, lineStyles []*excelize.Style
	minRows                  int
	rowHeight                float64
}

func requisitionColumns(cells []string) map[string]int {
	cols := map[string]int{}
	for col, value := range cells {
		switch strings.Join(strings.Fields(value), "") {
		case "序号":
			cols["index"] = col
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
	return cols
}

func defaultRequisitionTemplate() requisitionTemplate {
	border := []excelize.Border{}
	for _, side := range []string{"left", "right", "top", "bottom"} {
		border = append(border, excelize.Border{Type: side, Color: "000000", Style: 1})
	}
	line := &excelize.Style{Font: &excelize.Font{Family: "宋体", Size: 11, Color: "000000"}, Border: border, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center", WrapText: true}}
	t := requisitionTemplate{
		title: "工程物资请购计划表", keys: []string{"index", "name", "specification", "unit", "quantity", "needed_at", "notes"},
		labels: []string{"序号", "器材名称", "型号与规格", "单位", "数量", "需求时间", "备注"},
		widths: []float64{8.43, 12, 12.5, 13.87, 11.37, 13.63, 16.5}, minRows: 20, rowHeight: 20,
		titleStyle: &excelize.Style{Font: &excelize.Font{Family: "宋体", Size: 18, Bold: true, Color: "000000"}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center", WrapText: true}},
		metaStyle:  &excelize.Style{Font: &excelize.Font{Family: "宋体", Size: 11, Bold: true, Color: "000000"}, Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}},
	}
	for range t.keys {
		t.headerStyles = append(t.headerStyles, line)
		t.lineStyles = append(t.lineStyles, line)
	}
	return t
}

func (s *Service) applicationTemplate(r Requisition) (requisitionTemplate, error) {
	t := defaultRequisitionTemplate()
	key := r.TemplateAssetID
	if key == "" && len(r.AssetIDs) > 0 {
		key = r.AssetIDs[len(r.AssetIDs)-1]
	}
	if key == "" {
		return t, nil
	}
	_, data, e := s.loadAsset(s.db, key)
	if e != nil {
		return t, e
	}
	parsed, e := parseRequisition(data, r.TemplateSheet)
	if e != nil {
		return t, e
	}
	if parsed.Sheet == "" {
		matches := []string{}
		for _, name := range parsed.Sheets {
			candidate, e := parseRequisition(data, name)
			if e != nil {
				return t, e
			}
			cr := candidate.Requisition
			if cr.Project == r.Project && cr.ProjectNumber == r.ProjectNumber && cr.Contractor == r.Contractor {
				matches = append(matches, name)
			}
		}
		if len(matches) != 1 {
			return t, invalid("无法确定原稿工作表，请重新导入并选择模板页")
		}
		parsed, e = parseRequisition(data, matches[0])
		if e != nil {
			return t, e
		}
	}
	f, e := excelize.OpenReader(bytes.NewReader(data), excelize.Options{UnzipSizeLimit: 64 * 1024 * 1024, UnzipXMLSizeLimit: 8 * 1024 * 1024})
	if e != nil {
		return t, e
	}
	defer f.Close()
	sheet := parsed.Sheet
	rows, e := f.GetRows(sheet)
	if e != nil {
		return t, e
	}
	metadataColumn, e := requisitionMetadataColumn(f, sheet)
	if e != nil {
		return t, e
	}
	if metadataColumn > 0 {
		for i := range rows {
			if len(rows[i]) >= metadataColumn {
				rows[i] = rows[i][:metadataColumn-1]
			}
		}
	}
	header := -1
	cols := map[string]int{}
	for i, row := range rows {
		c := requisitionColumns(row)
		_, name := c["name"]
		_, quantity := c["quantity"]
		if name && quantity {
			header = i
			cols = c
			break
		}
	}
	if header < 0 {
		return t, invalid("模板表头")
	}
	styleAt := func(row, col int) (*excelize.Style, error) {
		cell, _ := excelize.CoordinatesToCellName(col, row)
		id, e := f.GetCellStyle(sheet, cell)
		if e != nil {
			return nil, e
		}
		return f.GetStyle(id)
	}
	for i, row := range rows[:header] {
		for c, value := range row {
			if strings.TrimSpace(value) == "" {
				continue
			}
			if projectLabels.MatchString(value) {
				t.metaStyle, e = styleAt(i+1, c+1)
			} else if t.title == "工程物资请购计划表" {
				t.title = value
				t.titleStyle, e = styleAt(i+1, c+1)
			}
			if e != nil {
				return t, e
			}
		}
	}
	// Keep the source column order, appending optional missing columns.
	sort.SliceStable(t.keys, func(i, j int) bool {
		a, aok := cols[t.keys[i]]
		b, bok := cols[t.keys[j]]
		if !aok {
			return false
		}
		if !bok {
			return true
		}
		return a < b
	})
	labels := map[string]string{"index": "序号", "name": "器材名称", "specification": "型号与规格", "unit": "单位", "quantity": "数量", "needed_at": "需求时间", "notes": "备注"}
	merges, e := f.GetMergeCells(sheet)
	if e != nil {
		return t, e
	}
	for i, key := range t.keys {
		t.labels[i] = labels[key]
		col, ok := cols[key]
		if !ok {
			continue
		}
		t.labels[i] = rows[header][col]
		last := col + 1
		for _, m := range merges {
			startCol, startRow, _ := excelize.CellNameToCoordinates(m.GetStartAxis())
			if startCol == col+1 && startRow == header+1 {
				last, _, _ = excelize.CellNameToCoordinates(m.GetEndAxis())
				break
			}
		}
		t.widths[i] = 0
		for c := col + 1; c <= last; c++ {
			letter, _ := excelize.ColumnNumberToName(c)
			width, e := f.GetColWidth(sheet, letter)
			if e != nil {
				return t, e
			}
			t.widths[i] += width
		}
		if t.widths[i] < 5 {
			t.widths[i] = 5
		}
		if t.widths[i] > 60 {
			t.widths[i] = 60
		}
		t.headerStyles[i], e = styleAt(header+1, col+1)
		if e != nil {
			return t, e
		}
		t.lineStyles[i], e = styleAt(header+2, col+1)
		if e != nil {
			return t, e
		}
	}
	t.rowHeight, e = f.GetRowHeight(sheet, header+2)
	if e != nil {
		return t, e
	}
	t.minRows = 0
	for i := header + 1; i < len(rows); i++ {
		if signatureBoundary(rows[i]) {
			t.minRows = i - header - 1
			break
		}
	}
	if t.minRows > 1000 {
		t.minRows = 1000
	}
	return t, nil
}

type requisitionCellValue struct {
	Schema  string          `json:"schema"`
	Cell    string          `json:"cell"`
	Display string          `json:"display"`
	Value   json.RawMessage `json:"value"`
}

const requisitionValueMarker = "hmi.requisition.values.v1"

func requisitionMetadataColumn(f *excelize.File, sheet string) (int, error) {
	// H is accepted for exports produced before the separate signature grid.
	for _, column := range []int{52, 8} {
		value, e := f.GetCellValue(sheet, requisitionCell(1, column))
		if e != nil {
			return 0, e
		}
		if value == requisitionValueMarker {
			return column, nil
		}
	}
	return 0, nil
}

// Typed free-form JSON is kept in a hidden, non-printing column. It is used only
// while the visible value matches; edits in Excel always take precedence.
func addRequisitionValue(f *excelize.File, sheet, cell, display string, value any) error {
	data, e := json.Marshal(value)
	if e != nil {
		return e
	}
	note, e := json.Marshal(requisitionCellValue{Schema: "hmi.requisition.cell.v1", Cell: cell, Display: display, Value: data})
	if e != nil {
		return e
	}
	_, row, e := excelize.CellNameToCoordinates(cell)
	if e != nil {
		return e
	}
	if e = f.SetCellStr(sheet, "AZ1", requisitionValueMarker); e != nil {
		return e
	}
	if e = f.SetColVisible(sheet, "AZ", false); e != nil {
		return e
	}
	return f.SetCellStr(sheet, fmt.Sprintf("AZ%d", row), string(note))
}

func requisitionValues(f *excelize.File, sheet string) (map[string]requisitionCellValue, error) {
	out := map[string]requisitionCellValue{}
	metadataColumn, e := requisitionMetadataColumn(f, sheet)
	if e != nil {
		return out, e
	}
	if metadataColumn == 0 {
		return out, nil
	}
	rows, e := f.GetRows(sheet)
	if e != nil {
		return out, e
	}
	for i, row := range rows {
		if len(row) < metadataColumn || len(row[metadataColumn-1]) > 32000 {
			continue
		}
		var value requisitionCellValue
		if json.Unmarshal([]byte(row[metadataColumn-1]), &value) != nil || value.Schema != "hmi.requisition.cell.v1" {
			continue
		}
		col, r, e := excelize.CellNameToCoordinates(value.Cell)
		if e != nil || col < 1 || col >= metadataColumn || r != i+1 {
			continue
		}
		visible, e := f.GetCellValue(sheet, value.Cell)
		if e != nil {
			return out, e
		}
		if visible == value.Display {
			out[value.Cell] = value
		}
	}
	return out, nil
}

func requisitionCell(row, col int) string {
	cell, _ := excelize.CoordinatesToCellName(col, row)
	return cell
}

func templateMeta(r Requisition) string {
	return fmt.Sprintf("工程项目名称：%s    工程编号：%s    请购时间：%s    施工单位：%s", r.Project, r.ProjectNumber, r.RequestedAt, r.Contractor)
}

func requisitionJSONMatches(value json.RawMessage, display string) bool {
	if jsonDisplay(value) == display {
		return true
	}
	var left, right bytes.Buffer
	return json.Compact(&left, value) == nil && json.Compact(&right, []byte(display)) == nil && bytes.Equal(left.Bytes(), right.Bytes())
}

// Every exported workbook must fit the same import envelope, including batches.
func finishRequisitionWorkbook(f *excelize.File) ([]byte, error) {
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, e
	}
	if b.Len() > MaxImageBytes {
		return nil, invalid("导出超过10 MiB模板导入上限，请减少批次或缩小签名图片")
	}
	z, e := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
	if e != nil {
		return nil, e
	}
	var size uint64
	for _, file := range z.File {
		size += file.UncompressedSize64
	}
	if size > 64*1024*1024 {
		return nil, invalid("导出内容超过模板导入上限，请分批导出")
	}
	return b.Bytes(), nil
}

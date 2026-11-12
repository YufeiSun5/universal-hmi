package totalreports

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/xuri/excelize/v2"
)

type PageImport struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Sheet string `json:"sheet"`
	Data  string `json:"data"`
}

func validatePage(t Template) error {
	if strings.TrimSpace(t.Name) == "" || len(t.Name) > 120 || t.Rows < 1 || t.Rows > 1000 || t.Columns < 1 || t.Columns > 100 || t.Rows*t.Columns > 30000 || t.HeaderRows != 0 || len(t.Daily) > 0 || len(t.Bindings) > 0 || len(t.InputColumns) > 0 || len(t.Cells) > 30000 || len(t.Formats) > 30000 || len(t.Styles) > 0 {
		return fmt.Errorf("页面尺寸无效（最多1000行、100列、30000格）")
	}
	seen := map[string]bool{}
	for _, c := range t.Cells {
		a := address(c.R, c.C)
		if c.R < 0 || c.R >= t.Rows || c.C < 0 || c.C >= t.Columns || seen[a] {
			return fmt.Errorf("页面单元格越界或重复")
		}
		seen[a] = true
		if c.V != nil {
			switch c.V.(type) {
			case string, float64, int, bool:
			default:
				return fmt.Errorf("单元格内容类型无效")
			}
			if len(fmt.Sprint(c.V)) > 4000 {
				return fmt.Errorf("单元格文本过长：%s", a)
			}
		}
		if c.F != "" && (!strings.HasPrefix(c.F, "=") || !validContent(c.F)) {
			return fmt.Errorf("%s 公式不受支持；请使用本工作表内的公式", a)
		}
	}
	for a, f := range t.Formats {
		c, r, e := excelize.CellNameToCoordinates(a)
		if e != nil || r > t.Rows || c > t.Columns || !validFormat(f) {
			return fmt.Errorf("%s 样式无效", a)
		}
	}
	occupied := map[string]bool{}
	for _, m := range t.Merges {
		if m.R < 0 || m.C < 0 || m.RS < 1 || m.CS < 1 || m.R+m.RS > t.Rows || m.C+m.CS > t.Columns {
			return fmt.Errorf("合并区域越界")
		}
		for r := m.R; r < m.R+m.RS; r++ {
			for c := m.C; c < m.C+m.CS; c++ {
				a := address(r, c)
				if occupied[a] {
					return fmt.Errorf("合并区域重叠")
				}
				occupied[a] = true
			}
		}
	}
	for k, v := range t.Widths {
		c, e := strconv.Atoi(k)
		if e != nil || c < 0 || c >= t.Columns || v < 10 || v > 1000 {
			return fmt.Errorf("列宽无效")
		}
	}
	return nil
}

// ImportPage creates one named, fixed-layout page from the selected worksheet.
// It does not rewrite dates, execute macros, or follow external workbook links.
func (s *Service) ImportPage(ctx context.Context, in PageImport) (string, error) {
	return s.importPage(ctx, in, nil)
}
func (s *Service) importPage(ctx context.Context, in PageImport, history []HistoryBinding) (string, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return "", e
	}
	kind := "page_" + in.ID
	if !customKind.MatchString(kind) || len(in.Data) > 12*1024*1024 {
		return "", fmt.Errorf("页面标识或文件大小无效")
	}
	b, e := base64.StdEncoding.DecodeString(in.Data)
	if e != nil {
		return "", fmt.Errorf("Excel文件编码无效")
	}
	f, e := excelize.OpenReader(bytes.NewReader(b), excelize.Options{UnzipSizeLimit: 64 * 1024 * 1024, UnzipXMLSizeLimit: 16 * 1024 * 1024})
	if e != nil {
		return "", fmt.Errorf("无法读取Excel：%w", e)
	}
	defer f.Close()
	found := false
	for _, name := range f.GetSheetList() {
		if name == in.Sheet {
			found = true
		}
	}
	if !found {
		return "", fmt.Errorf("所选工作表不存在")
	}
	dimension, e := f.GetSheetDimension(in.Sheet)
	if e != nil {
		return "", e
	}
	parts := strings.Split(dimension, ":")
	cols, rows, e := excelize.CellNameToCoordinates(parts[len(parts)-1])
	if e != nil {
		return "", e
	}
	iterator, e := f.Rows(in.Sheet)
	if e != nil {
		return "", e
	}
	defer iterator.Close()
	for n := 1; iterator.Next(); n++ {
		if n > 1000 {
			return "", fmt.Errorf("工作表超过1000行")
		}
		values, err := iterator.Columns(excelize.Options{RawCellValue: true})
		if err != nil {
			return "", err
		}
		rows = max(rows, n)
		cols = max(cols, len(values))
		if cols > 100 || rows*cols > 30000 {
			return "", fmt.Errorf("工作表超过100列或30000格")
		}
	}
	if e = iterator.Error(); e != nil {
		return "", e
	}
	merges, e := f.GetMergeCells(in.Sheet)
	if e != nil {
		return "", e
	}
	for _, m := range merges {
		c, r, err := excelize.CellNameToCoordinates(m.GetEndAxis())
		if err != nil {
			return "", err
		}
		cols = max(cols, c)
		rows = max(rows, r)
	}
	if e != nil || rows > 1000 || cols > 100 || rows*cols > 30000 {
		return "", fmt.Errorf("工作表过大（最多1000行、100列、30000格），请先收紧Excel使用范围")
	}
	t := Template{Kind: kind, Name: strings.TrimSpace(in.Name), Rows: rows, Columns: cols, Widths: map[string]float64{}, Formats: map[string]CellFormat{}}
	styles := map[int]CellFormat{}
	for c := 0; c < cols; c++ {
		col, _ := excelize.ColumnNumberToName(c + 1)
		w, _ := f.GetColWidth(in.Sheet, col)
		t.Widths[strconv.Itoa(c)] = max(10, min(1000, w*7))
	}
	for r := 0; r < rows; r++ {
		for c := 0; c < cols; c++ {
			a := address(r, c)
			v, e := f.GetCellValue(in.Sheet, a, excelize.Options{RawCellValue: true})
			if e != nil {
				return "", e
			}
			formula, e := f.GetCellFormula(in.Sheet, a)
			if e != nil {
				return "", e
			}
			cell := TemplateCell{R: r, C: c}
			if formula != "" {
				cell.F = "=" + strings.TrimPrefix(formula, "=")
			} else if v != "" {
				typ, _ := f.GetCellType(in.Sheet, a)
				if typ == excelize.CellTypeNumber || typ == excelize.CellTypeUnset {
					if n, err := strconv.ParseFloat(v, 64); err == nil {
						cell.V = n
					} else {
						cell.V = v
					}
				} else {
					cell.V = v
				}
			}
			if cell.V != nil || cell.F != "" {
				t.Cells = append(t.Cells, cell)
			}
			id, _ := f.GetCellStyle(in.Sheet, a)
			format, ok := styles[id]
			if !ok {
				style, err := f.GetStyle(id)
				if err != nil {
					return "", err
				}
				format = importFormat(style)
				styles[id] = format
			}
			if len(format) > 0 {
				t.Formats[a] = format
			}
		}
	}
	for _, m := range merges {
		c, r, _ := excelize.CellNameToCoordinates(m.GetStartAxis())
		ec, er, _ := excelize.CellNameToCoordinates(m.GetEndAxis())
		t.Merges = append(t.Merges, Merge{r - 1, c - 1, er - r + 1, ec - c + 1})
	}
	t.History = history
	t.Generic = len(history) > 0
	if e = validateTemplate(t); e != nil {
		return "", e
	}
	original, data, e := prepareOriginal(t, WorkbookUpload{Sheet: in.Sheet, Data: in.Data})
	if e != nil {
		return "", e
	}
	t.Original = original
	// A repeated import ID is a retry, never an overwrite of an existing page.
	raw, e := json.Marshal(t)
	if e != nil {
		return "", e
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return "", e
	}
	defer tx.Rollback()
	if e = storeOriginal(tx, original, data); e != nil {
		return "", e
	}
	if _, e = tx.Exec(`INSERT INTO total_report_templates(kind,data) VALUES(?,?) ON CONFLICT(kind) DO NOTHING`, kind, string(raw)); e != nil {
		return "", e
	}
	return kind, tx.Commit()
}

func importFormat(s *excelize.Style) CellFormat {
	f := CellFormat{}
	if s == nil {
		return f
	}
	color := func(k, v string) {
		v = strings.TrimPrefix(v, "#")
		if len(v) == 8 {
			v = v[2:]
		}
		if formatColor.MatchString("#" + v) {
			f[k] = "#" + v
		}
	}
	if s.Font != nil {
		color("fc", s.Font.Color)
		if s.Font.Family != "" {
			f["ff"] = s.Font.Family
		}
		if s.Font.Size >= 6 && s.Font.Size <= 48 {
			f["fs"] = s.Font.Size
		}
		if s.Font.Bold {
			f["bl"] = float64(1)
		}
		if s.Font.Italic {
			f["it"] = float64(1)
		}
		if s.Font.Strike {
			f["cl"] = float64(1)
		}
		if s.Font.Underline != "" {
			f["un"] = float64(1)
		}
	}
	if len(s.Fill.Color) > 0 {
		color("bg", s.Fill.Color[0])
	}
	if s.CustomNumFmt != nil {
		f["nf"] = *s.CustomNumFmt
	} else {
		switch s.NumFmt {
		case 1:
			f["nf"] = "0"
		case 2:
			f["nf"] = "0.00"
		case 3:
			f["nf"] = "#,##0"
		case 4:
			f["nf"] = "#,##0.00"
		case 9:
			f["nf"] = "0%"
		case 10:
			f["nf"] = "0.00%"
		case 14:
			f["nf"] = "yyyy-mm-dd"
		case 20:
			f["nf"] = "h:mm"
		case 21:
			f["nf"] = "h:mm:ss"
		case 22:
			f["nf"] = "yyyy-mm-dd h:mm"
		}
	}
	if s.Alignment != nil {
		if v, ok := map[string]float64{"center": 0, "left": 1, "right": 2}[s.Alignment.Horizontal]; ok {
			f["ht"] = v
		}
		if v, ok := map[string]float64{"center": 0, "top": 1, "bottom": 2}[s.Alignment.Vertical]; ok {
			f["vt"] = v
		}
		if s.Alignment.WrapText {
			f["tb"] = float64(2)
		}
	}
	return f
}

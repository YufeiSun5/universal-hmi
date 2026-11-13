package totalreports

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/xuri/excelize/v2"
)

// OriginalWorkbook is an immutable reference, frozen with each annual template.
// The XLSX bytes are stored once, not copied into API responses or checkpoints.
type OriginalWorkbook struct {
	ID        string `json:"id"`
	Sheet     string `json:"sheet"`
	RepeatRow int    `json:"repeat_row,omitempty"`
}

// WorkbookUpload is accepted only by developer template/import operations.
// RepeatRow is used only by the three expanding seasonal templates.
type WorkbookUpload struct {
	Sheet     string `json:"sheet"`
	Data      string `json:"data"`
	RepeatRow int    `json:"repeat_row,omitempty"`
}

func openOriginal(data []byte) (*excelize.File, error) {
	return excelize.OpenReader(bytes.NewReader(data), excelize.Options{UnzipSizeLimit: 64 * 1024 * 1024, UnzipXMLSizeLimit: 16 * 1024 * 1024})
}

func prepareOriginal(t Template, in WorkbookUpload) (*OriginalWorkbook, []byte, error) {
	// Seasonal originals can include formatted unused margins outside the
	// editable 30,000-cell report. Preserve those native layout cells without
	// increasing the editable page limit.
	maxCells := 30000
	if t.Rows == 0 || t.OriginalMargins {
		maxCells = 100000
	}
	if len(in.Data) > 12*1024*1024 {
		return nil, nil, fmt.Errorf("原始Excel超过8MiB")
	}
	data, e := base64.StdEncoding.DecodeString(in.Data)
	if e != nil || len(data) == 0 || len(data) > 8*1024*1024 {
		return nil, nil, fmt.Errorf("原始Excel无效或超过8MiB")
	}
	f, e := openOriginal(data)
	if e != nil {
		return nil, nil, fmt.Errorf("无法读取导出原稿：%w", e)
	}
	defer f.Close()
	index, e := f.GetSheetIndex(in.Sheet)
	if e != nil || index < 0 {
		return nil, nil, fmt.Errorf("原稿工作表不存在")
	}
	dim, e := f.GetSheetDimension(in.Sheet)
	if e != nil {
		return nil, nil, e
	}
	parts := strings.Split(dim, ":")
	cols, rows, e := excelize.CellNameToCoordinates(parts[len(parts)-1])
	if e != nil {
		return nil, nil, e
	}
	iterator, e := f.Rows(in.Sheet)
	if e != nil {
		return nil, nil, e
	}
	for n := 1; iterator.Next(); n++ {
		values, err := iterator.Columns(excelize.Options{RawCellValue: true})
		if err != nil {
			iterator.Close()
			return nil, nil, err
		}
		rows, cols = max(rows, n), max(cols, len(values))
		if rows > 1000 || cols > 100 || rows*cols > maxCells {
			iterator.Close()
			return nil, nil, fmt.Errorf("原稿范围超过1000行、100列或30000格")
		}
	}
	e = iterator.Error()
	iterator.Close()
	if e != nil {
		return nil, nil, e
	}
	allMerges, e := f.GetMergeCells(in.Sheet)
	if e != nil {
		return nil, nil, e
	}
	for _, m := range allMerges {
		c, r, err := excelize.CellNameToCoordinates(m.GetEndAxis())
		if err != nil {
			return nil, nil, err
		}
		cols, rows = max(cols, c), max(rows, r)
	}
	if rows > 1000 || cols > 100 || rows*cols > maxCells {
		return nil, nil, fmt.Errorf("原稿范围超过1000行、100列或30000格")
	}
	if t.Rows > 0 {
		if in.RepeatRow != 0 || !t.OriginalMargins && (rows != t.Rows || cols != t.Columns) || t.OriginalMargins && (rows < t.Rows || cols < t.Columns) {
			return nil, nil, fmt.Errorf("原稿行列范围与此页面不一致，请选择最初导入的工作表")
		}
		merges, err := f.GetMergeCells(in.Sheet)
		if err != nil {
			return nil, nil, err
		}
		if t.OriginalMargins {
			selected := []excelize.MergeCell{}
			for _, m := range merges {
				c, r, _ := excelize.CellNameToCoordinates(m.GetStartAxis())
				ec, er, _ := excelize.CellNameToCoordinates(m.GetEndAxis())
				if c <= t.Columns && r <= t.Rows {
					if ec > t.Columns || er > t.Rows {
						return nil, nil, fmt.Errorf("原稿显示范围切断合并格")
					}
					selected = append(selected, m)
				}
			}
			merges = selected
		}
		want := map[string]bool{}
		for _, m := range t.Merges {
			want[address(m.R, m.C)+":"+address(m.R+m.RS-1, m.C+m.CS-1)] = true
		}
		if len(merges) != len(want) {
			return nil, nil, fmt.Errorf("原稿合并区域与此页面不一致")
		}
		for _, m := range merges {
			if !want[m.GetStartAxis()+":"+m.GetEndAxis()] {
				return nil, nil, fmt.Errorf("原稿合并区域与此页面不一致")
			}
		}
	} else if cols < t.Columns || in.RepeatRow <= t.HeaderRows || in.RepeatRow > rows {
		return nil, nil, fmt.Errorf("采暖季原稿缺少有效数据行或列")
	}
	// A page represents one selected worksheet. Remove other sheets once at
	// import, while retaining this sheet's name and its native OOXML features.
	if len(f.GetSheetList()) > 1 {
		for _, name := range f.GetSheetList() {
			if name != in.Sheet {
				if e = f.DeleteSheet(name); e != nil {
					return nil, nil, e
				}
			}
		}
		f.SetActiveSheet(0)
		b, err := f.WriteToBuffer()
		if err != nil {
			return nil, nil, err
		}
		data = b.Bytes()
	}
	return &OriginalWorkbook{ID: digest(data), Sheet: in.Sheet, RepeatRow: in.RepeatRow}, data, nil
}

func storeOriginal(tx *persistence.Tx, ref *OriginalWorkbook, data []byte) error {
	_, e := tx.Exec(`INSERT INTO total_report_originals(id,data) VALUES(?,?) ON CONFLICT(id) DO NOTHING`, ref.ID, data)
	return e
}

func templateLayoutID(t Template) string {
	t.Original, t.Workbook = nil, nil
	return digest(t)
}

// AttachOriginal upgrades old pages without importing or overwriting any cell.
// Matching older annual templates get the same immutable original reference.
func (s *Service) AttachOriginal(ctx context.Context, kind string, in WorkbookUpload) error {
	if _, e := permission(ctx, "template"); e != nil {
		return e
	}
	if _, e := documentKey(kind, 2026); e != nil {
		return e
	}
	var raw string
	if e := s.db.QueryRowContext(ctx, `SELECT data FROM total_report_templates WHERE kind=?`, kind).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			return ErrMissing
		}
		return e
	}
	var t Template
	if e := json.Unmarshal([]byte(raw), &t); e != nil {
		return e
	}
	ref, data, e := prepareOriginal(t, in)
	if e != nil {
		return e
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`UPDATE total_report_templates SET data=data WHERE kind=?`, kind); e != nil {
		return e
	}
	var current string
	if e = tx.QueryRow(`SELECT data FROM total_report_templates WHERE kind=?`, kind).Scan(&current); e != nil {
		return e
	}
	if current != raw {
		return ErrConflict
	}
	if t.Original != nil && t.Original.ID != ref.ID {
		return fmt.Errorf("此页面已保存完整原稿，不能替换为另一份文件")
	}
	if e = storeOriginal(tx, ref, data); e != nil {
		return e
	}
	if e = attachMatchingDocuments(tx, t, ref); e != nil {
		return e
	}
	t.Original = ref
	b, e := json.Marshal(t)
	if e != nil {
		return e
	}
	if _, e = tx.Exec(`UPDATE total_report_templates SET data=? WHERE kind=?`, string(b), kind); e != nil {
		return e
	}
	return tx.Commit()
}

func attachMatchingDocuments(tx *persistence.Tx, template Template, ref *OriginalWorkbook) error {
	rows, e := tx.Query(`SELECT doc,template FROM total_report_docs WHERE doc LIKE ?`, template.Kind+"/%")
	if e != nil {
		return e
	}
	type update struct{ key, raw string }
	updates := []update{}
	want := templateLayoutID(template)
	for rows.Next() {
		var key, raw string
		if e = rows.Scan(&key, &raw); e != nil {
			rows.Close()
			return e
		}
		var old Template
		if e = json.Unmarshal([]byte(raw), &old); e != nil {
			rows.Close()
			return e
		}
		if old.Kind != template.Kind || old.Original != nil || templateLayoutID(old) != want {
			continue
		}
		old.Original = ref
		b, err := json.Marshal(old)
		if err != nil {
			rows.Close()
			return err
		}
		updates = append(updates, update{key, string(b)})
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, u := range updates {
		if _, e = tx.Exec(`UPDATE total_report_docs SET template=?,revision=revision+1 WHERE doc=?`, u.raw, u.key); e != nil {
			return e
		}
	}
	return nil
}

// Export edits the preserved original instead of reconstructing its layout.
func (s *Service) Export(ctx context.Context, kind string, year int) ([]byte, error) {
	if _, e := permission(ctx, "export"); e != nil {
		return nil, e
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return nil, e
	}
	if d.Template.Original == nil {
		return nil, fmt.Errorf("此报表尚未保存完整Excel原稿，请在开发端补充导出原稿后再导出；已有填写内容不会改变")
	}
	var data []byte
	if e = s.db.QueryRowContext(ctx, `SELECT data FROM total_report_originals WHERE id=?`, d.Template.Original.ID).Scan(&data); e != nil {
		return nil, e
	}
	f, e := openOriginal(data)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	name := d.Template.Original.Sheet
	if d.Template.Rows == 0 {
		if e = prepareSeasonWorkbook(f, name, d); e != nil {
			return nil, e
		}
	}
	formats := map[string]CellFormat{}
	for _, cell := range d.Cells {
		formats[cell.Address] = cell.Format
	}
	styleCache := map[string]int{}
	for _, c := range d.resolved() {
		a := address(c.R, c.C)
		// Non-anchor merged cells are not independent input values.
		merged := false
		for _, m := range d.Template.Merges {
			if c.R >= m.R && c.R < m.R+m.RS && c.C >= m.C && c.C < m.C+m.CS && (c.R != m.R || c.C != m.C) {
				merged = true
				break
			}
		}
		if merged {
			continue
		}
		oldFormula, err := f.GetCellFormula(name, a)
		if err != nil {
			return nil, err
		}
		oldValue, err := f.GetCellValue(name, a, excelize.Options{RawCellValue: true})
		if err != nil {
			return nil, err
		}
		value := ""
		if c.V != nil {
			value = fmt.Sprint(c.V)
		}
		if strings.TrimPrefix(oldFormula, "=") != strings.TrimPrefix(c.F, "=") || (c.F == "" && oldValue != value) {
			if oldFormula != "" {
				if e = f.SetCellFormula(name, a, ""); e != nil {
					return nil, e
				}
			}
			if c.F != "" {
				e = f.SetCellFormula(name, a, c.F)
			} else {
				e = f.SetCellValue(name, a, c.V)
			}
			if e != nil {
				return nil, e
			}
		}
		// Only explicitly changed toolbar attributes override the native style.
		// Starting from GetStyle keeps borders, rotation, shrink-to-fit, etc.
		changes := formatChanges(d.Template, c, formats[a])
		if d.Template.Rows == 0 {
			if source, ok := d.Template.cellStyle(c.R, c.C); ok {
				base := CellFormat{"bg": source.BG, "fc": source.FG, "bl": float64(0)}
				if source.Bold {
					base["bl"] = float64(1)
				}
				if source.Size > 0 {
					base["fs"] = source.Size
				}
				for k, v := range changes {
					base[k] = v
				}
				changes = base
			}
		}
		if d.wrapHeader(c) {
			changes["tb"] = float64(2)
			changes["vt"] = float64(0)
		}
		if len(changes) == 0 {
			continue
		}
		id, err := f.GetCellStyle(name, a)
		if err != nil {
			return nil, err
		}
		key := strconv.Itoa(id) + ":" + digest(changes)
		newID, ok := styleCache[key]
		if !ok {
			style, err := f.GetStyle(id)
			if err != nil {
				return nil, err
			}
			applyExportFormat(style, changes)
			newID, e = f.NewStyle(style)
			if e != nil {
				return nil, e
			}
			styleCache[key] = newID
		}
		if e = f.SetCellStyle(name, a, a, newID); e != nil {
			return nil, e
		}
	}
	if e = d.applySeasonalExcelLayout(f, name); e != nil {
		return nil, e
	}
	if e = s.annotateCurrentHistory(ctx, f, name, kind, year, nil); e != nil {
		return nil, e
	}
	full, mode := true, "auto"
	if e = f.SetCalcProps(&excelize.CalcPropsOptions{CalcMode: &mode, FullCalcOnLoad: &full, ForceFullCalc: &full}); e != nil {
		return nil, e
	}
	if _, e = permission(ctx, "export"); e != nil {
		return nil, e
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, e
	}
	return withoutCalculationChain(b.Bytes())
}

func formatChanges(t Template, c TemplateCell, saved CellFormat) CellFormat {
	base := CellFormat{"bg": "#FFFFFF", "fc": "#000000", "ff": "Arial", "fs": float64(11), "bl": float64(0), "it": float64(0), "un": float64(0), "cl": float64(0), "ht": float64(0), "vt": float64(0), "tb": float64(0), "nf": "General"}
	if s, ok := t.cellStyle(c.R, c.C); ok {
		base["bg"], base["fc"] = s.BG, s.FG
		if s.Size > 0 {
			base["fs"] = s.Size
		}
		if s.Bold {
			base["bl"] = float64(1)
		}
	}
	for k, v := range t.Formats[address(c.R, c.C)] {
		base[k] = v
	}
	out := CellFormat{}
	for k, v := range saved {
		if !strings.EqualFold(fmt.Sprint(v), fmt.Sprint(base[k])) {
			out[k] = v
		}
	}
	return out
}

func prepareSeasonWorkbook(f *excelize.File, name string, d Document) error {
	// The original supplies native layout. Only legacy readings/calendar values
	// are cleared; the confirmed seasonal formulas and dates are written below.
	rows, e := f.GetRows(name, excelize.Options{RawCellValue: true})
	if e != nil {
		return e
	}
	for r, row := range rows {
		for c, v := range row {
			a := address(r, c)
			formula, err := f.GetCellFormula(name, a)
			if err != nil {
				return err
			}
			if v == "" && formula == "" {
				continue
			}
			if e = f.SetCellFormula(name, a, ""); e != nil {
				return e
			}
			if e = f.SetCellValue(name, a, nil); e != nil {
				return e
			}
		}
	}
	merges, e := f.GetMergeCells(name)
	if e != nil {
		return e
	}
	for _, m := range merges {
		if e = f.UnmergeCell(name, m.GetStartAxis(), m.GetEndAxis()); e != nil {
			return e
		}
	}
	for _, m := range d.Template.Merges {
		if e = f.MergeCell(name, address(m.R, m.C), address(m.R+m.RS-1, m.C+m.CS-1)); e != nil {
			return e
		}
	}
	from, to := season(d.Year)
	count := d.Template.HeaderRows + int(to.Sub(from).Hours()/24) + 2
	for r := len(rows); r < count; r++ {
		height, err := f.GetRowHeight(name, d.Template.Original.RepeatRow)
		if err != nil {
			return err
		}
		if e = f.SetRowHeight(name, r+1, height); e != nil {
			return e
		}
		for c := 0; c < d.Template.Columns; c++ {
			id, err := f.GetCellStyle(name, address(d.Template.Original.RepeatRow-1, c))
			if err != nil {
				return err
			}
			if e = f.SetCellStyle(name, address(r, c), address(r, c), id); e != nil {
				return e
			}
		}
	}
	return nil
}

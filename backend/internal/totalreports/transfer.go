package totalreports

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
)

// ReportFragment contains only the selected report data, never connection credentials.
type ReportFragment struct {
	Schema   int              `json:"schema"`
	Name     string           `json:"name"`
	Range    string           `json:"range"`
	Whole    bool             `json:"whole"`
	Cells    []Cell           `json:"cells"`
	History  []HistoryBinding `json:"history"`
	Workbook WorkbookUpload   `json:"workbook"`
}
type FragmentImport struct {
	Expected int64          `json:"expected"`
	Fragment ReportFragment `json:"fragment"`
	Target   string         `json:"target"`
	Mode     string         `json:"mode"` // all, format, formula, binding, data
	Confirm  bool           `json:"confirm"`
}
type FragmentPreview struct {
	Range      string   `json:"range"`
	Cells      int      `json:"cells"`
	Overwrites int      `json:"overwrites"`
	Warnings   []string `json:"warnings"`
	Revision   int64    `json:"revision"`
	Digest     string   `json:"digest"`
}

var movableReference = regexp.MustCompile(`(?i)(\$?)([A-Z]{1,3})(\$?)([1-9][0-9]{0,3})`)

func relocateFormula(f string, dr, dc int, source cellRect) (string, []string, error) {
	refs := []string{}
	var invalid error
	// Excel quoted literals (including doubled quotes) are never rewritten.
	parts := quotedFormulaText.FindAllStringIndex(f, -1)
	offset := 0
	var out strings.Builder
	move := func(text string) string {
		var moved strings.Builder
		last := 0
		identifier := func(b byte) bool {
			return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '.' || b == '$'
		}
		for _, location := range movableReference.FindAllStringIndex(text, -1) {
			start, end := location[0], location[1]
			if start > 0 && identifier(text[start-1]) || end < len(text) && (identifier(text[end]) || text[end] == '(') {
				continue
			}
			token := text[start:end]
			m := movableReference.FindStringSubmatch(token)
			c, _ := excelize.ColumnNameToNumber(strings.ToUpper(m[2]))
			r, _ := strconv.Atoi(m[4])
			if !source.contains(r-1, c-1) {
				refs = append(refs, token)
			}
			if m[1] == "" {
				c += dc
			}
			if m[3] == "" {
				r += dr
			}
			if c < 1 || c > 16384 || r < 1 || r > 1048576 {
				invalid = fmt.Errorf("移动公式会产生越界引用：%s", token)
				continue
			}
			col, _ := excelize.ColumnNumberToName(c)
			moved.WriteString(text[last:start])
			moved.WriteString(m[1] + col + m[3] + strconv.Itoa(r))
			last = end
		}
		moved.WriteString(text[last:])
		return moved.String()
	}
	for _, p := range parts {
		out.WriteString(move(f[offset:p[0]]))
		out.WriteString(f[p[0]:p[1]])
		offset = p[1]
	}
	out.WriteString(move(f[offset:]))
	return out.String(), refs, invalid
}

func copyExcelRegion(src *excelize.File, srcSheet string, dst *excelize.File, dstSheet string, region cellRect, dr, dc int, content bool) error {
	styles := map[int]int{}
	for r := region.r0; r <= region.r1; r++ {
		height, e := src.GetRowHeight(srcSheet, r+1)
		if e != nil {
			return e
		}
		if e = dst.SetRowHeight(dstSheet, r+dr+1, height); e != nil {
			return e
		}
		for c := region.c0; c <= region.c1; c++ {
			a, b := address(r, c), address(r+dr, c+dc)
			id, e := src.GetCellStyle(srcSheet, a)
			if e != nil {
				return e
			}
			newID, ok := styles[id]
			if !ok {
				style, e := src.GetStyle(id)
				if e != nil {
					return e
				}
				newID, e = dst.NewStyle(style)
				if e != nil {
					return e
				}
				styles[id] = newID
			}
			if e = dst.SetCellStyle(dstSheet, b, b, newID); e != nil {
				return e
			}
			if content {
				f, e := src.GetCellFormula(srcSheet, a)
				if e != nil {
					return e
				}
				v, e := src.GetCellValue(srcSheet, a, excelize.Options{RawCellValue: true})
				if e != nil {
					return e
				}
				if f != "" {
					f, _, e = relocateFormula(f, dr, dc, region)
					if e != nil {
						return e
					}
					e = dst.SetCellFormula(dstSheet, b, f)
				} else {
					typ, _ := src.GetCellType(srcSheet, a)
					if (typ == excelize.CellTypeNumber || typ == excelize.CellTypeUnset) && v != "" {
						n, err := strconv.ParseFloat(v, 64)
						if err == nil {
							e = dst.SetCellValue(dstSheet, b, n)
						} else {
							e = dst.SetCellStr(dstSheet, b, v)
						}
					} else {
						e = dst.SetCellStr(dstSheet, b, v)
					}
				}
				if e != nil {
					return e
				}
			}
		}
	}
	for c := region.c0; c <= region.c1; c++ {
		col, _ := excelize.ColumnNumberToName(c + 1)
		dest, _ := excelize.ColumnNumberToName(c + dc + 1)
		w, e := src.GetColWidth(srcSheet, col)
		if e != nil {
			return e
		}
		if e = dst.SetColWidth(dstSheet, dest, dest, w); e != nil {
			return e
		}
	}
	merges, e := src.GetMergeCells(srcSheet)
	if e != nil {
		return e
	}
	for _, m := range merges {
		v, e := parseRect(m.GetStartAxis() + ":" + m.GetEndAxis())
		if e != nil {
			return e
		}
		if region.contains(v.r0, v.c0) && region.contains(v.r1, v.c1) {
			if e = dst.MergeCell(dstSheet, address(v.r0+dr, v.c0+dc), address(v.r1+dr, v.c1+dc)); e != nil {
				return e
			}
		}
	}
	conditional, e := src.GetConditionalFormats(srcSheet)
	if e != nil {
		return e
	}
	for area, options := range conditional {
		v, e := parseRect(area)
		if e != nil || !rectIntersects(region, v) {
			continue
		}
		clipped := cellRect{max(region.r0, v.r0), max(region.c0, v.c0), min(region.r1, v.r1), min(region.c1, v.c1)}
		for i := range options {
			if options[i].Format != nil {
				style, e := src.GetConditionalStyle(*options[i].Format)
				if e != nil {
					return e
				}
				id, e := dst.NewConditionalStyle(style)
				if e != nil {
					return e
				}
				options[i].Format = &id
			}
			if options[i].Type == "formula" {
				options[i].Criteria, _, e = relocateFormula(options[i].Criteria, dr+clipped.r0-v.r0, dc+clipped.c0-v.c0, region)
				if e != nil {
					return e
				}
			}
		}
		if e = dst.SetConditionalFormat(dstSheet, address(clipped.r0+dr, clipped.c0+dc)+":"+address(clipped.r1+dr, clipped.c1+dc), options); e != nil {
			return e
		}
	}
	return nil
}

func (s *Service) ExportFragment(ctx context.Context, kind string, year int, selection string) (ReportFragment, error) {
	if _, e := permission(ctx, "export"); e != nil {
		return ReportFragment{}, e
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return ReportFragment{}, e
	}
	whole := selection == ""
	if whole {
		selection = "A1:" + address(templateRows(d.Template, year)-1, d.Template.Columns-1)
	}
	v, e := parseRect(selection)
	if e != nil || v.r1 >= templateRows(d.Template, year) || v.c1 >= d.Template.Columns || v.size() > 30000 {
		return ReportFragment{}, fmt.Errorf("导出区域无效")
	}
	for _, m := range d.Template.Merges {
		if rectIntersects(v, cellRect{m.R, m.C, m.R + m.RS - 1, m.C + m.CS - 1}) && (!v.contains(m.R, m.C) || !v.contains(m.R+m.RS-1, m.C+m.CS-1)) {
			return ReportFragment{}, fmt.Errorf("请完整选择合并区域")
		}
	}
	b, e := s.Export(ctx, kind, year)
	if e != nil {
		return ReportFragment{}, e
	}
	src, e := openOriginal(b)
	if e != nil {
		return ReportFragment{}, e
	}
	defer src.Close()
	name := d.Template.Original.Sheet
	p := ReportFragment{Schema: 1, Name: d.Template.Name, Range: v.text(), Whole: whole, Cells: []Cell{}, History: []HistoryBinding{}}
	formats := map[string]CellFormat{}
	for _, c := range d.Cells {
		formats[c.Address] = c.Format
	}
	for _, c := range d.resolved() {
		if !v.contains(c.R, c.C) {
			continue
		}
		value := ""
		if c.F != "" {
			value = c.F
		} else if c.V != nil {
			value = fmt.Sprint(c.V)
		}
		a := address(c.R, c.C)
		id, _ := src.GetCellStyle(name, a)
		style, e := src.GetStyle(id)
		if e != nil {
			return p, e
		}
		format := importFormat(style)
		for k, val := range formats[a] {
			format[k] = val
		}
		p.Cells = append(p.Cells, Cell{Address: a, Value: value, Format: format})
	}
	for _, binding := range d.Template.History {
		r, _ := parseRect(binding.Range)
		if rectIntersects(v, r) {
			if !v.contains(r.r0, r.c0) || !v.contains(r.r1, r.c1) {
				binding.Range = cellRect{max(v.r0, r.r0), max(v.c0, r.c0), min(v.r1, r.r1), min(v.c1, r.c1)}.text()
				n := max(v.r0-r.r0, v.c0-r.c0)
				if binding.DateCell != "" && !binding.DateFixed {
					cc, rr, _ := excelize.CellNameToCoordinates(binding.DateCell)
					if binding.Direction == "down" {
						rr += n
					} else {
						cc += n
					}
					binding.DateCell = address(rr-1, cc-1)
				} else {
					binding.OffsetDays += n * binding.StepDays
				}
			}
			p.History = append(p.History, binding)
		}
	}
	if whole {
		p.Workbook = WorkbookUpload{Sheet: name, Data: base64.StdEncoding.EncodeToString(b)}
	} else {
		dst := excelize.NewFile()
		defer dst.Close()
		if e = copyExcelRegion(src, name, dst, "Sheet1", v, 0, 0, true); e != nil {
			return p, e
		}
		data, e := dst.WriteToBuffer()
		if e != nil {
			return p, e
		}
		p.Workbook = WorkbookUpload{Sheet: "Sheet1", Data: base64.StdEncoding.EncodeToString(data.Bytes())}
	}
	return p, nil
}
func rectIntersects(a, b cellRect) bool {
	return a.r0 <= b.r1 && a.r1 >= b.r0 && a.c0 <= b.c1 && a.c1 >= b.c0
}

func clearRegionConditions(f *excelize.File, sheet string, dest cellRect) error {
	rules, e := f.GetConditionalFormats(sheet)
	if e != nil {
		return e
	}
	for area, options := range rules {
		v, e := parseRect(area)
		if e != nil {
			return fmt.Errorf("条件格式区域%s暂不支持局部修改，请导入整表副本", area)
		}
		if !rectIntersects(v, dest) {
			continue
		}
		if e = f.UnsetConditionalFormat(sheet, area); e != nil {
			return e
		}
		i := cellRect{max(v.r0, dest.r0), max(v.c0, dest.c0), min(v.r1, dest.r1), min(v.c1, dest.c1)}
		outside := []cellRect{{v.r0, v.c0, i.r0 - 1, v.c1}, {i.r1 + 1, v.c0, v.r1, v.c1}, {i.r0, v.c0, i.r1, i.c0 - 1}, {i.r0, i.c1 + 1, i.r1, v.c1}}
		for _, r := range outside {
			if r.r1 < r.r0 || r.c1 < r.c0 {
				continue
			}
			cloned := append([]excelize.ConditionalFormatOptions(nil), options...)
			for j := range cloned {
				if cloned[j].Type == "formula" {
					cloned[j].Criteria, _, e = relocateFormula(cloned[j].Criteria, r.r0-v.r0, r.c0-v.c0, v)
					if e != nil {
						return e
					}
				}
			}
			if e = f.SetConditionalFormat(sheet, r.text(), cloned); e != nil {
				return e
			}
		}
	}
	return nil
}
func fragmentPlan(d Document, in FragmentImport) (FragmentPreview, []Cell, Template, error) {
	p := FragmentPreview{Warnings: []string{}, Revision: d.Revision, Digest: digest(in)}
	t := d.Template
	if in.Fragment.Schema != 1 || len(in.Fragment.Cells) > 30000 || len(in.Fragment.History) > 64 || len(in.Fragment.Workbook.Data) > 12*1024*1024 {
		return p, nil, t, fmt.Errorf("报表配置文件无效或过大")
	}
	src, e := parseRect(in.Fragment.Range)
	if e != nil {
		return p, nil, t, e
	}
	dest, e := parseRect(in.Target)
	if e != nil {
		return p, nil, t, e
	}
	dr, dc := dest.r0-src.r0, dest.c0-src.c0
	dest.r1 = dest.r0 + src.r1 - src.r0
	dest.c1 = dest.c0 + src.c1 - src.c0
	if dest.r1 >= templateRows(t, d.Year) || dest.c1 >= t.Columns {
		return p, nil, t, fmt.Errorf("导入区域超出当前表格，请选择足够的目标区域")
	}
	p.Range = dest.text()
	format := in.Mode == "all" || in.Mode == "format"
	binding := in.Mode == "all" || in.Mode == "binding"
	formula := in.Mode == "all" || in.Mode == "formula"
	data := in.Mode == "all" || in.Mode == "data"
	if !format && !binding && !formula && !data {
		return p, nil, t, fmt.Errorf("请选择导入内容")
	}
	current := map[string]Cell{}
	for _, c := range d.Cells {
		current[c.Address] = c
	}
	for _, c := range d.resolved() {
		a := address(c.R, c.C)
		if _, ok := current[a]; !ok {
			value := ""
			if c.F != "" {
				value = c.F
			} else if c.V != nil {
				value = fmt.Sprint(c.V)
			}
			current[a] = Cell{Address: a, Value: value}
		}
	}
	if binding {
		next := []HistoryBinding{}
		for _, b := range t.History {
			v, _ := parseRect(b.Range)
			if rectIntersects(v, dest) {
				if !dest.contains(v.r0, v.c0) || !dest.contains(v.r1, v.c1) {
					return p, nil, t, fmt.Errorf("目标区域切断已有绑定，请完整选中或先调整绑定")
				}
				p.Warnings = append(p.Warnings, "目标区域原有历史绑定将替换")
			} else {
				next = append(next, b)
			}
		}
		for i, b := range in.Fragment.History {
			v, e := parseRect(b.Range)
			if e != nil || !src.contains(v.r0, v.c0) || !src.contains(v.r1, v.c1) {
				return p, nil, t, fmt.Errorf("导入绑定超出来源区域")
			}
			b.Range = cellRect{v.r0 + dr, v.c0 + dc, v.r1 + dr, v.c1 + dc}.text()
			b.ID = fmt.Sprintf("import_%d_%s_%d", d.Revision, in.Target, i)
			if b.DateCell != "" {
				var refs []string
				b.DateCell, refs, e = relocateFormula(b.DateCell, dr, dc, src)
				if e != nil {
					return p, nil, t, e
				}
				if len(refs) > 0 {
					p.Warnings = append(p.Warnings, "日期绑定引用区域外单元格："+strings.Join(refs, ","))
				}
			}
			next = append(next, b)
		}
		t.History = next
		if e = validateHistory(t, d.Year); e != nil {
			return p, nil, t, e
		}
	}
	seen := map[string]bool{}
	changes := []Cell{}
	for _, c := range in.Fragment.Cells {
		cc, rr, e := excelize.CellNameToCoordinates(c.Address)
		if e != nil || !src.contains(rr-1, cc-1) || seen[c.Address] || !validContent(c.Value) || !validFormat(c.Format) {
			return p, nil, t, fmt.Errorf("导入单元格内容、格式或身份无效")
		}
		seen[c.Address] = true
		a := address(rr-1+dr, cc-1+dc)
		old := current[a]
		next := old
		next.Address = a
		next.Actor = "configuration"
		next.Revision = d.Revision + 1
		if format {
			next.Format = c.Format
		}
		isFormula := strings.HasPrefix(c.Value, "=")
		if isFormula && formula {
			next.Value, _, e = relocateFormula(c.Value, dr, dc, src)
			if e != nil {
				return p, nil, t, e
			}
			_, refs, _ := relocateFormula(c.Value, dr, dc, src)
			if len(refs) > 0 {
				p.Warnings = append(p.Warnings, c.Address+"引用区域外单元格："+strings.Join(refs, ","))
			}
		} else if !isFormula && data {
			next.Value = c.Value
		}
		if historyOwned(t, rr-1+dr, cc-1+dc) {
			if binding {
				next.Value = ""
			} else if next.Value != old.Value {
				return p, nil, t, fmt.Errorf("%s为自动数据，不能用手填值覆盖", a)
			}
		}
		if next.Value != old.Value || !sameFormat(next.Format, old.Format) || binding || format {
			if old.Value != "" {
				p.Overwrites++
			}
			changes = append(changes, next)
		}
	}
	if len(seen) != src.size() {
		return p, nil, t, fmt.Errorf("配置须包含完整矩形区域，包括空单元格")
	}
	if format {
		p.Warnings = append(p.Warnings, "格式导入会同步目标行高与列宽，对应整行和整列的显示尺寸会随之变化")
		merges := []Merge{}
		for _, m := range t.Merges {
			v := cellRect{m.R, m.C, m.R + m.RS - 1, m.C + m.CS - 1}
			if rectIntersects(v, dest) {
				if !dest.contains(v.r0, v.c0) || !dest.contains(v.r1, v.c1) {
					return p, nil, t, fmt.Errorf("导入区域切断目标合并格")
				}
			} else {
				merges = append(merges, m)
			}
		}
		t.Merges = merges
	}
	sort.Strings(p.Warnings)
	p.Cells = len(changes)
	return p, changes, t, nil
}
func (s *Service) PreviewFragment(ctx context.Context, kind string, year int, in FragmentImport) (FragmentPreview, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if _, e := permission(ctx, "template"); e != nil {
		return FragmentPreview{}, e
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return FragmentPreview{}, e
	}
	p, changes, t, e := fragmentPlan(d, in)
	if e != nil {
		return p, e
	}
	probe := d
	probe.Template = t
	probe.Cells = mergePreviewCells(d.Cells, changes)
	if in.Mode == "all" || in.Mode == "binding" {
		for _, b := range t.History {
			if strings.HasPrefix(b.ID, fmt.Sprintf("import_%d_", d.Revision)) {
				if _, e = s.previewBinding(ctx, probe, b); e != nil {
					return p, e
				}
			}
		}
	}
	if in.Mode == "all" || in.Mode == "format" {
		_, _, _, e = s.fragmentWorkbook(ctx, d, t, in)
	}
	return p, e
}

func mergePreviewCells(current, changes []Cell) []Cell {
	values := map[string]Cell{}
	for _, c := range current {
		values[c.Address] = c
	}
	for _, c := range changes {
		values[c.Address] = c
	}
	out := make([]Cell, 0, len(values))
	for _, c := range values {
		out = append(out, c)
	}
	return out
}
func (s *Service) ApplyFragment(ctx context.Context, kind string, year int, in FragmentImport) (Saved, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	actor, e := permission(ctx, "template")
	if e != nil {
		return Saved{}, e
	}
	if !in.Confirm {
		return Saved{}, fmt.Errorf("请确认导入预览")
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return Saved{}, e
	}
	_, changes, t, e := fragmentPlan(d, in)
	if e != nil {
		return Saved{}, e
	}
	// Resolve every imported binding before modifying the document. Failure is atomic.
	if in.Mode == "all" || in.Mode == "binding" {
		probe := d
		probe.Template = t
		probe.Cells = mergePreviewCells(d.Cells, changes)
		for _, b := range t.History {
			if strings.HasPrefix(b.ID, fmt.Sprintf("import_%d_", d.Revision)) {
				if _, e = s.previewBinding(ctx, probe, b); e != nil {
					return Saved{}, e
				}
			}
		}
	}
	var originalData []byte
	var original *OriginalWorkbook
	if in.Mode == "all" || in.Mode == "format" {
		originalData, original, t, e = s.fragmentWorkbook(ctx, d, t, in)
		if e != nil {
			return Saved{}, e
		}
		t.Original = original
	}
	key, _ := documentKey(kind, year)
	tx, rev, old, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	if rev != in.Expected || rev != d.Revision {
		return Saved{}, ErrConflict
	}
	affected := map[string]bool{}
	for _, c := range changes {
		affected[c.Address] = true
	}
	if e = s.ensureNoLeases(tx, key, affected); e != nil {
		return Saved{}, e
	}
	if e = s.designCheckpoint(tx, key, actor, rev, old); e != nil {
		return Saved{}, e
	}
	if original != nil {
		if e = storeOriginal(tx, original, originalData); e != nil {
			return Saved{}, e
		}
	}
	rev++
	for _, c := range changes {
		c.Revision = rev
		if e = writeCell(tx, key, c); e != nil {
			return Saved{}, e
		}
		if _, e = tx.Exec(`DELETE FROM total_report_readings WHERE doc=? AND address=?`, key, c.Address); e != nil {
			return Saved{}, e
		}
	}
	raw, _ := json.Marshal(t)
	if _, e = tx.Exec(`UPDATE total_report_docs SET revision=?,template=? WHERE doc=?`, rev, string(raw), key); e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "template"); e != nil {
		return Saved{}, e
	}
	return Saved{rev, changes}, tx.Commit()
}

func (s *Service) fragmentWorkbook(ctx context.Context, d Document, t Template, in FragmentImport) ([]byte, *OriginalWorkbook, Template, error) {
	data, e := base64.StdEncoding.DecodeString(in.Fragment.Workbook.Data)
	if e != nil {
		return nil, nil, t, e
	}
	src, e := openOriginal(data)
	if e != nil {
		return nil, nil, t, e
	}
	defer src.Close()
	b, e := s.Export(ctx, d.Kind, d.Year)
	if e != nil {
		return nil, nil, t, e
	}
	dst, e := openOriginal(b)
	if e != nil {
		return nil, nil, t, e
	}
	defer dst.Close()
	v, _ := parseRect(in.Fragment.Range)
	target, _ := parseRect(in.Target)
	source := v
	dr, dc := target.r0-source.r0, target.c0-source.c0
	dest := cellRect{target.r0, target.c0, target.r0 + v.r1 - v.r0, target.c0 + v.c1 - v.c0}
	name := d.Template.Original.Sheet
	if e = clearRegionConditions(dst, name, dest); e != nil {
		return nil, nil, t, e
	}
	merges, e := dst.GetMergeCells(name)
	if e != nil {
		return nil, nil, t, e
	}
	for _, m := range merges {
		r, _ := parseRect(m.GetStartAxis() + ":" + m.GetEndAxis())
		if rectIntersects(r, dest) {
			if e = dst.UnmergeCell(name, m.GetStartAxis(), m.GetEndAxis()); e != nil {
				return nil, nil, t, e
			}
		}
	}
	if e = copyExcelRegion(src, in.Fragment.Workbook.Sheet, dst, name, source, dr, dc, false); e != nil {
		return nil, nil, t, e
	}
	merges, e = src.GetMergeCells(in.Fragment.Workbook.Sheet)
	if e != nil {
		return nil, nil, t, e
	}
	for _, m := range merges {
		r, _ := parseRect(m.GetStartAxis() + ":" + m.GetEndAxis())
		if source.contains(r.r0, r.c0) && source.contains(r.r1, r.c1) {
			t.Merges = append(t.Merges, Merge{r.r0 + dr, r.c0 + dc, r.r1 - r.r0 + 1, r.c1 - r.c0 + 1})
		}
	}
	if t.Widths == nil {
		t.Widths = map[string]float64{}
	}
	if t.Heights == nil {
		t.Heights = map[string]float64{}
	}
	for r := source.r0; r <= source.r1; r++ {
		h, e := src.GetRowHeight(in.Fragment.Workbook.Sheet, r+1)
		if e != nil {
			return nil, nil, t, e
		}
		t.Heights[strconv.Itoa(r+dr)] = max(1, min(1000, h*4/3))
	}
	for c := source.c0; c <= source.c1; c++ {
		col, _ := excelize.ColumnNumberToName(c + 1)
		w, e := src.GetColWidth(in.Fragment.Workbook.Sheet, col)
		if e != nil {
			return nil, nil, t, e
		}
		t.Widths[strconv.Itoa(c+dc)] = w * 7
	}
	buf, e := dst.WriteToBuffer()
	if e != nil {
		return nil, nil, t, e
	}
	result := buf.Bytes()
	id := digest(result)
	return result, &OriginalWorkbook{ID: id, Sheet: name, RepeatRow: d.Template.Original.RepeatRow}, t, nil
}

type FragmentPage struct {
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Fragment ReportFragment `json:"fragment"`
}

func (s *Service) ImportFragmentPage(ctx context.Context, in FragmentPage) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if _, e := permission(ctx, "template"); e != nil {
		return "", e
	}
	p := in.Fragment
	if p.Schema != 1 || !p.Whole {
		return "", fmt.Errorf("新建报表请使用整表配置，局部配置应导入当前报表")
	}
	v, e := parseRect(p.Range)
	if e != nil || v.r0 != 0 || v.c0 != 0 {
		return "", fmt.Errorf("整表配置须从A1开始")
	}
	d := Document{Year: s.now().Year(), Template: Template{Rows: v.r1 + 1, Columns: v.c1 + 1}, Cells: p.Cells}
	_, changes, t, e := fragmentPlan(d, FragmentImport{Fragment: p, Target: "A1", Mode: "all"})
	if e != nil {
		return "", e
	}
	d.Template = t
	d.Cells = changes
	for _, binding := range t.History {
		if _, e = s.previewBinding(ctx, d, binding); e != nil {
			return "", e
		}
	}
	data, e := base64.StdEncoding.DecodeString(p.Workbook.Data)
	if e != nil {
		return "", e
	}
	f, e := openOriginal(data)
	if e != nil {
		return "", e
	}
	defer f.Close()
	for _, c := range changes {
		if strings.HasPrefix(c.Value, "=") {
			e = f.SetCellFormula(p.Workbook.Sheet, c.Address, c.Value)
		} else {
			if e = f.SetCellFormula(p.Workbook.Sheet, c.Address, ""); e != nil {
				return "", e
			}
			if n, err := strconv.ParseFloat(c.Value, 64); err == nil && numeric(c.Value) && c.Value != "" {
				e = f.SetCellValue(p.Workbook.Sheet, c.Address, n)
			} else {
				e = f.SetCellStr(p.Workbook.Sheet, c.Address, c.Value)
			}
		}
		if e != nil {
			return "", e
		}
		id, e := f.GetCellStyle(p.Workbook.Sheet, c.Address)
		if e != nil {
			return "", e
		}
		style, e := f.GetStyle(id)
		if e != nil {
			return "", e
		}
		applyExportFormat(style, c.Format)
		id, e = f.NewStyle(style)
		if e != nil {
			return "", e
		}
		if e = f.SetCellStyle(p.Workbook.Sheet, c.Address, c.Address, id); e != nil {
			return "", e
		}
	}
	buf, e := f.WriteToBuffer()
	if e != nil {
		return "", e
	}
	return s.importPage(ctx, PageImport{ID: in.ID, Name: in.Name, Sheet: p.Workbook.Sheet, Data: base64.StdEncoding.EncodeToString(buf.Bytes())}, t.History, &v)
}

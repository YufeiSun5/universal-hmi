package totalreports

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
)

func season(year int) (time.Time, time.Time) {
	return time.Date(year, 11, 5, 8, 0, 0, 0, time.UTC), time.Date(year+1, 4, 5, 8, 0, 0, 0, time.UTC)
}
func address(r, c int) string { v, _ := excelize.CoordinatesToCellName(c+1, r+1); return v }

var reference = regexp.MustCompile(`(\$?[A-Z]{1,3})(\$?)([1-9][0-9]*)`)
var formulaFunction = regexp.MustCompile(`([A-Z][A-Z0-9_.]*)\(`)
var formulaCharacters = regexp.MustCompile(`^[A-Z0-9_.$:,()+*/<>=!#" \-]+$`)

func translate(formula string, delta int) string {
	return reference.ReplaceAllStringFunc(formula, func(v string) string {
		m := reference.FindStringSubmatch(v)
		if m[2] == "$" {
			return v
		}
		r, _ := strconv.Atoi(m[3])
		return m[1] + strconv.Itoa(r+delta)
	})
}
func expand(t Template, year int) []TemplateCell {
	if t.Rows > 0 {
		return append([]TemplateCell(nil), t.Cells...)
	}
	from, to := season(year)
	count := int(to.Sub(from)/(24*time.Hour)) + 1
	replacements := []string{"{year}", strconv.Itoa(year), "{nextyear}", strconv.Itoa(year + 1), "{first}", strconv.Itoa(t.HeaderRows + 2), "{last}", strconv.Itoa(t.HeaderRows + count + 1)}
	for _, month := range []time.Month{11, 12, 1, 2, 3, 4} {
		first, last := 0, 0
		for d, i := from, 0; !d.After(to); d, i = d.AddDate(0, 0, 1), i+1 {
			if d.Month() == month {
				if first == 0 {
					first = t.HeaderRows + i + 2
				}
				last = t.HeaderRows + i + 2
			}
		}
		replacements = append(replacements, fmt.Sprintf("{m%dfirst}", month), strconv.Itoa(first), fmt.Sprintf("{m%dlast}", month), strconv.Itoa(last))
	}
	replace := strings.NewReplacer(replacements...)
	out := make([]TemplateCell, 0, len(t.Cells)+(count+1)*t.Columns)
	for _, c := range t.Cells {
		c.F = replace.Replace(c.F)
		if v, ok := c.V.(string); ok {
			c.V = replace.Replace(v)
		}
		out = append(out, c)
	}
	// Baseline is visible and explicitly excluded from all seasonal sums.
	for d, i := from.AddDate(0, 0, -1), 0; !d.After(to); d, i = d.AddDate(0, 0, 1), i+1 {
		row := t.HeaderRows + i
		stamp, clock := d, "08:00"
		if t.Kind == "heat" {
			clock = "24:00"
			if i == 0 {
				stamp, clock = from, "00:00"
			}
		}
		for c, v := range []any{int(stamp.Month()), stamp.Day(), clock} {
			out = append(out, TemplateCell{R: row, C: c, V: v})
		}
		for _, c := range t.Daily {
			if i == 0 && c.F != "" {
				continue
			}
			c.F = translate(c.F, row-c.R)
			c.R = row
			c.V = nil
			out = append(out, c)
		}
	}
	return out
}
func editable(t Template, year int) map[string]bool {
	out := map[string]bool{}
	for _, c := range grid(t, year) {
		if c.Editable {
			out[address(c.R, c.C)] = true
		}
	}
	return out
}

// The annual sheet is freely editable, including labels and formulas. Only
// source-owned heat meter readings and non-anchor merged cells remain locked.
func grid(t Template, year int) []TemplateCell {
	from, to := season(year)
	rows := t.HeaderRows + int(to.Sub(from)/(24*time.Hour)) + 2
	if t.Rows > 0 {
		rows = t.Rows
	}
	by := map[string]TemplateCell{}
	for _, c := range expand(t, year) {
		by[address(c.R, c.C)] = c
	}
	inputs := map[int]bool{}
	for _, c := range t.InputColumns {
		inputs[c] = true
	}
	merged := map[string]bool{}
	for _, m := range t.Merges {
		for r := m.R; r < m.R+m.RS; r++ {
			for c := m.C; c < m.C+m.CS; c++ {
				if r != m.R || c != m.C {
					merged[address(r, c)] = true
				}
			}
		}
	}
	out := make([]TemplateCell, 0, rows*t.Columns)
	for r := 0; r < rows; r++ {
		for c := 0; c < t.Columns; c++ {
			a := address(r, c)
			v, ok := by[a]
			if !ok {
				v = TemplateCell{R: r, C: c}
			}
			v.Editable = !(t.Kind == "heat" && r >= t.HeaderRows && ((!t.Generic && inputs[c]) || c < 3)) && !merged[a] && !historyOwned(t, r, c)
			out = append(out, v)
		}
	}
	return out
}

var quotedFormulaText = regexp.MustCompile(`"(?:[^"]|"")*"`)
var editableFormulaCharacters = regexp.MustCompile(`^[A-Z0-9_.$:,()+*/<>=!#" &%\^\-]+$`)

func validContent(v string) bool {
	if len(v) > 4000 || strings.ContainsRune(v, 0) {
		return false
	}
	if !strings.HasPrefix(v, "=") {
		return true
	}
	if len(v) > 1500 {
		return false
	}
	syntax := quotedFormulaText.ReplaceAllString(strings.ToUpper(v), `""`)
	depth := 0
	for _, c := range syntax {
		if c == '(' {
			depth++
			if depth > 64 {
				return false
			}
		}
		if c == ')' {
			depth--
			if depth < 0 {
				return false
			}
		}
	}
	if depth != 0 {
		return false
	}
	if !editableFormulaCharacters.MatchString(syntax) || strings.Contains(strings.ReplaceAll(syntax, "#REF!", ""), "!") {
		return false
	}
	for _, f := range formulaFunction.FindAllStringSubmatch(syntax, -1) {
		switch f[1] {
		case "SUM", "IF", "OR", "AND", "COUNT", "MIN", "MAX", "ABS", "AVERAGE", "IFERROR", "IFNA", "ROUND", "ROUNDUP", "ROUNDDOWN", "COUNTIF", "COUNTIFS", "SUMIF", "SUMIFS", "COUNTA", "COUNTBLANK", "NOT", "MOD", "INT", "SQRT", "POWER", "PRODUCT", "SUBTOTAL", "ISNUMBER", "ISBLANK", "ISTEXT", "ISERROR", "TEXT", "VALUE", "CONCATENATE", "LEFT", "RIGHT", "MID", "LEN", "TRIM", "DATE", "YEAR", "MONTH", "DAY":
		default:
			return false
		}
	}
	return true
}
func (d Document) resolved() []TemplateCell {
	current := map[string]string{}
	for _, c := range d.Cells {
		current[c.Address] = c.Value
	}
	out := grid(d.Template, d.Year)
	for i := range out {
		c := &out[i]
		if raw, ok := current[address(c.R, c.C)]; ok {
			c.F = ""
			c.V = nil
			if strings.HasPrefix(raw, "=") {
				c.F = raw
			} else if raw != "" {
				if numeric(raw) {
					c.V, _ = strconv.ParseFloat(raw, 64)
				} else {
					c.V = raw
				}
			}
		}
	}
	return out
}
func validateTemplate(t Template) error {
	if len(t.Heights) > 1000 {
		return fmt.Errorf("行高数量过多")
	}
	for k, v := range t.Heights {
		r, e := strconv.Atoi(k)
		if e != nil || r < 0 || r >= 1000 || v < 1 || v > 1000 {
			return fmt.Errorf("行高无效")
		}
	}
	if e := validateHistory(t, 2028); e != nil {
		return e
	}
	if _, e := documentKey(t.Kind, 2026); e != nil {
		return e
	}
	if customKind.MatchString(t.Kind) {
		return validatePage(t)
	}
	if t.Rows != 0 || len(t.Formats) != 0 {
		return fmt.Errorf("固定报表模板格式无效")
	}
	if len(t.Name) == 0 || len(t.Name) > 80 || t.Columns < 4 || t.Columns > 80 || t.HeaderRows < 1 || t.HeaderRows > 30 || len(t.Cells) > 2400 || len(t.Daily) > 80 {
		return fmt.Errorf("模板尺寸无效")
	}
	if len(t.Styles) > 2560 {
		return fmt.Errorf("样式数量过多")
	}
	color := regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
	styleKey := regexp.MustCompile(`^(h[0-9]{1,2}_|[bd])[0-9]{1,2}$`)
	for key, style := range t.Styles {
		if !styleKey.MatchString(key) || !color.MatchString(style.BG) || !color.MatchString(style.FG) || style.Size < 0 || style.Size > 48 {
			return fmt.Errorf("模板颜色无效")
		}
	}
	input := map[int]bool{}
	for _, c := range t.InputColumns {
		if c < 3 || c >= t.Columns || input[c] {
			return fmt.Errorf("输入列无效")
		}
		input[c] = true
	}
	seen := map[string]bool{}
	for _, c := range t.Cells {
		if c.R < 0 || c.R >= t.HeaderRows || c.C < 0 || c.C >= t.Columns {
			return fmt.Errorf("表头越界")
		}
		if c.Editable && c.V != nil {
			v := fmt.Sprint(c.V)
			if !numeric(v) {
				return fmt.Errorf("参数须为数值")
			}
		}
	}
	for _, c := range t.Daily {
		if c.C < 3 || c.C >= t.Columns || c.R < 1 || c.R > 9999 {
			return fmt.Errorf("数据行无效")
		}
		if c.F == "" && !input[c.C] {
			return fmt.Errorf("数据行须为公式或输入列")
		}
		if c.Editable && (c.F != "" || t.Kind == "heat") {
			return fmt.Errorf("自动热量或公式不可手填")
		}
	}
	for _, c := range expand(t, 2028) {
		a := address(c.R, c.C)
		if seen[a] {
			return fmt.Errorf("重复单元格%s", a)
		}
		seen[a] = true
		if v, ok := c.V.(string); ok && len(v) > 300 {
			return fmt.Errorf("表头文本过长")
		}
		if c.F != "" {
			if !validContent(c.F) {
				return fmt.Errorf("公式格式无效：%s", a)
			}
			if !strings.HasPrefix(c.F, "=") || len(c.F) > 1500 || !formulaCharacters.MatchString(c.F) {
				return fmt.Errorf("公式格式不受支持：%s", a)
			}
			for _, f := range formulaFunction.FindAllStringSubmatch(c.F, -1) {
				switch f[1] {
				case "SUM", "IF", "OR", "AND", "COUNT", "MIN", "MAX", "ABS":
				default:
					return fmt.Errorf("不支持函数%s", f[1])
				}
			}
			if strings.Contains(strings.ReplaceAll(c.F, "#REF!", ""), "!") {
				return fmt.Errorf("仅支持单张总体表，不能引用其他工作表")
			}
		}
	}
	for _, m := range t.Merges {
		if m.R < 0 || m.C < 0 || m.RS < 1 || m.CS < 1 || m.R+m.RS > t.HeaderRows || m.C+m.CS > t.Columns {
			return fmt.Errorf("合并区域越界")
		}
	}
	bound := map[int]bool{}
	identities := map[string]bool{}
	for _, b := range t.Bindings {
		identity := b.Station + "/" + b.Point
		if t.Kind != "heat" || !input[b.Column] || bound[b.Column] || identities[identity] || len(b.Station) == 0 || len(b.Station) > 32 || len(b.Point) == 0 || len(b.Point) > 128 || b.Unit != "GJ" {
			return fmt.Errorf("热量来源绑定无效或重复")
		}
		bound[b.Column] = true
		identities[identity] = true
	}
	if t.Kind == "heat" && len(bound) != len(input) {
		return fmt.Errorf("每个热量表底列须有独立的来源绑定")
	}
	return nil
}
func (s *Service) SaveTemplate(ctx context.Context, t Template) error {
	if _, e := permission(ctx, "template"); e != nil {
		return e
	}
	if e := validateTemplate(t); e != nil {
		return e
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if t.Workbook != nil {
		ref, data, err := prepareOriginal(t, *t.Workbook)
		if err != nil {
			return err
		}
		if e = storeOriginal(tx, ref, data); e != nil {
			return e
		}
		if e = attachMatchingDocuments(tx, t, ref); e != nil {
			return e
		}
		t.Original, t.Workbook = ref, nil
	} else if t.Original == nil {
		// Older callers can update catalog details without dropping the source.
		var oldRaw string
		e = tx.QueryRow(`SELECT data FROM total_report_templates WHERE kind=?`, t.Kind).Scan(&oldRaw)
		if e != nil && e != sql.ErrNoRows {
			return e
		}
		if e == nil {
			var old Template
			if e = json.Unmarshal([]byte(oldRaw), &old); e != nil {
				return e
			}
			t.Original = old.Original
		}
	}
	if t.Original != nil {
		var exists int
		if e = tx.QueryRow(`SELECT COUNT(*) FROM total_report_originals WHERE id=?`, t.Original.ID).Scan(&exists); e != nil {
			return e
		}
		if exists != 1 {
			return fmt.Errorf("导出原稿不存在，请重新上传原Excel")
		}
	}
	b, e := json.Marshal(t)
	if e != nil {
		return e
	}
	// Replacing a catalog template only affects newly created years. Existing
	// annual documents always keep their frozen layout and formulas.
	if _, e = tx.Exec(`INSERT INTO total_report_templates(kind,data) VALUES(?,?) ON CONFLICT(kind) DO UPDATE SET data=excluded.data`, t.Kind, string(b)); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Service) Catalog(ctx context.Context) ([]map[string]any, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, `SELECT kind,data FROM total_report_templates ORDER BY kind`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var kind, raw string
		var t Template
		if e = rows.Scan(&kind, &raw); e != nil {
			return nil, e
		}
		if e = json.Unmarshal([]byte(raw), &t); e != nil {
			return nil, e
		}
		out = append(out, map[string]any{"kind": kind, "name": t.Name})
	}
	return out, rows.Err()
}
func (s *Service) Document(ctx context.Context, kind string, year int) (Document, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return Document{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return Document{}, e
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return Document{}, e
	}
	defer tx.Rollback()
	var raw string
	var rev int64
	// INSERT SELECT is atomic and cannot replace an existing annual template.
	created, e := tx.Exec(`INSERT INTO total_report_docs(doc,revision,template,checkpoint_revision,checkpoint_at) SELECT ?,0,data,-1,0 FROM total_report_templates WHERE kind=? ON CONFLICT(doc) DO NOTHING`, key, kind)
	if e != nil {
		return Document{}, e
	}
	e = tx.QueryRow(`SELECT revision,template FROM total_report_docs WHERE doc=?`, key).Scan(&rev, &raw)
	if e == sql.ErrNoRows {
		return Document{}, ErrMissing
	}
	if e != nil {
		return Document{}, e
	}
	var t Template
	if e = json.Unmarshal([]byte(raw), &t); e != nil {
		return Document{}, e
	}
	newRows, e := created.RowsAffected()
	if e != nil {
		return Document{}, e
	}
	if newRows == 1 {
		for _, c := range expand(t, year) {
			if c.V != nil || c.F != "" {
				value := fmt.Sprint(c.V)
				if c.F != "" {
					value = c.F
				}
				if _, e = tx.Exec(`INSERT INTO total_report_cells(doc,address,value,revision,actor) VALUES(?,?,?,0,'template')`, key, address(c.R, c.C), value); e != nil {
					return Document{}, e
				}
			}
		}
	}
	if t.Kind == "heat" {
		if rev, e = s.migrateHeatMidnight(tx, key, t, year, rev, newRows == 1); e != nil {
			return Document{}, e
		}
		if !t.Generic {
			t.History = legacyHistory(t, year)
			t.Generic = true
			b, _ := json.Marshal(t)
			if _, e = tx.Exec(`UPDATE total_report_docs SET template=? WHERE doc=?`, string(b), key); e != nil {
				return Document{}, e
			}
		}
	}
	if newRows == 1 {
		for _, b := range t.History {
			v, err := parseRect(b.Range)
			if err != nil {
				return Document{}, err
			}
			for r := v.r0; r <= v.r1; r++ {
				for c := v.c0; c <= v.c1; c++ {
					if _, e = tx.Exec(`INSERT INTO total_report_cells(doc,address,value,revision,actor) VALUES(?,?,'',0,'source') ON CONFLICT(doc,address) DO UPDATE SET value=''`, key, address(r, c)); e != nil {
						return Document{}, e
					}
				}
			}
		}
	}
	cells, e := readCells(tx, key, -1)
	if e != nil {
		return Document{}, e
	}
	if e = tx.Commit(); e != nil {
		return Document{}, e
	}
	_, editErr := permission(ctx, "edit")
	_, rollbackErr := permission(ctx, "rollback")
	_, exportErr := permission(ctx, "export")
	if _, e = permission(ctx, "read"); e != nil {
		return Document{}, e
	}
	return Document{kind, year, rev, t, cells, editErr == nil, rollbackErr == nil, exportErr == nil}, nil
}
func (t Template) cellStyle(r, c int) (CellStyle, bool) {
	key := fmt.Sprintf("d%d", c)
	if r < t.HeaderRows {
		key = fmt.Sprintf("h%d_%d", r, c)
	} else if r == t.HeaderRows {
		key = fmt.Sprintf("b%d", c)
	}
	style, ok := t.Styles[key]
	return style, ok
}
func (d Document) Sheet() map[string]any {
	formats := map[string]CellFormat{}
	for _, cell := range d.Cells {
		formats[cell.Address] = cell.Format
	}
	cells := []map[string]any{}
	chain := []map[string]any{}
	merges := map[string]any{}
	from, to := season(d.Year)
	rows := d.Template.HeaderRows + int(to.Sub(from)/(24*time.Hour)) + 2
	if d.Template.Rows > 0 {
		rows = d.Template.Rows
	}
	for _, c := range d.resolved() {
		val := map[string]any{"v": c.V, "ht": 0, "vt": 0, "fs": 11}
		if c.V != nil {
			val["m"] = fmt.Sprint(c.V)
			typ := "g"
			if _, ok := c.V.(float64); ok {
				typ = "n"
			}
			val["ct"] = map[string]any{"fa": "General", "t": typ}
		}
		if c.F != "" {
			val["f"] = c.F
			val["v"] = nil
			chain = append(chain, map[string]any{"r": c.R, "c": c.C, "id": "total"})
		}
		if c.Editable {
			val["lo"] = 0
		} else {
			val["lo"] = 1
		}
		if c.R < d.Template.HeaderRows {
			val["bg"] = "#e8edf2"
			val["bl"] = 1
		} else if d.Template.Rows == 0 && c.Editable && c.F == "" && c.C >= 3 {
			val["bg"] = "#fff7d6"
		}
		if style, ok := d.Template.cellStyle(c.R, c.C); ok {
			val["bg"] = style.BG
			val["fc"] = style.FG
			val["bl"] = 0
			if style.Size > 0 {
				val["fs"] = style.Size
			}
			if style.Bold {
				val["bl"] = 1
			}
		}
		applyFortuneFormat(val, d.Template.Formats[address(c.R, c.C)])
		applyFortuneFormat(val, formats[address(c.R, c.C)])
		if d.wrapHeader(c) {
			val["tb"] = 2
			val["vt"] = 0
		}
		cells = append(cells, map[string]any{"r": c.R, "c": c.C, "v": val})
	}
	for _, m := range d.Template.Merges {
		merges[fmt.Sprintf("%d_%d", m.R, m.C)] = map[string]any{"r": m.R, "c": m.C, "rs": m.RS, "cs": m.CS}
		for _, cell := range cells {
			r, c := cell["r"].(int), cell["c"].(int)
			if r >= m.R && r < m.R+m.RS && c >= m.C && c < m.C+m.CS {
				val := cell["v"].(map[string]any)
				if r == m.R && c == m.C {
					val["mc"] = merges[fmt.Sprintf("%d_%d", m.R, m.C)]
				} else {
					val["mc"] = map[string]any{"r": m.R, "c": m.C}
					val["v"] = nil
					delete(val, "f")
				}
			}
		}
	}
	widths, heights := d.seasonalLayout()
	return map[string]any{"id": "total", "name": d.Template.Name, "row": rows, "column": d.Template.Columns, "celldata": cells, "calcChain": chain, "defaultColWidth": 100, "defaultRowHeight": 28, "config": map[string]any{"columnlen": widths, "rowlen": heights, "merge": merges}}
}

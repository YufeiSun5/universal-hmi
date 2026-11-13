package materials

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/xuri/excelize/v2"
	"golang.org/x/text/width"
)

// Export reads immutable prices and signatures. Downloads never post inventory.
func (s *Service) Export(ctx context.Context, key string) ([]byte, string, error) {
	if _, e := actor(ctx, "outbound"); e != nil {
		return nil, "", e
	}
	d, e := getDocument(s.db, key)
	if e != nil {
		return nil, "", e
	}
	if d.Kind != "outbound" {
		return nil, "", ErrMissing
	}
	f := excelize.NewFile()
	defer f.Close()
	sheet := "出库单"
	if e = f.SetSheetName("Sheet1", sheet); e != nil {
		return nil, "", e
	}
	var first error
	check := func(e error) {
		if first == nil {
			first = e
		}
	}
	put := func(cell, value string) { check(f.SetCellStr(sheet, cell, value)) }
	merge := func(a, b string) { check(f.MergeCell(sheet, a, b)) }
	newStyle := func(style *excelize.Style) int { id, e := f.NewStyle(style); check(e); return id }
	border := []excelize.Border{{Type: "bottom", Color: "DCE4EC", Style: 1}, {Type: "left", Color: "E6ECF1", Style: 1}, {Type: "right", Color: "E6ECF1", Style: 1}}
	rowStyles := []int{}
	numberStyles := []int{}
	centerStyles := []int{}
	for _, fill := range []string{"FFFFFF", "F5F8FB"} {
		rowStyles = append(rowStyles, newStyle(&excelize.Style{
			Font:      &excelize.Font{Family: "Microsoft YaHei", Size: 10, Color: "243B50"},
			Fill:      excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{fill}},
			Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}, Border: border,
		}))
		for _, alignment := range []string{"right", "center"} {
			style := newStyle(&excelize.Style{
				Font:      &excelize.Font{Family: "Microsoft YaHei", Size: 10, Color: "243B50"},
				Fill:      excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{fill}},
				Alignment: &excelize.Alignment{Horizontal: alignment, Vertical: "center", WrapText: true}, Border: border,
			})
			if alignment == "right" {
				numberStyles = append(numberStyles, style)
			} else {
				centerStyles = append(centerStyles, style)
			}
		}
	}
	title := newStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 20, Bold: true, Color: "173B58"}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center"}})
	meta := newStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 9, Color: "52677B"}, Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}})
	header := newStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 10, Bold: true, Color: "24465E"}, Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"E8EFF5"}}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center", WrapText: true}, Border: border})
	summary := newStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 11, Bold: true, Color: "173B58"}, Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"EAF1F7"}}, Alignment: &excelize.Alignment{Horizontal: "right", Vertical: "center", WrapText: true}, Border: border})
	textStyle := newStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 10, Color: "243B50"}, Alignment: &excelize.Alignment{Vertical: "top", WrapText: true}, Border: []excelize.Border{{Type: "bottom", Color: "E3EAF0", Style: 1}}})
	widths := []float64{4.5, 21, 15, 15, 5, 9, 10, 12, 8}
	for i, w := range widths {
		col, _ := excelize.ColumnNumberToName(i + 1)
		check(f.SetColWidth(sheet, col, col, w))
	}
	merge("A1", "I1")
	put("A1", "物料出库单")
	check(f.SetCellStyle(sheet, "A1", "I1", title))
	check(f.SetRowHeight(sheet, 1, 38))
	merge("A2", "E2")
	put("A2", "单号  "+d.Number)
	merge("F2", "I2")
	created := d.Created
	if at, e := time.Parse(time.RFC3339Nano, d.Created); e == nil {
		created = at.In(time.FixedZone("UTC+8", 8*60*60)).Format("2006-01-02 15:04")
	}
	put("F2", "办理时间  "+created)
	check(f.SetCellStyle(sheet, "A2", "I2", meta))
	check(f.SetRowHeight(sheet, 2, 28))
	check(f.SetRowHeight(sheet, 3, 8))
	for i, v := range []string{"序号", "物料名称", "规格", "分类", "单位", "数量", "单价", "金额", "说明"} {
		cell, _ := excelize.CoordinatesToCellName(i+1, 4)
		put(cell, v)
	}
	check(f.SetCellStyle(sheet, "A4", "I4", header))
	check(f.SetRowHeight(sheet, 4, 28))
	row := 5
	for i, l := range d.Lines {
		values := []string{strconv.Itoa(i + 1), l.Name, l.Specification, l.Category, l.Unit, l.Quantity, l.Price, l.Amount, ""}
		if l.Price == "" {
			values[8] = "单价未填"
		}
		columns := make([][]exportTextPart, len(values))
		segments := 1
		for c, v := range values {
			columns[c] = exportTextParts(v, int(widths[c]-1), 12)
			segments = max(segments, len(columns[c]))
		}
		for part := 0; part < segments; part++ {
			lines := 1
			for c, parts := range columns {
				value := ""
				if part < len(parts) {
					value = parts[part].Text
					lines = max(lines, parts[part].Lines)
				}
				if c == 0 && part > 0 {
					value = strconv.Itoa(i+1) + "续"
				}
				cell, _ := excelize.CoordinatesToCellName(c+1, row)
				put(cell, value)
			}
			check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row), rowStyles[i%2]))
			check(f.SetCellStyle(sheet, fmt.Sprintf("F%d", row), fmt.Sprintf("H%d", row), numberStyles[i%2]))
			for _, col := range []string{"A", "E"} {
				cell := fmt.Sprintf("%s%d", col, row)
				check(f.SetCellStyle(sheet, cell, cell, centerStyles[i%2]))
			}
			check(f.SetRowHeight(sheet, row, math.Max(30, float64(lines)*15+8)))
			row++
		}
	}
	label := "合计金额  " + d.KnownAmount
	if d.MissingPrices > 0 {
		label = fmt.Sprintf("已知金额小计  %s  ·  缺价 %d 行，非完整总金额", d.KnownAmount, d.MissingPrices)
	}
	merge(fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row))
	put(fmt.Sprintf("A%d", row), label)
	check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row), summary))
	check(f.SetRowHeight(sheet, row, 30))
	row++
	// Excel cannot auto-size merged cells. Bounded continuation rows prevent its
	// fixed row-height limit from hiding long descriptions or splitting them off.
	for _, field := range []struct{ Label, Value string }{{"用途", d.Purpose}, {"领料人", d.Recipient}, {"备注", d.Notes}} {
		value := field.Value
		if value == "" {
			value = "—"
		}
		for _, part := range exportTextParts(field.Label+"："+value, 94, 10) {
			merge(fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row))
			put(fmt.Sprintf("A%d", row), part.Text)
			check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row), textStyle))
			check(f.SetRowHeight(sheet, row, math.Max(26, float64(part.Lines)*15+8)))
			row++
		}
	}
	check(f.SetRowHeight(sheet, row, 10))
	row++
	merge(fmt.Sprintf("A%d", row), fmt.Sprintf("E%d", row))
	put(fmt.Sprintf("A%d", row), "出库经办人："+d.Owner)
	merge(fmt.Sprintf("F%d", row), fmt.Sprintf("I%d", row))
	put(fmt.Sprintf("F%d", row), "经办人签名")
	check(f.SetCellStyle(sheet, fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row), textStyle))
	asset, data, e := loadAsset(s.db, d.SignatureID)
	if e != nil {
		return nil, "", e
	}
	cfg, _, e := image.DecodeConfig(bytes.NewReader(data))
	if e != nil {
		return nil, "", e
	}
	scale := min(120/float64(cfg.Width), 40/float64(cfg.Height))
	ownerLines := exportTextParts("出库经办人："+d.Owner, 56, 1000)[0].Lines
	check(f.SetRowHeight(sheet, row, math.Max(58, float64(ownerLines)*15+8)))
	check(f.AddPictureFromBytes(sheet, fmt.Sprintf("F%d", row), &excelize.Picture{Extension: "." + strings.TrimPrefix(asset.MIME, "image/"), File: data, Format: &excelize.GraphicOptions{ScaleX: scale, ScaleY: scale, OffsetX: 8, OffsetY: 22}}))
	orientation, size, fitWidth, fitHeight := "portrait", 9, 1, 0
	fit := true
	check(f.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight}))
	check(f.SetSheetProps(sheet, &excelize.SheetPropsOptions{FitToPage: &fit}))
	margin, verticalMargin, footer := .3, .4, .2
	check(f.SetPageMargins(sheet, &excelize.PageLayoutMarginsOptions{Left: &margin, Right: &margin, Top: &verticalMargin, Bottom: &verticalMargin, Header: &footer, Footer: &footer}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: fmt.Sprintf("'%s'!$A$1:$I$%d", sheet, row), Scope: sheet}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: "'出库单'!$4:$4", Scope: sheet}))
	check(f.SetHeaderFooter(sheet, &excelize.HeaderFooterOptions{OddFooter: "&L" + d.Number + "&R第 &P 页 / 共 &N 页"}))
	if first != nil {
		return nil, "", first
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, "", e
	}
	return b.Bytes(), d.Number + ".xlsx", nil
}

type exportTextPart struct {
	Text  string
	Lines int
}

// Excel width units are narrow characters. CJK occupies two units, combining
// marks none. Physical continuation rows preserve the complete original text.
func exportTextParts(value string, capacity, maxLines int) []exportTextPart {
	capacity = max(2, capacity)
	maxLines = max(2, maxLines)
	runes := []rune(value)
	start, used, lines := 0, 0, 1
	parts := []exportTextPart{}
	units := func(r rune) int {
		if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) {
			return 0
		}
		if r == '\t' {
			return 4
		}
		switch width.LookupRune(r).Kind() {
		case width.EastAsianWide, width.EastAsianFullwidth:
			return 2
		}
		if r == 'W' || r == 'M' {
			return 2
		}
		return 1
	}
	wide := func(r rune) bool {
		k := width.LookupRune(r).Kind()
		return k == width.EastAsianWide || k == width.EastAsianFullwidth
	}
	nextLine := func(at int) {
		if lines == maxLines {
			parts = append(parts, exportTextPart{string(runes[start:at]), lines})
			start, lines = at, 1
		} else {
			lines++
		}
		used = 0
	}
	for i := 0; i < len(runes); {
		r := runes[i]
		if r == '\r' || r == '\n' {
			end := i + 1
			if r == '\r' && end < len(runes) && runes[end] == '\n' {
				end++
			}
			nextLine(end)
			i = end
			continue
		}
		end, n := i+1, units(r)
		// Excel wraps Latin words at whitespace rather than at arbitrary character
		// counts. Treat a whole narrow word as a unit, and long words conservatively.
		if !unicode.IsSpace(r) && !wide(r) {
			for end < len(runes) && !unicode.IsSpace(runes[end]) && !wide(runes[end]) {
				n += units(runes[end])
				end++
			}
		}
		if n <= capacity {
			if used+n > capacity {
				nextLine(i)
			}
			used += n
		} else {
			if used > 0 {
				nextLine(i)
			}
			for at := i; at < end; at++ {
				count := units(runes[at])
				if used+count > capacity {
					nextLine(at)
				}
				used += count
			}
		}
		i = end
	}
	if start < len(runes) || len(parts) == 0 {
		parts = append(parts, exportTextPart{string(runes[start:]), lines})
	}
	return parts
}

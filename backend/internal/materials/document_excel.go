package materials

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"image"
	"math"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
)

// These are the user-supplied reviewed, empty receipt/issue forms.
//
//go:embed templates/inbound.xlsx
var inboundTemplate []byte

//go:embed templates/outbound.xlsx
var outboundTemplate []byte

type DocumentExportInput struct {
	Kind string   `json:"kind"`
	IDs  []string `json:"ids"`
}

// Export and ExportDocuments only read immutable document/price/signature
// snapshots. A download never confirms another inventory operation.
func (s *Service) Export(ctx context.Context, key string) ([]byte, string, error) {
	if _, e := actor(ctx, "personal"); e != nil {
		return nil, "", e
	}
	d, e := getDocument(s.db, key)
	if e != nil {
		return nil, "", e
	}
	data, _, e := s.ExportDocuments(ctx, DocumentExportInput{Kind: d.Kind, IDs: []string{key}})
	return data, d.Number + ".xlsx", e
}

func (s *Service) ExportDocuments(ctx context.Context, in DocumentExportInput) ([]byte, string, error) {
	if in.Kind != "inbound" && in.Kind != "outbound" {
		return nil, "", invalid("仅支持收料单和领料单导出")
	}
	if _, e := actor(ctx, in.Kind); e != nil {
		return nil, "", e
	}
	if len(in.IDs) < 1 || len(in.IDs) > 50 {
		return nil, "", invalid("请选择1至50张同类单据")
	}
	seen := map[string]bool{}
	docs := make([]Document, 0, len(in.IDs))
	total := 0
	for _, key := range in.IDs {
		if e := ctx.Err(); e != nil {
			return nil, "", e
		}
		if key == "" || seen[key] {
			return nil, "", invalid("单据编号无效或重复")
		}
		seen[key] = true
		d, e := getDocument(s.db, key)
		if e != nil {
			return nil, "", e
		}
		if d.Kind != in.Kind {
			return nil, "", ErrMissing
		}
		total += len(d.Lines)
		if total > 5000 {
			return nil, "", invalid("一次最多5000条明细，请分批导出")
		}
		docs = append(docs, d)
	}
	template, sheet := outboundTemplate, "出库单"
	if in.Kind == "inbound" {
		template, sheet = inboundTemplate, "入库单"
	}
	f, e := excelize.OpenReader(bytes.NewReader(template))
	if e != nil {
		return nil, "", e
	}
	defer f.Close()
	source := f.GetSheetList()[0]
	if _, e = f.NewSheet(sheet); e != nil {
		return nil, "", e
	}
	for col := 1; col <= 27; col++ {
		letter, _ := excelize.ColumnNumberToName(col)
		w, e := f.GetColWidth(source, letter)
		if e != nil {
			return nil, "", e
		}
		if e = f.SetColWidth(sheet, letter, letter, w); e != nil {
			return nil, "", e
		}
	}
	start := 1
	for _, d := range docs {
		if e = ctx.Err(); e != nil {
			return nil, "", e
		}
		if start > 1 {
			if e = f.InsertPageBreak(sheet, fmt.Sprintf("A%d", start)); e != nil {
				return nil, "", e
			}
		}
		end, err := s.writeDocumentBlock(ctx, f, source, sheet, start, d)
		if err != nil {
			return nil, "", err
		}
		// The template's first empty row provides spacing. Extra spacer rows
		// before a manual break can overflow a full page into a blank page.
		start = end + 1
	}
	orientation, size, fitWidth, fitHeight := "landscape", 9, 1, 0
	fit := true
	if e = f.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight}); e != nil {
		return nil, "", e
	}
	if e = f.SetSheetProps(sheet, &excelize.SheetPropsOptions{FitToPage: &fit}); e != nil {
		return nil, "", e
	}
	margin := .25
	if e = f.SetPageMargins(sheet, &excelize.PageLayoutMarginsOptions{Left: &margin, Right: &margin, Top: &margin, Bottom: &margin}); e != nil {
		return nil, "", e
	}
	if e = f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: fmt.Sprintf("'%s'!$A$1:$AA$%d", sheet, start-1), Scope: sheet}); e != nil {
		return nil, "", e
	}
	if e = f.DeleteSheet(source); e != nil {
		return nil, "", e
	}
	f.SetActiveSheet(0)
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, "", e
	}
	if b.Len() > 32<<20 {
		return nil, "", invalid("导出文件过大，请分批选择")
	}
	return b.Bytes(), in.Kind + "-" + time.Now().UTC().Format("20060102-150405") + ".xlsx", nil
}

type documentPrintRow struct {
	values []string
	height float64
}

func (s *Service) writeDocumentBlock(ctx context.Context, f *excelize.File, source, sheet string, start int, d Document) (int, error) {
	inbound := d.Kind == "inbound"
	minLines, lastTemplate := 2, 15
	columns := []int{2, 10, 15, 17, 20, 23}
	widths := []int{36, 22, 8, 12, 12, 12}
	baseHeight := 57.0
	if inbound {
		minLines, lastTemplate = 4, 18
		columns = []int{2, 5, 11, 16, 18, 20, 23}
		widths = []int{12, 27, 22, 8, 8, 12, 12}
		baseHeight = 39
	}
	printed := []documentPrintRow{}
	for _, l := range d.Lines {
		values := []string{l.Name, l.Specification, l.Unit, l.Quantity, l.Price, l.Amount}
		if inbound {
			values = append([]string{l.Category}, values...)
		}
		parts := make([][]exportTextPart, len(values))
		count := 1
		for i, value := range values {
			parts[i] = exportTextParts(value, widths[i], 9)
			count = max(count, len(parts[i]))
		}
		for n := 0; n < count; n++ {
			r := documentPrintRow{values: make([]string, len(values)), height: baseHeight}
			for c, ps := range parts {
				if n < len(ps) {
					r.values[c] = ps[n].Text
					r.height = math.Max(r.height, float64(ps[n].Lines)*15+8)
				}
			}
			printed = append(printed, r)
		}
	}
	for len(printed) < minLines {
		printed = append(printed, documentPrintRow{values: make([]string, len(columns)), height: baseHeight})
	}
	// Bound physical continuation rows as well as business lines.
	if len(printed) > 2000 {
		return 0, invalid("单据文字过长，请缩短后导出")
	}
	extra := len(printed) - minLines
	notes := "用途：" + d.Purpose
	if d.Notes != "" {
		notes += "\n备注：" + d.Notes
	}
	noteParts := exportTextParts(notes, 94, 9)
	noteExtra := 0
	if !inbound {
		noteExtra = len(noteParts) - 1
	}
	rowAt := func(row int) int {
		offset := 0
		if !inbound && row > 11 {
			offset = noteExtra
		}
		if row >= 9+minLines {
			return start + row - 1 + extra + offset
		}
		return start + row - 1
	}
	var first error
	check := func(e error) {
		if first == nil {
			first = e
		}
	}
	cell := func(col, row int) string { v, _ := excelize.CoordinatesToCellName(col, row); return v }
	put := func(col, row int, value string) { check(f.SetCellStr(sheet, cell(col, row), value)) }
	copyRow := func(from, to int) {
		height, e := f.GetRowHeight(source, from)
		check(e)
		check(f.SetRowHeight(sheet, to, height))
		for c := 1; c <= 27; c++ {
			a, b := cell(c, from), cell(c, to)
			style, e := f.GetCellStyle(source, a)
			check(e)
			check(f.SetCellStyle(sheet, b, b, style))
			formula, e := f.GetCellFormula(source, a)
			check(e)
			if formula == "" {
				value, e := f.GetCellValue(source, a)
				check(e)
				if value != "" {
					check(f.SetCellStr(sheet, b, value))
				}
			}
		}
	}
	for row := 1; row <= lastTemplate; row++ {
		if row >= 9 && row < 9+minLines {
			continue
		}
		copyRow(row, rowAt(row))
	}
	for i := range printed {
		copyRow(9, start+8+i)
		check(f.SetRowHeight(sheet, start+8+i, printed[i].height))
	}
	if !inbound {
		for i := 1; i < len(noteParts); i++ {
			copyRow(11, rowAt(11)+i)
			put(2, rowAt(11)+i, "")
		}
	}
	merges, e := f.GetMergeCells(source)
	if e != nil {
		return 0, e
	}
	for _, m := range merges {
		c1, r1, _ := excelize.CellNameToCoordinates(m.GetStartAxis())
		c2, r2, _ := excelize.CellNameToCoordinates(m.GetEndAxis())
		if r1 >= 9 && r1 < 9+minLines && r1 == r2 {
			if r1 == 9 {
				for i := range printed {
					check(f.MergeCell(sheet, cell(c1, start+8+i), cell(c2, start+8+i)))
				}
			}
		} else if !inbound && r1 == 11 && r2 == 11 {
			for i := range noteParts {
				check(f.MergeCell(sheet, cell(c1, rowAt(11)+i), cell(c2, rowAt(11)+i)))
			}
		} else {
			endRow := rowAt(r2)
			if !inbound && r2 == 11 {
				endRow += noteExtra
			}
			check(f.MergeCell(sheet, cell(c1, rowAt(r1)), cell(c2, endRow)))
		}
	}
	for i, r := range printed {
		for c, value := range r.values {
			put(columns[c], start+8+i, value)
		}
	}
	date := d.Created
	if at, e := time.Parse(time.RFC3339Nano, d.Created); e == nil {
		date = at.In(time.FixedZone("UTC+8", 8*60*60)).Format("2006-01-02")
	}
	// No field is inferred from notes or from unrelated application roles.
	if inbound {
		put(18, rowAt(6), date)
		if d.MissingPrices == 0 {
			put(23, rowAt(14), d.KnownAmount)
		} else {
			put(13, rowAt(14), fmt.Sprintf("已知小计（缺价%d行）", d.MissingPrices))
			put(23, rowAt(14), d.KnownAmount)
		}
	} else {
		put(21, rowAt(4), date)
		put(5, rowAt(5), d.Recipient)
		put(21, rowAt(5), d.Number)
		for i, part := range noteParts {
			put(4, rowAt(11)+i, part.Text)
			check(f.SetRowHeight(sheet, rowAt(11)+i, math.Max(42, float64(part.Lines)*15+8)))
		}
	}
	end := rowAt(lastTemplate)
	appendText := func(value string) {
		for _, part := range exportTextParts(value, 112, 9) {
			end++
			check(f.MergeCell(sheet, cell(2, end), cell(25, end)))
			put(2, end, part.Text)
			style, e := f.GetCellStyle(source, "D11")
			if inbound {
				style, e = f.GetCellStyle(source, "B13")
			}
			check(e)
			check(f.SetCellStyle(sheet, cell(2, end), cell(25, end), style))
			check(f.SetRowHeight(sheet, end, math.Max(26, float64(part.Lines)*15+8)))
		}
	}
	if inbound {
		appendText("入库单号：" + d.Number + "　经办人：" + d.Owner)
		if d.Notes != "" {
			appendText("备注：" + d.Notes)
		}
	} else {
		appendText("出库经办人：" + d.Owner + "　领用方：" + d.Recipient)
	}
	// The existing signature proves the outbound operator only. Preserve it in
	// its own labelled area; never impersonate the four unsigned template roles.
	if d.SignatureID != "" {
		if e := ctx.Err(); e != nil {
			return 0, e
		}
		asset, data, e := s.loadAsset(s.db, d.SignatureID)
		if e != nil {
			return 0, e
		}
		cfg, _, e := image.DecodeConfig(bytes.NewReader(data))
		if e != nil {
			return 0, e
		}
		end++
		check(f.MergeCell(sheet, cell(2, end), cell(7, end)))
		put(2, end, "经办签名")
		check(f.MergeCell(sheet, cell(8, end), cell(14, end)))
		check(f.SetRowHeight(sheet, end, 38))
		scale := math.Min(120/float64(cfg.Width), 40/float64(cfg.Height))
		check(f.AddPictureFromBytes(sheet, cell(8, end), &excelize.Picture{Extension: "." + strings.TrimPrefix(asset.MIME, "image/"), File: data, Format: &excelize.GraphicOptions{ScaleX: scale, ScaleY: scale, OffsetX: 4, OffsetY: 4, Positioning: "oneCell"}}))
	}
	return end, first
}

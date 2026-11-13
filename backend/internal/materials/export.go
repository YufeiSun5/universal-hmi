package materials

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"strconv"
	"strings"

	"github.com/xuri/excelize/v2"
)

// Export uses only the immutable outbound snapshot, never current item prices
// or the operator's current signature. It performs no inventory mutation.
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
	check := func(err error) {
		if first == nil {
			first = err
		}
	}
	put := func(cell, value string) { check(f.SetCellStr(sheet, cell, value)) }
	merge := func(a, b string) { check(f.MergeCell(sheet, a, b)) }
	merge("A1", "I1")
	put("A1", "物料出库单")
	merge("A2", "E2")
	put("A2", "单号："+d.Number)
	merge("F2", "I2")
	put("F2", "日期："+d.Created[:10])
	headers := []string{"序号", "物料名称", "规格", "分类", "单位", "数量", "单价", "金额", "备注"}
	for i, v := range headers {
		cell, _ := excelize.CoordinatesToCellName(i+1, 4)
		put(cell, v)
	}
	for i, l := range d.Lines {
		row := i + 5
		values := []string{strconv.Itoa(i + 1), l.Name, l.Specification, l.Category, l.Unit, l.Quantity, l.Price, l.Amount, ""}
		if l.Price == "" {
			values[8] = "单价未填"
		}
		for col, v := range values {
			cell, _ := excelize.CoordinatesToCellName(col+1, row)
			put(cell, v)
		}
		check(f.SetRowHeight(sheet, row, 36))
	}
	end := len(d.Lines) + 5
	merge(fmt.Sprintf("A%d", end), fmt.Sprintf("I%d", end))
	label := "合计金额：" + d.KnownAmount
	if d.MissingPrices > 0 {
		label = fmt.Sprintf("已知金额小计：%s；缺价%d行，非完整总金额", d.KnownAmount, d.MissingPrices)
	}
	put(fmt.Sprintf("A%d", end), label)
	for offset, value := range []string{"用途：" + d.Purpose, "领料人：" + d.Recipient, "备注：" + d.Notes, "出库经办人：" + d.Owner + "  办理时间：" + d.Created} {
		row := end + offset + 1
		merge(fmt.Sprintf("A%d", row), fmt.Sprintf("I%d", row))
		put(fmt.Sprintf("A%d", row), value)
		check(f.SetRowHeight(sheet, row, 36))
	}
	sigRow := end + 5
	put(fmt.Sprintf("A%d", sigRow), "签名：")
	merge(fmt.Sprintf("B%d", sigRow), fmt.Sprintf("E%d", sigRow+2))
	check(f.SetRowHeight(sheet, sigRow, 30))
	check(f.SetRowHeight(sheet, sigRow+1, 30))
	check(f.SetRowHeight(sheet, sigRow+2, 30))
	asset, data, e := loadAsset(s.db, d.SignatureID)
	if e != nil {
		return nil, "", e
	}
	cfg, _, e := image.DecodeConfig(bytes.NewReader(data))
	if e != nil {
		return nil, "", e
	}
	scale := min(240/float64(cfg.Width), 100/float64(cfg.Height))
	check(f.AddPictureFromBytes(sheet, fmt.Sprintf("B%d", sigRow), &excelize.Picture{Extension: "." + strings.TrimPrefix(asset.MIME, "image/"), File: data, Format: &excelize.GraphicOptions{ScaleX: scale, ScaleY: scale, OffsetX: 5, OffsetY: 5}}))
	base, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 10}, Alignment: &excelize.Alignment{Vertical: "center", WrapText: true}, Border: []excelize.Border{{Type: "left", Color: "CCD4DC", Style: 1}, {Type: "right", Color: "CCD4DC", Style: 1}, {Type: "top", Color: "CCD4DC", Style: 1}, {Type: "bottom", Color: "CCD4DC", Style: 1}}})
	check(e)
	check(f.SetCellStyle(sheet, "A4", fmt.Sprintf("I%d", sigRow+2), base))
	title, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Size: 18, Bold: true}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center"}})
	check(e)
	check(f.SetCellStyle(sheet, "A1", "I1", title))
	check(f.SetRowHeight(sheet, 1, 36))
	header, e := f.NewStyle(&excelize.Style{Font: &excelize.Font{Family: "Microsoft YaHei", Bold: true, Size: 10}, Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"E4EBF2"}}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center", WrapText: true}})
	check(e)
	check(f.SetCellStyle(sheet, "A4", "I4", header))
	check(f.SetRowHeight(sheet, 4, 28))
	for i, width := range []float64{6, 22, 15, 16, 7, 12, 12, 15, 12} {
		col, _ := excelize.ColumnNumberToName(i + 1)
		check(f.SetColWidth(sheet, col, col, width))
	}
	orientation, size, fitWidth, fitHeight := "portrait", 9, 1, 0
	check(f.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &size, FitToWidth: &fitWidth, FitToHeight: &fitHeight}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: fmt.Sprintf("'%s'!$A$1:$I$%d", sheet, sigRow+2), Scope: sheet}))
	check(f.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: "'出库单'!$4:$4", Scope: sheet}))
	check(f.SetHeaderFooter(sheet, &excelize.HeaderFooterOptions{OddFooter: "&C第 &P 页 / 共 &N 页"}))
	if first != nil {
		return nil, "", first
	}
	b, e := f.WriteToBuffer()
	if e != nil {
		return nil, "", e
	}
	return b.Bytes(), d.Number + ".xlsx", nil
}

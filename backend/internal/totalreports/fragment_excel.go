package totalreports

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/xuri/excelize/v2"
)

type FragmentExcel struct {
	Workbook WorkbookUpload `json:"workbook"`
	Range    string         `json:"range"`
}

func (s *Service) ReadFragmentExcel(ctx context.Context, in FragmentExcel) (ReportFragment, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return ReportFragment{}, e
	}
	if len(in.Workbook.Data) > 12*1024*1024 {
		return ReportFragment{}, fmt.Errorf("Excel超过8MiB")
	}
	data, e := base64.StdEncoding.DecodeString(in.Workbook.Data)
	if e != nil {
		return ReportFragment{}, e
	}
	f, e := openOriginal(data)
	if e != nil {
		return ReportFragment{}, e
	}
	defer f.Close()
	if i, e := f.GetSheetIndex(in.Workbook.Sheet); e != nil || i < 0 {
		return ReportFragment{}, fmt.Errorf("工作表不存在")
	}
	whole := in.Range == ""
	merges, e := f.GetMergeCells(in.Workbook.Sheet)
	if e != nil {
		return ReportFragment{}, e
	}
	if whole {
		rows, e := f.GetRows(in.Workbook.Sheet)
		if e != nil {
			return ReportFragment{}, e
		}
		cols := 0
		for _, row := range rows {
			cols = max(cols, len(row))
		}
		rowCount := len(rows)
		for _, m := range merges {
			c, r, err := excelize.CellNameToCoordinates(m.GetEndAxis())
			if err != nil {
				return ReportFragment{}, err
			}
			cols = max(cols, c)
			rowCount = max(rowCount, r)
		}
		if rowCount == 0 || rowCount > 1000 || cols == 0 || cols > 100 || rowCount*cols > 30000 {
			return ReportFragment{}, fmt.Errorf("工作表范围超过1000行、100列或30000格")
		}
		in.Range = "A1:" + address(rowCount-1, cols-1)
	}
	v, e := parseRect(in.Range)
	if e != nil || v.size() > 30000 {
		return ReportFragment{}, fmt.Errorf("选择的Excel区域无效")
	}
	for _, m := range merges {
		mr, e := parseRect(m.GetStartAxis() + ":" + m.GetEndAxis())
		if e != nil {
			return ReportFragment{}, e
		}
		if rectIntersects(v, mr) && (!v.contains(mr.r0, mr.c0) || !v.contains(mr.r1, mr.c1)) {
			return ReportFragment{}, fmt.Errorf("来源区域切断合并格，请完整选择合并区域")
		}
	}
	p := ReportFragment{Schema: 1, Name: in.Workbook.Sheet, Range: v.text(), Whole: whole, Cells: []Cell{}, History: []HistoryBinding{}, Workbook: in.Workbook}
	for r := v.r0; r <= v.r1; r++ {
		for c := v.c0; c <= v.c1; c++ {
			a := address(r, c)
			value, e := f.GetCellValue(in.Workbook.Sheet, a, excelize.Options{RawCellValue: true})
			if e != nil {
				return p, e
			}
			formula, e := f.GetCellFormula(in.Workbook.Sheet, a)
			if e != nil {
				return p, e
			}
			if formula != "" {
				value = "=" + strings.TrimPrefix(formula, "=")
			}
			if !validContent(value) {
				return p, fmt.Errorf("%s内容不受支持", a)
			}
			id, e := f.GetCellStyle(in.Workbook.Sheet, a)
			if e != nil {
				return p, e
			}
			style, e := f.GetStyle(id)
			if e != nil {
				return p, e
			}
			p.Cells = append(p.Cells, Cell{Address: a, Value: value, Format: importFormat(style)})
		}
	}
	return p, nil
}

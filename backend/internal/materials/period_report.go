package materials

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/shopspring/decimal"
	"github.com/xuri/excelize/v2"
)

const maxReportLines = 10000

type ReportRow struct {
	DocumentID string   `json:"document_id"`
	Number     string   `json:"number"`
	Kind       string   `json:"kind"`
	LineID     string   `json:"line_id"`
	Cells      []string `json:"cells"`
}
type PeriodReport struct {
	Kind          string         `json:"kind"`
	Columns       []string       `json:"columns"`
	Items         []ReportRow    `json:"items"`
	Total         int            `json:"total"`
	Documents     int            `json:"documents"`
	KnownAmount   string         `json:"known_amount"`
	MissingPrices int            `json:"missing_prices"`
	Quantities    []UnitQuantity `json:"quantities"`
}

func reportColumns(kind string) []string {
	if kind == "inbound" {
		return []string{"序号", "入库时间", "发票号", "供应商", "名称", "规格型号", "单位", "数量", "单价", "金额", "主管", "采购员", "保管员", "料号", "合同号", "质量证明书份数", "运杂费（整单，勿累加）", "备注"}
	}
	return []string{"序号", "出库时间", "名称", "规格型号", "单位", "数量", "单价", "金额", "性质", "领料单位", "工程项目", "站所", "工程编号", "供应审核", "主管", "保管", "领用人", "料号", "用途", "备注"}
}

func reportFilter(f Filter) (Filter, error) {
	var e error
	f, e = pagination(f)
	if e != nil {
		return f, e
	}
	if f.Kind != "inbound" && f.Kind != "outbound" && f.Kind != "both" {
		return f, invalid("请选择入库、出库或合并报表")
	}
	if f.Status != "" || f.To != "" || f.OwnerID != "" || f.ParentID != nil || f.InboundStatus != "" {
		return f, invalid("汇总筛选条件无效")
	}
	if f.From == "" || f.Until == "" {
		return f, invalid("请选择完整起止日期")
	}
	start, _ := time.Parse(time.RFC3339Nano, f.From)
	end, _ := time.Parse(time.RFC3339Nano, f.Until)
	if end.Sub(start) > 366*24*time.Hour {
		return f, invalid("一次最多查询366天，请缩小日期范围")
	}
	return f, nil
}

// Each row is a confirmed immutable document line. Category and search filters
// apply to lines, so unrelated lines from a matching document never leak in.
// No relationship between left and right rows is inferred from their position.
func (s *Service) periodReport(ctx context.Context, q queryer, kind string, f Filter) (PeriodReport, error) {
	out := PeriodReport{Kind: kind, Columns: reportColumns(kind), Items: []ReportRow{}, KnownAmount: "0.00", Quantities: []UnitQuantity{}}
	df := f
	df.Search = ""
	where, args, e := s.documentFilter(kind, df)
	if e != nil {
		return out, e
	}
	line, params := s.documentLineFilter(df)
	args = append(args, params...)
	where += " AND " + line
	j := s.chainJSON
	if f.Search != "" {
		where += " AND lower(" + j("l.body", "code") + " || ' ' || " + j("l.body", "name") + " || ' ' || " + j("l.body", "specification") + " || ' ' || " + j("d.body", "number") + " || ' ' || " + j("d.body", "recipient") + ") LIKE ? ESCAPE '!'"
		args = append(args, like(f.Search))
	}
	rows, e := q.Query("SELECT d.id,d.created,"+j("d.body", "number")+","+j("d.body", "recipient")+",l.body,d.body FROM materials_documents d JOIN materials_lines l ON l.document_id=d.id WHERE "+where+" ORDER BY d.created,d.id,l.id LIMIT 10001", args...)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	amounts := decimal.Zero
	units := map[string]decimal.Decimal{}
	docs := map[string]bool{}
	for rows.Next() {
		if e = ctx.Err(); e != nil {
			return out, e
		}
		if len(out.Items) >= maxReportLines {
			return out, invalid("匹配明细超过10000行，请缩小日期或分类范围")
		}
		var key, created, number, recipient, body, documentBody string
		var d Document
		var l Line
		if e = rows.Scan(&key, &created, &number, &recipient, &body, &documentBody); e != nil {
			return out, e
		}
		if e = decodeBody(body, &l); e != nil {
			return out, e
		}
		if e = decodeBody(documentBody, &d); e != nil {
			return out, e
		}
		at, err := time.Parse(time.RFC3339Nano, created)
		if err != nil {
			return out, err
		}
		date := at.In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02")
		cells := make([]string, len(out.Columns))
		cells[0] = fmt.Sprint(len(out.Items) + 1)
		cells[1] = date
		if kind == "inbound" {
			cells[2] = d.Details.InvoiceNumber
			cells[3] = d.Details.Supplier
			cells[10] = d.Details.Supervisor.Name
			cells[11] = d.Details.Purchaser.Name
			cells[12] = d.Details.Storekeeper.Name
			cells[13] = l.Code
			cells[14] = d.Details.ContractNumber
			if d.Details.CertificateCount != nil {
				cells[15] = fmt.Sprint(*d.Details.CertificateCount)
			}
			cells[16] = d.Details.Freight
			cells[17] = d.Notes
			cells[4] = l.Name
			cells[5] = l.Specification
			cells[6] = l.Unit
			cells[7] = l.Quantity
			cells[8] = l.Price
			cells[9] = l.Amount
		} else {
			cells[2] = l.Name
			cells[3] = l.Specification
			cells[4] = l.Unit
			cells[5] = l.Quantity
			cells[6] = l.Price
			cells[7] = l.Amount
			cells[8] = d.Details.Nature
			cells[9] = recipient
			cells[10] = d.Details.Project
			cells[11] = d.Details.Station
			cells[12] = d.Details.ProjectNumber
			cells[13] = d.Details.SupplyReviewer.Name
			cells[14] = d.Details.Supervisor.Name
			cells[15] = d.Details.Storekeeper.Name
			cells[16] = d.Details.RecipientPerson.Name
			cells[17] = l.Code
			cells[18] = d.Purpose
			cells[19] = d.Notes
		}
		out.Items = append(out.Items, ReportRow{DocumentID: key, Number: number, Kind: kind, LineID: l.ID, Cells: cells})
		docs[key] = true
		n, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			return out, err
		}
		units[l.Unit] = units[l.Unit].Add(n)
		if l.Amount == "" {
			out.MissingPrices++
		} else {
			amount, err := decimal.NewFromString(l.Amount)
			if err != nil {
				return out, err
			}
			amounts = amounts.Add(amount)
		}
	}
	if e = rows.Err(); e != nil {
		return out, e
	}
	out.Total = len(out.Items)
	out.Documents = len(docs)
	out.KnownAmount = amounts.StringFixed(2)
	for unit, n := range units {
		out.Quantities = append(out.Quantities, UnitQuantity{Unit: unit, Quantity: n.String()})
	}
	sort.Slice(out.Quantities, func(i, j int) bool { return out.Quantities[i].Unit < out.Quantities[j].Unit })
	return out, nil
}

func (s *Service) PeriodReport(ctx context.Context, f Filter) (PeriodReport, error) {
	f, e := reportFilter(f)
	if e != nil {
		return PeriodReport{}, e
	}
	if f.Kind == "both" {
		return PeriodReport{}, invalid("查看时请选择入库或出库")
	}
	if _, e = actor(ctx, f.Kind); e != nil {
		return PeriodReport{}, e
	}
	tx, a, e := s.chainRead(ctx)
	if e != nil {
		return PeriodReport{}, e
	}
	defer tx.Rollback()
	out, e := s.periodReport(ctx, tx, f.Kind, f)
	if e != nil {
		return PeriodReport{}, e
	}
	if !a.Active() {
		return PeriodReport{}, authorization.ErrDenied
	}
	start := min(f.Offset, out.Total)
	end := min(start+f.Limit, out.Total)
	out.Items = out.Items[start:end]
	return out, nil
}

func (s *Service) ExportPeriodReport(ctx context.Context, f Filter) ([]byte, string, error) {
	f, e := reportFilter(f)
	if e != nil {
		return nil, "", e
	}
	kinds := []string{f.Kind}
	if f.Kind == "both" {
		kinds = []string{"inbound", "outbound"}
	}
	for _, kind := range kinds {
		if _, e = actor(ctx, kind); e != nil {
			return nil, "", e
		}
	}
	tx, a, e := s.chainRead(ctx)
	if e != nil {
		return nil, "", e
	}
	defer tx.Rollback()
	reports := []PeriodReport{}
	for _, kind := range kinds {
		r, err := s.periodReport(ctx, tx, kind, f)
		if err != nil {
			return nil, "", err
		}
		reports = append(reports, r)
	}
	// Freeze both sides in one read snapshot; rendering never holds the DB open.
	if e = tx.Commit(); e != nil {
		return nil, "", e
	}
	data, e := renderPeriodReport(ctx, reports, f)
	if !a.Active() {
		return nil, "", authorization.ErrDenied
	}
	return data, "材料出入库明细表.xlsx", e
}

func renderPeriodReport(ctx context.Context, reports []PeriodReport, filter Filter) ([]byte, error) {
	template, e := readPeriodReportTemplate()
	if e != nil {
		return nil, e
	}
	book := excelize.NewFile()
	defer book.Close()
	sheet := "材料出入库明细表"
	if e := book.SetSheetName("Sheet1", sheet); e != nil {
		return nil, e
	}
	var first error
	check := func(e error) {
		if first == nil {
			first = e
		}
	}
	styles := map[int]int{}
	for key, style := range template.Styles {
		// Wrap complete snapshot values in the original column widths. Values
		// remain explicit strings, including leading-zero identifiers.
		if style.Alignment != nil {
			style.Alignment.WrapText = true
		}
		id, err := book.NewStyle(&style)
		check(err)
		styles[key] = id
	}
	title := styles[template.TitleStyle]
	// The source's merged heading stores its right border on the last cell,
	// not on the top-left style. Restore that outside edge after extending it.
	groupStyle := template.Styles[template.GroupStyle]
	groupStyle.Border = append(groupStyle.Border, excelize.Border{Type: "right", Color: "000000", Style: 1})
	head, err := book.NewStyle(&groupStyle)
	check(err)
	noteStyle := template.Styles[template.NoteStyle]
	noteFont := *noteStyle.Font
	noteFont.Bold = false
	noteStyle.Font = &noteFont
	note, err := book.NewStyle(&noteStyle)
	check(err)
	cell := func(c, r int) string { v, _ := excelize.CoordinatesToCellName(c, r); return v }
	put := func(c, r int, v string) { check(book.SetCellStr(sheet, cell(c, r), v)) }
	start, _ := time.Parse(time.RFC3339Nano, filter.From)
	end, _ := time.Parse(time.RFC3339Nano, filter.Until)
	zone := time.FixedZone("UTC+8", 8*3600)
	period := start.In(zone).Format("2006-01-02") + " 至 " + end.Add(-time.Nanosecond).In(zone).Format("2006-01-02") + "（北京时间）"
	offset, maxRow := 1, 6
	headerHeight := template.RowHeights[3]
	for _, r := range reports {
		if e = ctx.Err(); e != nil {
			return nil, e
		}
		count := len(r.Columns)
		last := offset + count - 1
		endRow := 5 + len(r.Items)
		maxRow = max(maxRow, endRow+2)
		check(book.MergeCell(sheet, cell(offset, 1), cell(last, 1)))
		put(offset, 1, template.Title)
		check(book.SetCellStyle(sheet, cell(offset, 1), cell(last, 1), title))
		check(book.MergeCell(sheet, cell(offset, 2), cell(last, 2)))
		put(offset, 2, period)
		check(book.SetCellStyle(sheet, cell(offset, 2), cell(last, 2), note))
		check(book.MergeCell(sheet, cell(offset, 3), cell(last, 3)))
		label := "入库"
		if r.Kind == "outbound" {
			label = "出库"
		}
		put(offset, 3, label)
		check(book.SetCellStyle(sheet, cell(offset, 3), cell(last, 3), head))
		widths := make([]float64, count)
		for i, h := range r.Columns {
			put(offset+i, 4, h)
			format, err := template.column(r.Kind, h)
			if err != nil {
				return nil, err
			}
			widths[i] = format.Width
			col, _ := excelize.ColumnNumberToName(offset + i)
			check(book.SetColWidth(sheet, col, col, format.Width))
			check(book.SetCellStyle(sheet, cell(offset+i, 4), cell(offset+i, 4), styles[format.HeaderStyle]))
			check(book.SetCellStyle(sheet, cell(offset+i, 5), cell(offset+i, endRow), styles[format.BodyStyle]))
			for _, part := range exportTextParts(h, int(format.Width), 12) {
				headerHeight = max(headerHeight, float64(part.Lines)*16+8)
			}
		}
		for row, item := range r.Items {
			if e = ctx.Err(); e != nil {
				return nil, e
			}
			height := template.RowHeights[4]
			for i, v := range item.Cells {
				put(offset+i, row+5, v)
				lines := 0
				for _, part := range exportTextParts(v, int(widths[i]), 12) {
					lines += part.Lines
				}
				height = max(height, float64(lines)*16+8)
			}
			// Preserve content in normal Excel view without manufacturing continuation records.
			old, _ := book.GetRowHeight(sheet, row+5)
			check(book.SetRowHeight(sheet, row+5, min(409, max(old, height))))
		}
		amountCol := offset + 9
		if r.Kind == "outbound" {
			amountCol = offset + 7
		}
		label = "合计"
		if r.MissingPrices > 0 {
			label = fmt.Sprintf("已知小计（缺价%d行）", r.MissingPrices)
		}
		check(book.MergeCell(sheet, cell(offset, endRow), cell(amountCol-1, endRow)))
		put(offset, endRow, label)
		put(amountCol, endRow, r.KnownAmount)
		check(book.SetCellStyle(sheet, cell(offset, endRow), cell(last, endRow), head))
		check(book.MergeCell(sheet, cell(offset, endRow+1), cell(last, endRow+1)))
		put(offset, endRow+1, fmt.Sprintf("%d张单据，%d条明细；缺失字段留空。", r.Documents, r.Total))
		check(book.SetCellStyle(sheet, cell(offset, endRow+1), cell(last, endRow+1), note))
		check(book.SetRowHeight(sheet, endRow, max(template.RowHeights[4], headerHeight)))
		check(book.SetRowHeight(sheet, endRow+1, template.RowHeights[4]))
		offset = last + 1
	}
	check(book.SetRowHeight(sheet, 1, template.RowHeights[0]))
	check(book.SetRowHeight(sheet, 2, template.RowHeights[1]))
	check(book.SetRowHeight(sheet, 3, template.RowHeights[2]))
	check(book.SetRowHeight(sheet, 4, headerHeight))
	check(book.MergeCell(sheet, cell(1, maxRow), cell(offset-1, maxRow)))
	put(1, maxRow, "入库与出库独立排列，不表示同一行的出入库存在对应关系。金额沿用原单快照，退库不冲减原出库明细。运杂费为整单金额，逐行展示勿重复累加；人员姓名不表示已签署。")
	check(book.SetCellStyle(sheet, cell(1, maxRow), cell(offset-1, maxRow), note))
	check(book.SetRowHeight(sheet, maxRow, template.RowHeights[4]))
	check(book.SetPanes(sheet, &excelize.Panes{Freeze: true, YSplit: 4, TopLeftCell: "A5", ActivePane: "bottomLeft"}))
	orientation := "landscape"
	paper := 8
	fit := 1
	zero := 0
	fitPage := true
	check(book.SetSheetProps(sheet, &excelize.SheetPropsOptions{FitToPage: &fitPage}))
	check(book.SetPageLayout(sheet, &excelize.PageLayoutOptions{Orientation: &orientation, Size: &paper, FitToWidth: &fit, FitToHeight: &zero}))
	check(book.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Area", RefersTo: "'" + sheet + "'!$A$1:$" + strings.TrimRight(cell(offset-1, maxRow), "0123456789") + "$" + fmt.Sprint(maxRow), Scope: sheet}))
	check(book.SetDefinedName(&excelize.DefinedName{Name: "_xlnm.Print_Titles", RefersTo: "'" + sheet + "'!$1:$4", Scope: sheet}))
	if first != nil {
		return nil, first
	}
	b, e := book.WriteToBuffer()
	if e != nil {
		return nil, e
	}
	if b.Len() > 20<<20 {
		return nil, invalid("导出超过20MiB，请缩小范围")
	}
	return b.Bytes(), nil
}

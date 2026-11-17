package materials

import (
	"bytes"
	"context"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
	"testing"
	"time"
)

func TestPeriodReportSnapshotsFiltersPermissionsAndExcel(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			child := must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "汇总子类", ParentID: f.normal.ID}}))(t)
			wire := must(s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "=1+2电线", Unit: "米", Warning: "0", CategoryID: child.ID}}))(t)
			in := must(s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{
				{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "20", Price: "0.005"},
				{ItemID: wire.ID, CategoryID: child.ID, Quantity: "1.25"},
				{ItemID: f.item.ID, CategoryID: f.scrap.ID, Quantity: "3", Price: "10"},
			}}))(t)
			out := must(s.Confirm(f.ctx, "outbound", f.outboundInput(t, "2")))(t)
			must(s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.normal.ID}}}))(t)
			next := must(s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "1", Price: "200"}}}))(t)
			for key, at := range map[string]string{in.ID: "2026-11-12T16:00:00.000000000Z", out.ID: "2026-11-13T15:59:59.000000000Z", next.ID: "2026-11-13T16:00:00.000000000Z"} {
				d := must(getDocument(s.db, key))(t)
				d.Created = at
				if _, e := s.db.Exec("UPDATE materials_documents SET created=?,body=? WHERE id=?", at, raw(d), key); e != nil {
					t.Fatal(e)
				}
			}
			filter := Filter{Kind: "inbound", From: "2026-11-13T00:00:00+08:00", Until: "2026-11-14T00:00:00+08:00", CategoryID: f.normal.ID, Limit: 1}
			p := must(s.PeriodReport(f.ctx, filter))(t)
			if p.Total != 2 || len(p.Items) != 1 || p.Documents != 1 || p.KnownAmount != "0.10" || p.MissingPrices != 1 || len(p.Quantities) != 2 {
				t.Fatalf("report %+v", p)
			}
			filter.Offset = 1
			n := must(s.PeriodReport(f.ctx, filter))(t)
			if n.KnownAmount != p.KnownAmount || n.Items[0].LineID == p.Items[0].LineID || n.Items[0].Cells[0] != "2" {
				t.Fatal("pagination lost summary or stable sequence", n)
			}
			filter.Search = "电线"
			filter.Offset = 0
			only := must(s.PeriodReport(f.ctx, filter))(t)
			if only.Total != 1 || only.Items[0].Cells[4] != "=1+2电线" || only.Items[0].Cells[9] != "" {
				t.Fatal("line search or missing amount", only)
			}
			filter.Search = ""
			filter.Kind = "outbound"
			op := must(s.PeriodReport(f.ctx, filter))(t)
			if op.Total != 1 || op.Items[0].Cells[5] != "2" || op.KnownAmount != "25.00" {
				t.Fatal("return changed original outbound", op)
			}
			inboundOnly := testContext("in", authorization.Grants{MaterialsInbound: true})
			if _, e := s.PeriodReport(inboundOnly, filter); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal("outbound disclosure", e)
			}
			filter.Kind = "both"
			if _, _, e := s.ExportPeriodReport(inboundOnly, filter); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal("combined disclosure", e)
			}
			before := raw(must(s.Stock(f.ctx, Filter{}))(t))
			data, _, e := s.ExportPeriodReport(f.ctx, filter)
			if e != nil {
				t.Fatal(e)
			}
			book := must(excelize.OpenReader(bytes.NewReader(data)))(t)
			defer book.Close()
			sheet := book.GetSheetList()[0]
			props := must(book.GetSheetProps(sheet))(t)
			layout := must(book.GetPageLayout(sheet))(t)
			if props.FitToPage == nil || !*props.FitToPage || layout.FitToWidth == nil || *layout.FitToWidth != 1 {
				t.Fatal("wide report must print on one page across")
			}
			if len(book.GetSheetList()) != 1 {
				t.Fatal("expected one template sheet")
			}
			value := func(cell string) string { return must(book.GetCellValue(sheet, cell))(t) }
			if value("A3") != "入库" || value("S3") != "出库" || value("M4") != "保管员" || value("AI4") != "领用人" || value("J7") != "0.10" || value("Z6") != "25.00" {
				t.Fatal("template layout or all-page totals")
			}
			if value("A1") != "大连庄河环海热电有限公司材料明细" || value("S1") != value("A1") {
				t.Fatal("user template title was replaced")
			}
			for col, width := range map[string]float64{"B": 16, "D": 36, "E": 22.625, "F": 19.375, "U": 29.375, "V": 20.625} {
				if got := must(book.GetColWidth(sheet, col))(t); got != width {
					t.Fatalf("template width %s = %v, want %v", col, got, width)
				}
			}
			for _, cell := range []string{"A1", "A3", "A4", "D5", "J7", "S3", "U4", "Z6", "N4", "AK4"} {
				style := must(book.GetStyle(must(book.GetCellStyle(sheet, cell))(t)))(t)
				if style.Font == nil || style.Font.Family != "仿宋" || style.Font.Size != 12 || (style.Font.Color != "" && style.Font.Color != "000000") {
					t.Fatalf("template typography %s: %+v", cell, style.Font)
				}
				for _, color := range style.Fill.Color {
					if style.Fill.Pattern != 0 && color != "FFFFFF" {
						t.Fatalf("non-template colored fill %s: %+v", cell, style.Fill)
					}
				}
				for _, border := range style.Border {
					if border.Style != 1 || border.Color != "000000" {
						t.Fatalf("template border %s: %+v", cell, border)
					}
				}
			}
			for _, cell := range []string{"R3", "AL3", "AL6"} {
				style := must(book.GetStyle(must(book.GetCellStyle(sheet, cell))(t)))(t)
				right := false
				for _, border := range style.Border {
					right = right || border.Type == "right" && border.Style == 1
				}
				if !right {
					t.Fatalf("template outside border missing at %s", cell)
				}
			}
			if value("C5") != "" || value("D5") != "" || value("K5") != "" || value("AF5") != "" {
				t.Fatal("missing metadata invented")
			}
			for _, c := range []string{"E5", "E6"} {
				if must(book.GetCellFormula(sheet, c))(t) != "" {
					t.Fatal("input executed as formula")
				}
			}
			if raw(must(s.Stock(f.ctx, Filter{}))(t)) != before {
				t.Fatal("report mutated stock")
			}
			revoked := authorization.WithActor(context.Background(), authorization.Actor{ID: "off", Grants: allGrants(), Valid: func() bool { return false }})
			if _, _, e = s.ExportPeriodReport(revoked, filter); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal(e)
			}
			filter.Kind = "inbound"
			filter.From = "2026-11-15T00:00:00Z"
			if _, e = s.PeriodReport(f.ctx, filter); e == nil {
				t.Fatal("inverse range")
			}
		})
	}
}

func TestPeriodReportRequiresBoundedExplicitDates(t *testing.T) {
	for _, f := range []Filter{{Kind: "inbound"}, {Kind: "stock", From: "2026-01-01T00:00:00Z", Until: "2026-02-01T00:00:00Z"}, {Kind: "inbound", From: "2020-01-01T00:00:00Z", Until: "2026-01-01T00:00:00Z"}} {
		if _, e := reportFilter(f); e == nil {
			t.Fatal("invalid query accepted", f)
		}
	}
}

func TestPeriodReportRefusesTruncation(t *testing.T) {
	f := setup(t, false)
	d := f.inbound(t, "20", Application{})
	line := d.Lines[0]
	tx := must(f.s.db.Begin())(t)
	for i := 0; i < maxReportLines; i++ {
		line.ID = id()
		if _, e := tx.Exec("INSERT INTO materials_lines(document_id,id,item_id,category_id,quantity,returned,body) VALUES(?,?,?,?,1,0,?)", d.ID, line.ID, line.ItemID, line.CategoryID, raw(line)); e != nil {
			t.Fatal(e)
		}
	}
	if e := tx.Commit(); e != nil {
		t.Fatal(e)
	}
	filter := Filter{Kind: "inbound", From: d.Created, Until: time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano)}
	if _, e := f.s.PeriodReport(f.ctx, filter); e == nil {
		t.Fatal("silently truncated report")
	}
	if _, _, e := f.s.ExportPeriodReport(f.ctx, filter); e == nil {
		t.Fatal("silently truncated Excel")
	}
}

package materials

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func TestDocumentBatchTemplatesGrowVerticallyAndKeepSnapshots(t *testing.T) {
	f := setup(t, false)
	items := []Item{f.item}
	for i := 1; i < 8; i++ {
		items = append(items, must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: fmt.Sprintf("批量物料%d", i+1), Specification: "DN100", Unit: "件", CategoryID: f.normal.ID, Price: "12.5", Warning: "0"}}))(t))
	}
	makeInput := func(kind string, n int) DocumentInput {
		in := DocumentInput{Mutation: operation(), SignatureVersion: f.sig.Version, Purpose: "隔离测试维修", Recipient: "测试领用单位", Notes: "真实备注，不推断供应商或合同"}
		for _, item := range items[:n] {
			l := LineInput{ItemID: item.ID, CategoryID: f.normal.ID, Quantity: "2"}
			if kind == "inbound" {
				l.Price = "10"
			} else {
				p := must(f.s.Stock(f.ctx, Filter{ItemID: item.ID, CategoryID: f.normal.ID}))(t)
				l.ItemVersion = p.Items[0].Version
				l.BalanceVersion = p.Items[0].BalanceVersion
			}
			in.Lines = append(in.Lines, l)
		}
		return in
	}
	inLong := must(f.s.Confirm(f.ctx, "inbound", makeInput("inbound", 8)))(t)
	inShort := must(f.s.Confirm(f.ctx, "inbound", makeInput("inbound", 1)))(t)
	outLong := must(f.s.Confirm(f.ctx, "outbound", makeInput("outbound", 8)))(t)
	outShort := must(f.s.Confirm(f.ctx, "outbound", makeInput("outbound", 1)))(t)
	before := raw(must(f.s.Stock(f.ctx, Filter{}))(t))
	for _, tc := range []struct {
		kind, sheet string
		docs        []Document
		col         string
	}{{"inbound", "入库单", []Document{inLong, inShort}, "G"}, {"outbound", "出库单", []Document{outLong, outShort}, "E"}} {
		t.Run(tc.kind, func(t *testing.T) {
			data, _, e := f.s.ExportDocuments(f.ctx, DocumentExportInput{Kind: tc.kind, IDs: []string{tc.docs[0].ID, tc.docs[1].ID}})
			if e != nil {
				t.Fatal(e)
			}
			x := must(excelize.OpenReader(bytes.NewReader(data)))(t)
			defer x.Close()
			if len(x.GetSheetList()) != 1 || x.GetSheetList()[0] != tc.sheet {
				t.Fatal("batch must be one sheet", x.GetSheetList())
			}
			rows := must(x.GetRows(tc.sheet))(t)
			titles := []int{}
			for i, row := range rows {
				if len(row) > 8 && strings.Contains(row[8], "料") {
					if strings.Contains(row[8], "单") {
						titles = append(titles, i+1)
					}
				}
			}
			if len(titles) != 2 || titles[0] != 3 || titles[1] <= titles[0]+18 {
				t.Fatalf("overlapping blocks %v", titles)
			}
			for j, d := range tc.docs {
				start := titles[j] - 2
				for i, line := range d.Lines {
					if got := must(x.GetCellValue(tc.sheet, fmt.Sprintf("%s%d", tc.col, start+8+i)))(t); got != line.Name {
						t.Fatalf("wrong line %d %d %q", j, i, got)
					}
				}
				dateCell := fmt.Sprintf("U%d", start+3)
				if tc.kind == "inbound" {
					dateCell = fmt.Sprintf("R%d", start+5)
				}
				if got := must(x.GetCellValue(tc.sheet, dateCell))(t); len(got) != 10 {
					t.Fatal("date missing", got)
				}
			}
			all := ""
			for _, r := range rows {
				all += strings.Join(r, "|")
			}
			if strings.Index(all, tc.docs[0].Number) >= strings.Index(all, tc.docs[1].Number) {
				t.Fatal("selection order lost")
			}
			pics := must(x.GetPictureCells(tc.sheet))(t)
			want := 0
			if tc.kind == "outbound" {
				want = 2
			}
			if len(pics) != want {
				t.Fatalf("unexpected signatures %v", pics)
			}
			for _, cell := range pics {
				if !strings.HasPrefix(cell, "H") {
					t.Fatal("operator signature assigned to unrelated role", cell)
				}
			}
			// Existing data has no vendor/contract/project fields; never infer them.
			emptyCells := []string{"E5", "U5", "E6"}
			if tc.kind == "outbound" {
				emptyCells = []string{"E6", "T6"}
			}
			for _, cell := range emptyCells {
				if got := must(x.GetCellValue(tc.sheet, cell))(t); got != "" {
					t.Fatal("invented missing value", cell, got)
				}
			}
			if target := os.Getenv("HMI_DOCUMENT_EXPORT_ARTIFACTS"); target != "" {
				if e = os.MkdirAll(target, 0700); e != nil {
					t.Fatal(e)
				}
				if e = os.WriteFile(filepath.Join(target, tc.kind+"-batch.xlsx"), data, 0600); e != nil {
					t.Fatal(e)
				}
			}
		})
	}
	if after := raw(must(f.s.Stock(f.ctx, Filter{}))(t)); after != before {
		t.Fatal("export mutated inventory")
	}
}

func TestDocumentBatchExportRejectsEntireInvalidSelection(t *testing.T) {
	f := setup(t, false)
	in := f.inbound(t, "4", Application{})
	out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
	for _, input := range []DocumentExportInput{{Kind: "inbound"}, {Kind: "return", IDs: []string{out.ID}}, {Kind: "inbound", IDs: []string{in.ID, in.ID}}, {Kind: "inbound", IDs: []string{in.ID, out.ID}}, {Kind: "outbound", IDs: []string{out.ID, "missing"}}, {Kind: "outbound", IDs: make([]string, 51)}} {
		if data, _, e := f.s.ExportDocuments(f.ctx, input); e == nil || len(data) != 0 {
			t.Fatalf("invalid batch succeeded %+v %v", input, e)
		}
	}
	for _, kind := range []string{"inbound", "outbound"} {
		key := in.ID
		g := authorization.Grants{MaterialsOutbound: true}
		if kind == "outbound" {
			key = out.ID
			g = authorization.Grants{MaterialsInbound: true}
		}
		if _, _, e := f.s.ExportDocuments(testContext("limited", g), DocumentExportInput{Kind: kind, IDs: []string{key}}); e == nil {
			t.Fatal("cross-kind grant allowed")
		}
	}
	ctx, cancel := context.WithCancel(f.ctx)
	cancel()
	if _, _, e := f.s.ExportDocuments(ctx, DocumentExportInput{Kind: "inbound", IDs: []string{in.ID}}); e == nil {
		t.Fatal("cancelled export succeeded")
	}
}

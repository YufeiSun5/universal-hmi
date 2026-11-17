package materials

import (
	"bytes"
	"context"
	"fmt"
	"image/color"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func TestItemCodeConcurrentUniquenessAndSearch(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(fmt.Sprint(pg), func(t *testing.T) {
			f := setup(t, pg)
			var wg sync.WaitGroup
			results := make(chan error, 8)
			for i := 0; i < 8; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					code := " 00Ab01 "
					if i%2 == 1 {
						code = "00ab01"
					}
					_, e := f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Code: code, Name: fmt.Sprint("item", i), Unit: "个", Warning: "0", CategoryID: f.normal.ID}})
					results <- e
				}(i)
			}
			wg.Wait()
			close(results)
			success := 0
			for e := range results {
				if e == nil {
					success++
				}
			}
			if success != 1 {
				t.Fatalf("duplicate code accepted %d times", success)
			}
			p := must(f.s.Items(f.ctx, Filter{Search: "00ab01"}))(t)
			if p.Total != 1 || len(p.Items[0].Code) != 6 {
				t.Fatal(p)
			}
			item := p.Items[0]
			item.Name = "renamed"
			must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: item}))(t)
			for i := 0; i < 2; i++ {
				must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "无料号", Unit: "个", Warning: "0", CategoryID: f.normal.ID}}))(t)
			}
		})
	}
}

func TestDocumentFieldsSnapshotsExportsAndInventory(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(fmt.Sprint(pg), func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			directory := map[string]string{"buyer": "采购账号", "keeper": "保管账号"}
			s.SetPersonnelDirectory(func(authorization.Actor) (map[string]string, error) { return directory, nil })
			f.item.Code = "000012A"
			f.item = must(s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
			count := int64(0)
			in := DocumentInput{Mutation: operation(), Notes: "进货备注", Details: DocumentFields{Supplier: "=供应商", InvoiceNumber: "000INV", ContractNumber: "00C", CertificateCount: &count, Freight: "30.50", Purchaser: Personnel{UserID: "buyer", Name: "伪造姓名"}, Supervisor: Personnel{Name: "外部主管"}, Storekeeper: Personnel{UserID: "keeper"}}, Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "10", Price: "2"}}}
			incoming := must(s.Confirm(f.ctx, "inbound", in))(t)
			if incoming.Lines[0].Code != "000012A" || incoming.Details.Purchaser.Name != "采购账号" || incoming.KnownAmount != "20.00" || incoming.SignatureID != "" {
				t.Fatal(incoming)
			}
			outgoingInput := f.outboundInput(t, "3")
			outgoingInput.Recipient = "领用单位"
			outgoingInput.Notes = "出库备注"
			outgoingInput.Details = DocumentFields{Project: "工程甲", ProjectNumber: "000P-A", Station: "站所甲", Nature: "维修", RecipientPerson: Personnel{Name: "外部领用人"}, SupplyReviewer: Personnel{UserID: "buyer"}, Supervisor: Personnel{Name: "出库主管"}, Storekeeper: Personnel{UserID: "keeper"}}
			preview := must(s.PreviewOutbound(f.ctx, outgoingInput))(t)
			if preview.Details.SupplyReviewer.Name != "采购账号" || preview.Lines[0].Code != "000012A" {
				t.Fatal(preview)
			}
			outgoing := must(s.Confirm(f.ctx, "outbound", outgoingInput))(t)
			old := raw(outgoing)
			directory["buyer"] = "改名账号"
			delete(directory, "keeper")
			f.item.Code = "NEW-0001"
			f.item = must(s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
			// An acknowledged operation stays idempotent after directory changes.
			retry := must(s.Confirm(f.ctx, "inbound", in))(t)
			if retry.ID != incoming.ID {
				t.Fatal("retry posted again")
			}
			reopened := must(Open(s.db, s.files))(t)
			got := must(reopened.Document(f.ctx, outgoing.ID, Filter{}))(t).Document
			if raw(got) != old {
				t.Fatal("document snapshot changed after reopen/rename")
			}
			returned := must(s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: outgoing.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: outgoing.Lines[0].ID, Quantity: "1", TargetCategoryID: f.normal.ID}}}))(t)
			if returned.Lines[0].Code != "000012A" || f.stock(t, f.normal.ID).Quantity != "8" {
				t.Fatal("return did not retain original code or quantity")
			}
			if inboundSummary(incoming).Details != (DocumentFields{}) {
				t.Fatal("restricted summary leaked purchase data")
			}
			before := raw(must(s.Stock(f.ctx, Filter{}))(t))
			for _, d := range []Document{incoming, outgoing} {
				data, _, e := s.Export(f.ctx, d.ID)
				if e != nil {
					t.Fatal(e)
				}
				book := must(excelize.OpenReader(bytes.NewReader(data)))(t)
				sheet := book.GetSheetList()[0]
				expected := map[string]string{"B9": "000012A", "E9": f.item.Name, "E6": "工程甲", "T6": "000P-A", "B14": "采购账号", "H14": "出库主管", "N14": "保管账号", "T14": "外部领用人"}
				if d.Kind == "inbound" {
					expected = map[string]string{"E5": "=供应商", "U5": "00C", "E6": "000INV", "E9": "000012A", "G9": f.item.Name, "G14": "0", "W13": "30.5", "W14": "20.00", "B17": "外部主管", "J17": "采购账号", "R17": "保管账号"}
				}
				for cell, value := range expected {
					if got := must(book.GetCellValue(sheet, cell))(t); got != value {
						t.Fatalf("%s %s: %q != %q", d.Kind, cell, got, value)
					}
					if must(book.GetCellFormula(sheet, cell))(t) != "" {
						t.Fatal("text became formula")
					}
				}
				pics := must(book.GetPictureCells(sheet))(t)
				want := 0
				if d.Kind == "outbound" {
					want = 1
				}
				if len(pics) != want {
					t.Fatal("attribution created signatures", pics)
				}
				book.Close()
				batch, _, e := s.ExportDocuments(f.ctx, DocumentExportInput{Kind: d.Kind, IDs: []string{d.ID}})
				if e != nil {
					t.Fatal(e)
				}
				b := must(excelize.OpenReader(bytes.NewReader(batch)))(t)
				for cell, value := range expected {
					if must(b.GetCellValue(sheet, cell))(t) != value {
						t.Fatal("batch differs", cell)
					}
				}
				b.Close()
			}
			for _, kind := range []string{"inbound", "outbound"} {
				filter := Filter{Kind: kind, From: incoming.Created, Until: time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano), Search: "000012A"}
				report := must(s.PeriodReport(f.ctx, filter))(t)
				if report.Total != 1 {
					t.Fatal(report)
				}
				values := map[string]string{}
				for i, c := range report.Columns {
					values[c] = report.Items[0].Cells[i]
				}
				if values["料号"] != "000012A" || values["保管员"] != "保管账号" && values["保管"] != "保管账号" {
					t.Fatal(values)
				}
				if kind == "inbound" && (values["供应商"] != "=供应商" || values["质量证明书份数"] != "0" || values["运杂费（整单，勿累加）"] != "30.5" || report.KnownAmount != "20.00") {
					t.Fatal(values)
				}
				if kind == "outbound" && (values["工程编号"] != "000P-A" || values["领用人"] != "外部领用人" || report.KnownAmount != "37.50") {
					t.Fatal(values)
				}
				data, _, e := s.ExportPeriodReport(f.ctx, filter)
				if e != nil {
					t.Fatal(e)
				}
				book := must(excelize.OpenReader(bytes.NewReader(data)))(t)
				sheet := book.GetSheetList()[0]
				for i, c := range report.Columns {
					cell, _ := excelize.CoordinatesToCellName(i+1, 5)
					if must(book.GetCellValue(sheet, cell))(t) != values[c] {
						t.Fatal("report export mismatch", c)
					}
				}
				book.Close()
			}
			if raw(must(s.Stock(f.ctx, Filter{}))(t)) != before {
				t.Fatal("exports changed stock")
			}
		})
	}
}

func TestDocumentFieldsRejectInvalidInputAndDoNotSign(t *testing.T) {
	f := setup(t, false)
	negative := int64(-1)
	for _, details := range []DocumentFields{{CertificateCount: &negative}, {Freight: "-2"}, {Project: "wrong kind"}, {Purchaser: Personnel{UserID: "missing", Name: "spoof"}}} {
		_, e := f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Details: details, Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "1"}}})
		if e == nil {
			t.Fatal("invalid details accepted", details)
		}
	}
	if must(f.s.Documents(f.ctx, "inbound", Filter{}))(t).Total != 0 {
		t.Fatal("invalid input posted stock")
	}
	if _, e := f.s.Personnel(testContext("catalog", authorization.Grants{MaterialsCatalog: true})); e == nil {
		t.Fatal("catalog-only user read personnel")
	}
	ctx := testContext("signer", requisitionGrants())
	sig := sign(t, f.s, ctx, color.NRGBA{A: 255})
	app := must(f.s.Submit(ctx, requisitionInput()))(t)
	changed := authorization.WithActor(context.Background(), authorization.Actor{ID: "signer", DisplayName: "改名后", Grants: requisitionGrants(), Valid: func() bool { return true }})
	next := sign(t, f.s, changed, color.NRGBA{G: 255, A: 255})
	app = must(f.s.Approve(changed, app.ID, ApprovalInput{Mutation: operation(), Version: app.Version, Stage: "review", Decision: "approved"}))(t)
	if app.Steps[0].Actor != "signer" || app.Steps[0].SignatureVersion != sig.Version || app.Steps[0].SignatureID != sig.AssetID || app.Steps[1].Actor != "改名后" || app.Steps[1].SignatureVersion != next.Version {
		t.Fatal("signing snapshots drift", app.Steps)
	}
}

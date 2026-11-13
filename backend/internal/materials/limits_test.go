package materials

import (
	"fmt"
	"image/color"
	"testing"
)

func TestDocumentAndAttachmentLimitsRollbackWholeRequest(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			input := DocumentInput{Mutation: operation()}
			for i := 0; i < 100; i++ {
				item := must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: fmt.Sprintf("边界物料%03d", i), Unit: "个", CategoryID: f.normal.ID, Price: "1", Warning: "0"}}))(t)
				input.Lines = append(input.Lines, LineInput{ItemID: item.ID, CategoryID: f.normal.ID, Quantity: "1", Price: "1"})
			}
			for i := 0; i < 10; i++ {
				asset := must(f.s.Upload(f.ctx, AssetInput{Mutation: operation(), Kind: "receipt", Name: fmt.Sprintf("receipt%d.png", i), Data: imageBytes(color.NRGBA{R: uint8(i), A: 255})}))(t)
				input.AssetIDs = append(input.AssetIDs, asset.ID)
			}
			valid := must(f.s.Confirm(f.ctx, "inbound", input))(t)
			if len(valid.Lines) != 100 || len(valid.AssetIDs) != 10 || valid.KnownAmount != "100.00" {
				t.Fatal("maximum legal document changed")
			}
			over := input
			over.Mutation = operation()
			over.Lines = append(append([]LineInput{}, input.Lines...), input.Lines[0])
			if _, e := f.s.Confirm(f.ctx, "inbound", over); e == nil {
				t.Fatal("101 lines accepted")
			}
			over = input
			over.Mutation = operation()
			over.AssetIDs = append(append([]string{}, input.AssetIDs...), input.AssetIDs[0])
			if _, e := f.s.Confirm(f.ctx, "inbound", over); e == nil {
				t.Fatal("11 photos accepted")
			}
			over = input
			over.Mutation = operation()
			over.Lines = []LineInput{input.Lines[0], input.Lines[0]}
			if _, e := f.s.Confirm(f.ctx, "inbound", over); e == nil {
				t.Fatal("duplicate item/category accepted")
			}
			docs := must(f.s.Documents(f.ctx, "inbound", Filter{}))(t)
			if docs.Total != 1 {
				t.Fatal("failed request partially posted")
			}
			for _, line := range input.Lines {
				stock := must(f.s.Stock(f.ctx, Filter{ItemID: line.ItemID}))(t)
				if len(stock.Items) != 1 || stock.Items[0].Quantity != "1" {
					t.Fatal("limit rejection changed stock", stock)
				}
			}
		})
	}
}

func TestMaximumDecimalAcrossCategoriesAndReturns(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			maximum := "99999999999.9999"
			f.item.Price = maximum
			f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
			f.inbound(t, maximum, Application{})
			extra := DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.scrap.ID, Quantity: "0.0001"}}}
			if _, e := f.s.Confirm(f.ctx, "inbound", extra); e == nil {
				t.Fatal("total cap exceeded through another category")
			}
			out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, maximum)))(t)
			if out.KnownAmount != "9999999999999980000000.00" {
				t.Fatalf("large decimal rounded via float: %s", out.KnownAmount)
			}
			extra.Mutation = operation()
			extra.Lines[0].Quantity = maximum
			must(f.s.Confirm(f.ctx, "inbound", extra))(t)
			ret := DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, TargetCategoryID: f.normal.ID, Quantity: "0.0001"}}}
			if _, e := f.s.Confirm(f.ctx, "return", ret); e == nil {
				t.Fatal("return exceeded inventory limit")
			}
			detail := must(f.s.Document(f.ctx, out.ID, Filter{}))(t)
			if detail.Returns.Total != 0 || detail.Document.Lines[0].Remaining != maximum {
				t.Fatal("failed return consumed remaining quantity")
			}
			balance := f.stock(t, f.scrap.ID)
			must(f.s.Confirm(f.ctx, "transfer", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.scrap.ID, TargetCategoryID: f.normal.ID, Quantity: "0.0001", ItemVersion: balance.Version, BalanceVersion: balance.BalanceVersion}}}))(t)
			if normal := f.stock(t, f.normal.ID); normal.Quantity != "0.0001" || normal.TotalQuantity != maximum {
				t.Fatal("transfer at limit changed total")
			}
		})
	}
}

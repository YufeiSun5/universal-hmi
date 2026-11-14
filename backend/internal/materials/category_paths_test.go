package materials

import (
	"strings"
	"testing"
)

func TestCategoryPathsDisambiguateBalancesAndFreezeDocuments(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			root := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "一号库"}}))(t)
			leaf := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "配件", ParentID: root.ID}}))(t)
			otherRoot := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "二号库"}}))(t)
			otherLeaf := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "配件", ParentID: otherRoot.ID}}))(t)
			f.normal = leaf
			f.item.CategoryID = leaf.ID
			f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
			f.inbound(t, "2", Application{})
			must(f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: otherLeaf.ID, Quantity: "3"}}}))(t)
			balances := must(f.s.Stock(f.ctx, Filter{ItemID: f.item.ID}))(t)
			if len(balances.Items) != 2 {
				t.Fatal(balances)
			}
			for _, balance := range balances.Items {
				if !strings.Contains(balance.StockCategory, " / 配件") {
					t.Fatalf("ambiguous category %q", balance.StockCategory)
				}
			}
			preview := must(f.s.PreviewOutbound(f.ctx, DocumentInput{Lines: []LineInput{{ItemID: f.item.ID, CategoryID: leaf.ID, Quantity: "1"}}}))(t)
			if preview.Lines[0].Category != "一号库 / 配件" {
				t.Fatal(preview)
			}
			out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
			before := f.stock(t, leaf.ID).TotalQuantity
			if _, e := f.s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1"}}}); e == nil {
				t.Fatal("empty target category accepted")
			}
			if _, e := f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, Quantity: "1"}}}); e == nil {
				t.Fatal("empty inbound category accepted")
			}
			if f.stock(t, leaf.ID).TotalQuantity != before {
				t.Fatal("invalid category changed stock")
			}
			root.Name = "主库"
			root = must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: root}))(t)
			if live := f.stock(t, leaf.ID); live.StockCategory != "主库 / 配件" {
				t.Fatalf("renamed ancestor not reflected %+v", live)
			}
			destination := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "三号库"}}))(t)
			leaf.ParentID = destination.ID
			must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: leaf}))(t)
			if live := f.stock(t, leaf.ID); live.StockCategory != "三号库 / 配件" || live.Quantity != "1" || live.TotalQuantity != "4" {
				t.Fatalf("move changed stock %+v", live)
			}
			document := must(f.s.Document(f.ctx, out.ID, Filter{}))(t)
			if document.Document.Lines[0].Category != "一号库 / 配件" {
				t.Fatal("historical category path drifted")
			}
		})
	}
}

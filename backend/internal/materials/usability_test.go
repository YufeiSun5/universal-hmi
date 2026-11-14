package materials

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"sync"
	"testing"
)

func TestCategoryDeletionSerializesAgainstNewDependencies(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			other := independentService(t, f.s)
			for _, dependency := range []string{"child", "stock"} {
				parent := must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "竞态" + dependency}}))(t)
				preflight := must(f.s.CategoryDeletion(f.ctx, parent.ID))(t)
				if !preflight.CanDelete {
					t.Fatal("unexpected dependency")
				}
				start := make(chan struct{})
				results := make(chan error, 2)
				var wg sync.WaitGroup
				wg.Add(2)
				go func() {
					defer wg.Done()
					<-start
					_, e := f.s.SetCategoryDeleted(f.ctx, parent.ID, CategoryDeletionInput{Mutation: operation(), Version: parent.Version, Deleted: true})
					results <- e
				}()
				go func() {
					defer wg.Done()
					<-start
					var e error
					if dependency == "child" {
						_, e = other.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "并发子类", ParentID: parent.ID}})
					} else {
						_, e = other.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: parent.ID, Quantity: "1"}}})
					}
					results <- e
				}()
				close(start)
				wg.Wait()
				close(results)
				success := 0
				for e := range results {
					if e == nil {
						success++
					}
				}
				if success != 1 {
					t.Fatalf("expected exactly one transaction, got %d", success)
				}
				state := must(f.s.CategoryDeletion(f.ctx, parent.ID))(t)
				if state.Category.Deleted && (state.Children > 0 || state.Balances > 0) {
					t.Fatal("dangling category dependency", state)
				}
			}
		})
	}
}

func TestCategoryDeletionKeepsHistoryAndChecksDependencies(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			parent := must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "父分类"}}))(t)
			child := must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "子分类", ParentID: parent.ID}}))(t)
			del := func(c Category) (Category, error) {
				return s.SetCategoryDeleted(f.ctx, c.ID, CategoryDeletionInput{Mutation: operation(), Version: c.Version, Deleted: true})
			}
			if _, e := del(parent); e == nil {
				t.Fatal("deleted live parent")
			}
			if _, e := del(f.normal); e == nil {
				t.Fatal("deleted item default")
			}
			denied := testContext("requester", authorization.Grants{MaterialsRequest: true})
			if _, e := s.CategoryDeletion(denied, child.ID); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal(e)
			}
			must(s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: child.ID, Quantity: "3", Price: "2"}}}))(t)
			if _, e := del(child); e == nil {
				t.Fatal("deleted stock")
			}
			b := f.stock(t, child.ID)
			out := must(s.Confirm(f.ctx, "outbound", DocumentInput{Mutation: operation(), SignatureVersion: f.sig.Version, Purpose: "维修", Lines: []LineInput{{ItemID: f.item.ID, CategoryID: child.ID, Quantity: "3", ItemVersion: b.Version, BalanceVersion: b.BalanceVersion}}}))(t)
			input := CategoryDeletionInput{Mutation: operation(), Version: child.Version, Deleted: true}
			child = must(s.SetCategoryDeleted(f.ctx, child.ID, input))(t)
			retry := must(s.SetCategoryDeleted(f.ctx, child.ID, input))(t)
			if retry.Version != child.Version {
				t.Fatal("delete retry not idempotent")
			}
			if _, e := s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: child}); e == nil {
				t.Fatal("save resurrected deleted category")
			}
			if _, e := s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: child.ID, Quantity: "1"}}}); e == nil {
				t.Fatal("new inbound targets deleted category")
			}
			if _, e := s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "new", Unit: "个", Warning: "0", CategoryID: child.ID}}); e == nil {
				t.Fatal("item targets deleted category")
			}
			deleted := must(s.Categories(f.ctx, Filter{Status: "deleted"}))(t)
			if deleted.Total != 1 || !deleted.Items[0].Deleted {
				t.Fatalf("deleted %+v", deleted)
			}
			history := must(s.Document(f.ctx, out.ID, Filter{}))(t)
			if history.Document.Lines[0].Category != "父分类 / 子分类" {
				t.Fatal("history changed")
			}
			must(s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.scrap.ID}}}))(t)
			if _, e := s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: child.ID}}}); e == nil {
				t.Fatal("return to deleted category")
			}
			parent = must(del(parent))(t)
			if _, e := s.SetCategoryDeleted(f.ctx, child.ID, CategoryDeletionInput{Mutation: operation(), Version: child.Version}); e == nil {
				t.Fatal("restored under deleted parent")
			}
			parent = must(s.SetCategoryDeleted(f.ctx, parent.ID, CategoryDeletionInput{Mutation: operation(), Version: parent.Version}))(t)
			child = must(s.SetCategoryDeleted(f.ctx, child.ID, CategoryDeletionInput{Mutation: operation(), Version: child.Version}))(t)
			if child.Deleted {
				t.Fatal("not restored")
			}
		})
	}
}

func TestDocumentPeriodAndSubtreeSummary(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			child := must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "子类", ParentID: f.normal.ID}}))(t)
			wire := must(s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "电线", Unit: "米", Warning: "0", CategoryID: child.ID}}))(t)
			first := must(s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{
				{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "2", Price: "0.1"},
				{ItemID: wire.ID, CategoryID: child.ID, Quantity: "1.25"},
				{ItemID: f.item.ID, CategoryID: f.scrap.ID, Quantity: "3", Price: "10"},
			}}))(t)
			second := must(s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "1", Price: "0.2"}}}))(t)
			// Business-day boundaries are canonical UTC; the exact next midnight is excluded.
			for key, at := range map[string]string{first.ID: "2026-11-12T16:00:00.000000000Z", second.ID: "2026-11-13T16:00:00.000000000Z"} {
				d := must(getDocument(s.db, key))(t)
				d.Created = at
				if _, e := s.db.Exec("UPDATE materials_documents SET created=?,body=? WHERE id=?", at, raw(d), key); e != nil {
					t.Fatal(e)
				}
			}
			filter := Filter{CategoryID: f.normal.ID, From: "2026-11-13T00:00:00+08:00", Until: "2026-11-14T00:00:00+08:00", Limit: 1}
			p := must(s.Documents(f.ctx, "inbound", filter))(t)
			if p.Total != 1 || p.Summary.Products != 2 || p.Summary.KnownAmount != "0.20" || p.Summary.MissingPrices != 1 || len(p.Summary.Quantities) != 2 {
				t.Fatalf("summary %+v", p.Summary)
			}
			if p.Items[0].KnownAmount != "30.20" || p.Items[0].MatchedAmount != "0.20" {
				t.Fatalf("partial %+v", p.Items[0])
			}
			filter.Until = ""
			p = must(s.Documents(f.ctx, "inbound", filter))(t)
			filter.Offset = 1
			next := must(s.Documents(f.ctx, "inbound", filter))(t)
			if p.Total != 2 || p.Summary.KnownAmount != "0.40" || raw(p.Summary) != raw(next.Summary) {
				t.Fatalf("pagination changed summary: %+v %+v", p.Summary, next.Summary)
			}
			items := must(s.Items(f.ctx, Filter{CategoryID: f.normal.ID}))(t)
			stock := must(s.Stock(f.ctx, Filter{CategoryID: f.normal.ID}))(t)
			if items.Total != 2 || stock.Total != 2 {
				t.Fatalf("subtree items %d stock %d", items.Total, stock.Total)
			}
			out := must(s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
			old := "2026-10-01T00:00:00.000000000Z"
			out.Created = old
			if _, e := s.db.Exec("UPDATE materials_documents SET created=?,body=? WHERE id=?", old, raw(out), out.ID); e != nil {
				t.Fatal(e)
			}
			must(s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: child.ID}}}))(t)
			period := must(s.Documents(f.ctx, "outbound", Filter{From: "2026-11-01T00:00:00Z", CategoryID: f.normal.ID}))(t)
			if period.Total != 0 || period.ReturnSummary.Documents != 1 || period.ReturnSummary.KnownAmount != "12.50" {
				t.Fatalf("period return %+v", period)
			}
			if _, e := s.Documents(testContext("requester", authorization.Grants{MaterialsRequest: true}), "inbound", Filter{}); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal(e)
			}
			if _, e := s.Documents(f.ctx, "inbound", Filter{From: "2026-11-02T00:00:00Z", Until: "2026-11-01T00:00:00Z"}); e == nil {
				t.Fatal("invalid range accepted")
			}
		})
	}
}

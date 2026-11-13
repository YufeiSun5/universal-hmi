package materials

import (
	"testing"
	"time"
)

func TestTimeFiltersUseInstantsAndPreserveFractions(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			s := testService(t, pg)
			ctx := testContext("warehouse", allGrants())
			c := must(s.SaveCategory(ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "normal"}}))(t)
			item := must(s.SaveItem(ctx, ItemInput{Mutation: operation(), Item: Item{Name: "valve", Unit: "piece", CategoryID: c.ID, Warning: "0"}}))(t)
			app := must(s.Submit(ctx, ApplicationInput{Mutation: operation(), Text: "request"}))(t)
			doc := must(s.Confirm(ctx, "inbound", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: item.ID, CategoryID: c.ID, Quantity: "1"}}}))(t)
			// Same instant, deliberately encoded with another offset and fewer digits.
			instant := time.Date(2026, 11, 13, 15, 59, 59, 999999000, time.UTC)
			fixed := instant.Format(timestampLayout)
			for _, table := range []string{"materials_applications", "materials_documents", "materials_ledger"} {
				if _, err := s.db.Exec("UPDATE "+table+" SET created=?", fixed); err != nil {
					t.Fatal(err)
				}
			}
			filter := Filter{From: "2026-11-13T23:59:59+08:00", To: "2026-11-13T23:59:59.999999+08:00"}
			apps := must(s.Applications(ctx, filter))(t)
			if apps.Total != 1 || apps.Items[0].ID != app.ID {
				t.Fatal(apps)
			}
			docs := must(s.Documents(ctx, "inbound", filter))(t)
			if docs.Total != 1 || docs.Items[0].ID != doc.ID {
				t.Fatal(docs)
			}
			movements := must(s.Movements(ctx, filter))(t)
			if movements.Total != 1 {
				t.Fatal(movements)
			}
			filter.From = "2026-11-14T00:00:00+08:00"
			filter.To = ""
			if got := must(s.Documents(ctx, "inbound", filter))(t); got.Total != 0 {
				t.Fatal(got)
			}
			if _, err := s.Applications(ctx, Filter{From: "invalid"}); err == nil {
				t.Fatal("invalid date accepted")
			}
			if _, err := s.Movements(ctx, Filter{From: "2026-11-14T00:00:00Z", To: "2026-11-13T00:00:00Z"}); err == nil {
				t.Fatal("reversed range accepted")
			}
		})
	}
}

package externaldata

import (
	"context"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestHeatPricesSharedPersistenceConflictAndAuthorization(t *testing.T) {
	s, src, history := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "能耗", SourceID: src.ID, Kind: "energy"})
	if e != nil {
		t.Fatal(e)
	}
	ctx := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}})
	one, e := s.SaveHeatPrice(ctx, view.ID, HeatPriceChange{Year: 2025, UnitPrice: "20.123456"})
	if e != nil || one.Revision != 1 {
		t.Fatal(one, e)
	}
	// A second service instance reads the same persisted shared book.
	other, e := Open(s.repo, filepath.Join(t.TempDir(), "secrets"))
	if e != nil {
		t.Fatal(e)
	}
	two, e := other.HeatPrices(ctx, view.ID)
	if e != nil || len(two.Items) != 1 || two.Items[0].UnitPrice != "20.123456" {
		t.Fatal(two, e)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, service := range []*Service{s, other} {
		wg.Add(1)
		go func(service *Service) {
			defer wg.Done()
			_, e := service.SaveHeatPrice(ctx, view.ID, HeatPriceChange{Year: 2026, UnitPrice: "0", Revision: 1})
			results <- e
		}(service)
	}
	wg.Wait()
	close(results)
	passed, conflicts := 0, 0
	for e := range results {
		if e == nil {
			passed++
		} else if errors.Is(e, ErrConflict) {
			conflicts++
		} else {
			t.Fatal(e)
		}
	}
	if passed != 1 || conflicts != 1 {
		t.Fatal(passed, conflicts)
	}
	final, e := s.HeatPrices(ctx, view.ID)
	if e != nil || final.Revision != 2 || len(final.Items) != 2 || value(final.price(2026)) != "0" {
		t.Fatal(final, e)
	}
	for _, price := range []string{"-1", "NaN", "1e2", "1/2", "1.1234567", "100000000"} {
		if _, e = s.SaveHeatPrice(ctx, view.ID, HeatPriceChange{Year: 2026, UnitPrice: price, Revision: 2}); e == nil {
			t.Fatal(price)
		}
	}
	if _, e = s.SaveHeatPrice(actor(authorization.Grants{Roles: []string{"viewer"}}), view.ID, HeatPriceChange{Year: 2026, UnitPrice: "2", Revision: 2}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	if _, e = s.HeatPrices(context.Background(), history.ID); !errors.Is(e, ErrMissing) {
		t.Fatal(e)
	}
	readonly := authorization.WithActor(context.Background(), authorization.Actor{ReadOnly: true, Valid: func() bool { return true }, Grants: authorization.Grants{ExternalScreenIDs: []string{view.ID}}})
	if _, e = s.SaveHeatPrice(readonly, view.ID, HeatPriceChange{Year: 2026, UnitPrice: "2", Revision: 2}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	if _, e = s.HeatPrices(readonly, view.ID); e != nil {
		t.Fatal(e)
	}
}

func TestHeatPricesSeasonMissingTariffAndSnapshot(t *testing.T) {
	book := HeatPrices{Revision: 7, Items: []HeatPrice{{Year: 2026, UnitPrice: "2"}, {Year: 2027, UnitPrice: "3"}}}
	for _, date := range []struct {
		day  string
		year int
	}{{"2027-04-05", 2026}, {"2027-04-06", 0}, {"2027-11-04", 0}, {"2027-11-05", 2027}} {
		day, _ := time.ParseInLocation("2006-01-02", date.day, beijing)
		if priceSeason(day) != date.year {
			t.Fatal(date)
		}
		r, e := buildHeatSettlement(Request{Mode: "settlement_daily", UnitPrice: "999"}, day, day, day.AddDate(0, 0, 1), settlementSamples(date.day, "10"), book)
		if e != nil || r.PriceRevision != 7 || value(r.TotalHeat) != "80.000000000000" {
			t.Fatal(r, e)
		}
		if date.year == 0 {
			if r.TotalAmount != nil || r.Rows[0].Amount != nil {
				t.Fatal(r)
			}
		} else if value(r.Rows[0].Amount) != value(book.price(date.year))+"0.00" {
			t.Fatal(r.Rows[0])
		}
	}
	day := time.Date(2028, 11, 5, 0, 0, 0, 0, beijing)
	r, e := buildHeatSettlement(Request{Mode: "settlement_daily"}, day, day, day.AddDate(0, 0, 1), settlementSamples("2028-11-05", "10"), book)
	if e != nil || r.Incomplete != 8 || r.TotalAmount != nil || r.TotalHeat == nil || r.Rows[0].UnitPrice != nil {
		t.Fatal(r, e)
	}
}

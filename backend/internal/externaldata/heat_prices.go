package externaldata

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

const heatPricesKey = "heat_settlement_prices_v1"

type HeatPrice struct {
	Year      int    `json:"year"`
	UnitPrice string `json:"unit_price"`
	UpdatedAt string `json:"updated_at"`
	UpdatedBy string `json:"updated_by"`
}
type HeatPrices struct {
	Revision int64       `json:"revision"`
	Items    []HeatPrice `json:"items"`
}
type HeatPriceChange struct {
	Year      int    `json:"year"`
	UnitPrice string `json:"unit_price"`
	Revision  int64  `json:"revision"`
}
type configCAS interface {
	CompareAndSwapConfig(string, any, any) (bool, error)
}

func (s *Service) HeatPrices(ctx context.Context, screenID string) (HeatPrices, error) {
	_, view, err := s.source(ctx, screenID, true)
	if err != nil {
		return HeatPrices{}, err
	}
	if view.Kind != "energy" {
		return HeatPrices{}, ErrMissing
	}
	book := HeatPrices{Items: []HeatPrice{}}
	err = s.repo.LoadConfig(heatPricesKey, &book)
	return book, err
}

func (s *Service) SaveHeatPrice(ctx context.Context, screenID string, in HeatPriceChange) (HeatPrices, error) {
	if a, ok := authorization.FromContext(ctx); ok && (!a.Active() || a.ReadOnly) {
		return HeatPrices{}, authorization.ErrDenied
	}
	if in.Year < 1900 || in.Year > 2100 || !pricePattern.MatchString(in.UnitPrice) || in.Revision < 0 {
		return HeatPrices{}, fmt.Errorf("采暖季起始年应为1900～2100；单价须为非负数，最多6位小数")
	}
	old, err := s.HeatPrices(ctx, screenID)
	if err != nil {
		return HeatPrices{}, err
	}
	if old.Revision != in.Revision {
		return HeatPrices{}, ErrConflict
	}
	next := HeatPrices{Revision: old.Revision + 1, Items: append([]HeatPrice{}, old.Items...)}
	author := "local"
	if a, ok := authorization.FromContext(ctx); ok {
		author = a.ID
	}
	entry := HeatPrice{Year: in.Year, UnitPrice: in.UnitPrice, UpdatedAt: time.Now().UTC().Format(time.RFC3339Nano), UpdatedBy: author}
	found := false
	for i := range next.Items {
		if next.Items[i].Year == in.Year {
			next.Items[i] = entry
			found = true
			break
		}
	}
	if !found {
		next.Items = append(next.Items, entry)
	}
	sort.Slice(next.Items, func(i, j int) bool { return next.Items[i].Year < next.Items[j].Year })
	if !mayRead(ctx, screenID) {
		return HeatPrices{}, authorization.ErrDenied
	}
	if a, ok := authorization.FromContext(ctx); ok && a.Audit != nil {
		if err = a.Audit("heat-price.change", fmt.Sprint(in.Year), fmt.Sprintf("revision %d -> %d; price %s", old.Revision, next.Revision, in.UnitPrice)); err != nil {
			return HeatPrices{}, err
		}
	}
	repo, ok := s.repo.(configCAS)
	if !ok {
		return HeatPrices{}, fmt.Errorf("价格存储不支持原子更新")
	}
	var previous any = old
	if old.Revision == 0 {
		previous = nil
	}
	saved, err := repo.CompareAndSwapConfig(heatPricesKey, previous, next)
	if err != nil {
		return HeatPrices{}, err
	}
	if !saved {
		return HeatPrices{}, ErrConflict
	}
	return next, nil
}

// A seasonal tariff applies only from November 5 through April 5 inclusive.
func priceSeason(day time.Time) int {
	y, m, d := day.Date()
	if m > 11 || m == 11 && d >= 5 {
		return y
	}
	if m < 4 || m == 4 && d <= 5 {
		return y - 1
	}
	return 0
}
func (b HeatPrices) price(year int) *string {
	for _, p := range b.Items {
		if p.Year == year {
			v := p.UnitPrice
			return &v
		}
	}
	return nil
}

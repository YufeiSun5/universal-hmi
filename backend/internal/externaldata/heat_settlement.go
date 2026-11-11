package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Settlement is a projection of authorized whole-site statistics. It never
// derives whole-site consumption from zone readings or raw meter counters.
var heatSettlementSites = []Station{
	{"01-001", "中心站"}, {"01-003", "香港广场站"}, {"01-005", "怡景华府站"},
	{"02-002", "北站"}, {"02-003", "国奥首站"}, {"04-001", "南站"},
	{"04-003", "张屯"}, {"03-001", "西站"},
}

type HeatSettlementRow struct {
	UnitPrice *string `json:"unit_price"`
	Season    int     `json:"season"`
	Period    string  `json:"period"`
	Station   string  `json:"station"`
	Name      string  `json:"name"`
	Heat      *string `json:"heat"`
	Amount    *string `json:"amount"`
	Status    string  `json:"status"`
}
type HeatSettlement struct {
	PriceRevision int64               `json:"price_revision"`
	Mode          string              `json:"mode"`
	From          string              `json:"from"`
	To            string              `json:"to"`
	AsOf          string              `json:"as_of"`
	UnitPrice     string              `json:"unit_price"`
	Rows          []HeatSettlementRow `json:"rows"`
	TotalHeat     *string             `json:"total_heat"`
	TotalAmount   *string             `json:"total_amount"`
	Incomplete    int                 `json:"incomplete"`
}

var pricePattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,7})(\.[0-9]{1,6})?$`)
var heatPattern = regexp.MustCompile(`^[0-9]{1,30}(\.[0-9]{1,12})?$`)

func heatSettlementBounds(in Request, now time.Time) (time.Time, time.Time, error) {
	a, err := time.ParseInLocation("2006-01-02", in.Date, beijing)
	if err != nil || in.Station != "" || in.Offset != 0 {
		return a, a, fmt.Errorf("请选择有效统计日期")
	}
	b := a
	switch in.Mode {
	case "settlement_hourly":
	case "settlement_daily":
		if in.From != "" {
			a, err = time.ParseInLocation("2006-01-02", in.From, beijing)
			if err != nil {
				return a, b, fmt.Errorf("开始日期无效")
			}
			b, err = time.ParseInLocation("2006-01-02", in.To, beijing)
			if err != nil || b.Sub(a) > 30*24*time.Hour {
				return a, b, fmt.Errorf("日统计最多31天")
			}
		}
	case "settlement_monthly":
		a = time.Date(a.Year(), a.Month(), 1, 0, 0, 0, 0, beijing)
		b = a.AddDate(0, 1, -1)
	case "settlement_season":
		y := a.Year()
		if a.Before(time.Date(y, 11, 5, 0, 0, 0, 0, beijing)) {
			y--
		}
		a = time.Date(y, 11, 5, 0, 0, 0, 0, beijing)
		b = time.Date(y+1, 4, 5, 0, 0, 0, 0, beijing)
	default:
		return a, b, fmt.Errorf("无效结算周期")
	}
	today := now.In(beijing).Format("2006-01-02")
	if b.Before(a) || a.Year() < 2026 || a.Year() > 2100 || a.Format("2006-01-02") > today {
		return a, b, fmt.Errorf("请选择已开始的结算周期（2026年起）")
	}
	if (in.Mode == "settlement_daily" || in.Mode == "settlement_hourly") && b.Format("2006-01-02") > today {
		return a, b, fmt.Errorf("结束日期不能晚于今天")
	}
	return a, b, nil
}

func (s *Service) queryHeatSettlement(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	now := time.Now().UTC()
	start, end, err := heatSettlementBounds(in, now)
	if err != nil {
		return Result{}, err
	}
	prices, err := s.HeatPrices(ctx, view.ID)
	if err != nil {
		return Result{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, closeDB, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer closeDB()
	data, err := settlementStatistics(ctx, db, in, start, end, now)
	if err != nil {
		return Result{}, err
	}
	report, err := buildHeatSettlement(in, start, end, now, data, prices)
	if err != nil {
		return Result{}, err
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return Result{Points: []Point{}, Rows: []Row{}, HeatSettlement: report, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision}, nil
}

func buildHeatSettlement(in Request, start, end, now time.Time, data []Statistic, prices HeatPrices) (*HeatSettlement, error) {
	r := &HeatSettlement{Mode: in.Mode, From: start.Format("2006-01-02"), To: end.Format("2006-01-02"), AsOf: now.In(beijing).Format(time.RFC3339), UnitPrice: in.UnitPrice, Rows: []HeatSettlementRow{}}
	r.UnitPrice = ""
	r.PriceRevision = prices.Revision
	allowed := map[string]bool{}
	for _, site := range heatSettlementSites {
		allowed[site.Code] = true
	}
	index := map[string]Statistic{}
	hourly := in.Mode == "settlement_hourly"
	for _, v := range data {
		if !allowed[v.Station] || energyMetric(v.Label) != "heat" {
			continue
		}
		key := v.Date
		if hourly {
			h, err := time.Parse(time.RFC3339, value(v.Hour))
			if err != nil || h.Minute() != 0 || h.Second() != 0 {
				return nil, fmt.Errorf("热量小时标识无效")
			}
			key = h.In(beijing).Format("2006-01-02 15:00")
		}
		key += "/" + v.Station
		if _, exists := index[key]; exists {
			return nil, fmt.Errorf("数据库返回重复热量记录")
		}
		index[key] = v
	}
	today := now.In(beijing).Format("2006-01-02")
	periods := []string{}
	for d := start; !d.After(end) && d.Format("2006-01-02") <= today; d = d.AddDate(0, 0, 1) {
		if hourly {
			for h := 0; h < 24; h++ {
				t := d.Add(time.Duration(h) * time.Hour)
				if t.After(now) {
					break
				}
				periods = append(periods, t.Format("2006-01-02 15:00"))
			}
		} else {
			periods = append(periods, d.Format("2006-01-02"))
		}
	}
	groups := [][]string{}
	if in.Mode == "settlement_monthly" || in.Mode == "settlement_season" {
		for _, p := range periods {
			day, _ := time.ParseInLocation("2006-01-02", p[:10], beijing)
			if len(groups) == 0 {
				groups = append(groups, []string{p})
				continue
			}
			last := groups[len(groups)-1]
			prior, _ := time.ParseInLocation("2006-01-02", last[0][:10], beijing)
			if priceSeason(day) != priceSeason(prior) {
				groups = append(groups, []string{p})
			} else {
				groups[len(groups)-1] = append(last, p)
			}
		}
	} else {
		for _, p := range periods {
			groups = append(groups, []string{p})
		}
	}
	totalHeat, totalAmount := new(big.Rat), new(big.Rat)
	heatRows, amountRows := 0, 0
	for _, group := range groups {
		label := group[0]
		day, _ := time.ParseInLocation("2006-01-02", label[:10], beijing)
		year := priceSeason(day)
		tariff := prices.price(year)
		var price *big.Rat
		if tariff != nil {
			price, _ = new(big.Rat).SetString(*tariff)
		}

		if in.Mode == "settlement_monthly" {
			label = start.Format("2006-01")
			if len(groups) > 1 {
				label = group[0] + "～" + group[len(group)-1]
			}
		}
		if in.Mode == "settlement_season" {
			label = fmt.Sprintf("%d–%d采暖季", start.Year(), end.Year())
		}
		for _, site := range heatSettlementSites {
			sum := new(big.Rat)
			missing, available := 0, 0
			partial := false
			diagnostic := ""
			for _, p := range group {
				v, exists := index[p+"/"+site.Code]
				heat, status := v.DayUsage, value(v.DayStatus)
				if hourly {
					heat, status = v.HourUsage, value(v.HourStatus)
				}
				// The database returns the available whole-site consumption even
				// when some hours or members are missing. Status is diagnostic;
				// it must not discard an existing business value.
				if !exists || v.Unit != "GJ" || heat == nil || !heatPattern.MatchString(value(heat)) {
					missing++
					continue
				}
				n, _ := new(big.Rat).SetString(*heat)
				sum.Add(sum, n)
				available++
				if diagnostic == "" && status != "" && status != "有效" && status != "截至采样有效" && status != "完整" && status != "正常" {
					diagnostic = status
				}
				if strings.HasPrefix(p, today) && (!hourly || p == now.In(beijing).Format("2006-01-02 15:00")) {
					partial = true
				}
			}
			row := HeatSettlementRow{UnitPrice: tariff, Season: year, Period: label, Station: site.Code, Name: site.Name, Status: "完整"}
			incomplete := missing > 0 || diagnostic != ""
			if missing > 0 {
				row.Status = fmt.Sprintf("缺数（%d/%d）", missing, len(group))
			} else if diagnostic != "" {
				row.Status = diagnostic
			} else if partial {
				row.Status = "截至当前统计"
			}
			if available > 0 {
				h := sum.FloatString(12)
				row.Heat = &h
				heatRows++
				totalHeat.Add(totalHeat, sum)
				if price == nil {
					if year == 0 {
						row.Status += "；非采暖季未计价"
					} else {
						row.Status += fmt.Sprintf("；%d–%d采暖季单价未设置", year, year+1)
					}
					incomplete = true
				} else {
					a := new(big.Rat).Mul(sum, price).FloatString(2)
					row.Amount = &a
					n, _ := new(big.Rat).SetString(a)
					totalAmount.Add(totalAmount, n)
					amountRows++
				}
			}
			if incomplete {
				r.Incomplete++
			}
			r.Rows = append(r.Rows, row)
		}
	}
	if heatRows > 0 {
		h := totalHeat.FloatString(12)
		r.TotalHeat = &h
	}
	if amountRows > 0 {
		a := totalAmount.FloatString(2)
		r.TotalAmount = &a
	}
	if len(r.Rows) > 0 && r.Rows[0].UnitPrice != nil {
		r.UnitPrice = *r.Rows[0].UnitPrice
		for _, row := range r.Rows {
			if row.UnitPrice == nil || *row.UnitPrice != r.UnitPrice {
				r.UnitPrice = ""
				break
			}
		}
	}
	return r, nil
}

// Two workers amortize per-day procedure latency without unbounded fan-out.
// Both use the same frozen as-of time and the source's bounded connection pool.
func settlementStatistics(ctx context.Context, db *sql.DB, in Request, start, end, now time.Time) ([]Statistic, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	today := now.In(beijing).Format("2006-01-02")
	dates := make(chan string, 184)
	for day := start; !day.After(end) && day.Format("2006-01-02") <= today; day = day.AddDate(0, 0, 1) {
		if date := day.Format("2006-01-02"); date >= periodStart {
			dates <- date
		}
	}
	close(dates)
	var mu sync.Mutex
	var wg sync.WaitGroup
	var firstError error
	data := []Statistic{}
	fail := func(err error) {
		mu.Lock()
		if firstError == nil {
			firstError = err
			cancel()
		}
		mu.Unlock()
	}
	workers := min(2, len(dates))
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for date := range dates {
				if ctx.Err() != nil {
					return
				}
				rows, err := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", nil), sql.Named("site", nil), sql.Named("whole", true), sql.Named("date", date), sql.Named("hourly", in.Mode == "settlement_hourly"), sql.Named("asof", now))
				if err != nil {
					fail(interfaceFailure(ctx, "热量结算", "执行存储过程", err))
					return
				}
				batch, err := scanStatistics(rows, true, date, today)
				rows.Close()
				if err != nil {
					fail(interfaceFailure(ctx, "热量结算", "读取返回字段", err))
					return
				}
				mu.Lock()
				over := len(data)+len(batch) > 25000
				if !over {
					data = append(data, batch...)
				}
				mu.Unlock()
				if over {
					fail(fmt.Errorf("结算结果过大"))
					return
				}
			}
		}()
	}
	wg.Wait()
	if firstError != nil {
		return nil, firstError
	}
	if ctx.Err() != nil {
		return nil, queryError(ctx)
	}
	return data, nil
}

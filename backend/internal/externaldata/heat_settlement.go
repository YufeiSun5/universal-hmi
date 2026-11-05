package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"regexp"
	"strings"
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
	Period  string  `json:"period"`
	Station string  `json:"station"`
	Name    string  `json:"name"`
	Heat    *string `json:"heat"`
	Amount  *string `json:"amount"`
	Status  string  `json:"status"`
}
type HeatSettlement struct {
	Mode        string              `json:"mode"`
	From        string              `json:"from"`
	To          string              `json:"to"`
	AsOf        string              `json:"as_of"`
	UnitPrice   string              `json:"unit_price"`
	Rows        []HeatSettlementRow `json:"rows"`
	TotalHeat   *string             `json:"total_heat"`
	TotalAmount *string             `json:"total_amount"`
	Incomplete  int                 `json:"incomplete"`
}

var pricePattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,7})(\.[0-9]{1,6})?$`)
var heatPattern = regexp.MustCompile(`^[0-9]{1,30}(\.[0-9]{1,12})?$`)

func heatSettlementBounds(in Request, now time.Time) (time.Time, time.Time, error) {
	a, err := time.ParseInLocation("2006-01-02", in.Date, beijing)
	if err != nil || in.Station != "" || in.Offset != 0 || !pricePattern.MatchString(in.UnitPrice) {
		return a, a, fmt.Errorf("请选择日期并填写有效单价（元/GJ，最多6位小数）")
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
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, closeDB, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer closeDB()
	data := []Statistic{}
	today := now.In(beijing).Format("2006-01-02")
	// The deployed procedure supports all whole sites in one call. Filter the
	// result to the fixed settlement list before constructing the response.
	for day := start; !day.After(end) && day.Format("2006-01-02") <= today; day = day.AddDate(0, 0, 1) {
		date := day.Format("2006-01-02")
		if date < periodStart {
			continue
		} // Preserve unavailable days as gaps.
		rows, e := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", nil), sql.Named("site", nil), sql.Named("whole", true), sql.Named("date", date), sql.Named("hourly", in.Mode == "settlement_hourly"), sql.Named("asof", now))
		if e != nil {
			return Result{}, statisticsError(ctx)
		}
		batch, e := scanStatistics(rows, true, date, today)
		rows.Close()
		if e != nil {
			return Result{}, statisticsError(ctx)
		}
		data = append(data, batch...)
		if len(data) > 25000 {
			return Result{}, fmt.Errorf("结算结果过大")
		}
	}
	report, err := buildHeatSettlement(in, start, end, now, data)
	if err != nil {
		return Result{}, err
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return Result{Points: []Point{}, Rows: []Row{}, HeatSettlement: report, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision}, nil
}

func buildHeatSettlement(in Request, start, end, now time.Time, data []Statistic) (*HeatSettlement, error) {
	r := &HeatSettlement{Mode: in.Mode, From: start.Format("2006-01-02"), To: end.Format("2006-01-02"), AsOf: now.In(beijing).Format(time.RFC3339), UnitPrice: in.UnitPrice, Rows: []HeatSettlementRow{}}
	price, ok := new(big.Rat).SetString(in.UnitPrice)
	if !ok || !pricePattern.MatchString(in.UnitPrice) {
		return nil, fmt.Errorf("无效单价")
	}
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
		groups = append(groups, periods)
	} else {
		for _, p := range periods {
			groups = append(groups, []string{p})
		}
	}
	totalHeat, totalAmount := new(big.Rat), new(big.Rat)
	for _, group := range groups {
		label := group[0]
		if in.Mode == "settlement_monthly" {
			label = start.Format("2006-01")
		}
		if in.Mode == "settlement_season" {
			label = fmt.Sprintf("%d–%d采暖季", start.Year(), end.Year())
		}
		for _, site := range heatSettlementSites {
			sum := new(big.Rat)
			missing := 0
			partial := false
			for _, p := range group {
				v, exists := index[p+"/"+site.Code]
				heat, status := v.DayUsage, value(v.DayStatus)
				if hourly {
					heat, status = v.HourUsage, value(v.HourStatus)
				}
				// Only the database's positive validity statuses are settleable.
				valid := status == "有效" || status == "截至采样有效" || status == "完整" || status == "正常"
				if !exists || v.Unit != "GJ" || heat == nil || !heatPattern.MatchString(value(heat)) || !valid {
					missing++
					continue
				}
				n, _ := new(big.Rat).SetString(*heat)
				sum.Add(sum, n)
				if strings.HasPrefix(p, today) && (!hourly || p == now.In(beijing).Format("2006-01-02 15:00")) {
					partial = true
				}
			}
			row := HeatSettlementRow{Period: label, Station: site.Code, Name: site.Name, Status: "完整"}
			if missing > 0 {
				row.Status = fmt.Sprintf("缺数（%d/%d）", missing, len(group))
				r.Incomplete++
			} else {
				h := sum.FloatString(12)
				a := new(big.Rat).Mul(sum, price).FloatString(2)
				row.Heat = &h
				row.Amount = &a
				if partial {
					row.Status = "截至当前统计"
				}
				totalHeat.Add(totalHeat, sum)
				n, _ := new(big.Rat).SetString(a)
				totalAmount.Add(totalAmount, n)
			}
			r.Rows = append(r.Rows, row)
		}
	}
	if r.Incomplete == 0 {
		h, a := totalHeat.FloatString(12), totalAmount.FloatString(2)
		r.TotalHeat = &h
		r.TotalAmount = &a
	}
	return r, nil
}

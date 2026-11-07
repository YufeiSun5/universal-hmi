package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
)

// Period reports project stored daily consumption, never raw meter counters or
// zone sums presented as whole-site consumption. The original daily screen
// remains the authorization and source identity.
func (s *Service) queryPeriodReport(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	now := time.Now()
	if strings.TrimSpace(in.Station) == "" || len(in.Station) > 32 || strings.Contains(in.Station, ",") || in.Offset != 0 {
		return Result{}, fmt.Errorf("请选择单个站区")
	}
	start, end, err := heatSettlementBounds(Request{Mode: "settlement_" + in.Mode, Date: in.Date}, now)
	if err != nil {
		return Result{}, err
	}
	period := start.Format("2006-01")
	if in.Mode == "season" {
		period = fmt.Sprintf("%d–%d采暖季", start.Year(), end.Year())
	}
	first, _ := time.ParseInLocation("2006-01-02", periodStart, beijing)
	if start.Before(first) {
		start = first
	}
	today, _ := time.ParseInLocation("2006-01-02", now.In(beijing).Format("2006-01-02"), beijing)
	if end.After(today) {
		end = today
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, closeDB, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer closeDB()
	data := []Statistic{}
	// Reuse the deployed daily interface in bounded 31-day windows.
	for day := start; !day.After(end); {
		last := day.AddDate(0, 0, 30)
		if last.After(end) {
			last = end
		}
		rows, e := db.QueryContext(ctx, settlementProcedure, sql.Named("from", day.Format("2006-01-02")), sql.Named("to", last.Format("2006-01-02")), sql.Named("station", in.Station))
		if e != nil {
			return Result{}, interfaceError(ctx, "月报/采暖季报")
		}
		batch, e := scanInterfaceRows(rows, settlementFields, 25000, "+08:00")
		rows.Close()
		if e != nil {
			return Result{}, interfaceError(ctx, "月报/采暖季报")
		}
		for _, m := range batch {
			date := strings.Split(value(m["统计日期"]), "T")[0]
			if value(m["站区编码"]) != in.Station || date < day.Format("2006-01-02") || date > last.Format("2006-01-02") {
				return Result{}, interfaceError(ctx, "月报/采暖季报")
			}
			if energyMetric(value(m["测点编码"])) == "" {
				continue
			}
			data = append(data, Statistic{Date: date, Station: in.Station, Name: value(m["站区名称"]), Metric: value(m["测点编码"]), Unit: value(m["单位"]), DayUsage: m["完整日用量"], DaySubtotal: m["已结算小计"]})
			if len(data) > 25000 {
				return Result{}, fmt.Errorf("统计结果过大")
			}
		}
		day = last.AddDate(0, 0, 1)
	}
	result, err := buildPeriodReport(period, data)
	if err != nil {
		return Result{}, err
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return Result{Points: []Point{}, Rows: []Row{}, Statistics: result, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision}, nil
}

func buildPeriodReport(period string, data []Statistic) ([]Statistic, error) {
	groups := map[string]*Statistic{}
	sums := map[string]*big.Rat{}
	seen := map[string]bool{}
	labels := map[string]string{"heat": "热", "electricity": "电", "water": "水"}
	for _, r := range data {
		metric := energyMetric(r.Metric)
		if metric == "" {
			continue
		}
		key := r.Station + "/" + metric
		identity := key + "/" + r.Date
		if seen[identity] {
			return nil, fmt.Errorf("数据库返回重复日统计记录")
		}
		seen[identity] = true
		g := groups[key]
		if g == nil {
			g = &Statistic{Date: period, Station: r.Station, Name: r.Name, Metric: metric, Label: labels[metric], Unit: r.Unit, StatisticKind: "usage"}
			groups[key] = g
		} else if g.Unit != r.Unit {
			return nil, fmt.Errorf("统计周期内单位不一致，不能汇总")
		}
		v := r.DayUsage
		if v == nil {
			v = r.DaySubtotal
		}
		if v == nil || !heatPattern.MatchString(*v) {
			continue
		}
		n, ok := new(big.Rat).SetString(*v)
		if !ok {
			continue
		}
		if sums[key] == nil {
			sums[key] = new(big.Rat)
		}
		sums[key].Add(sums[key], n)
	}
	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	rank := map[string]int{"heat": 0, "electricity": 1, "water": 2}
	sort.Slice(keys, func(i, j int) bool {
		a, b := groups[keys[i]], groups[keys[j]]
		if a.Station != b.Station {
			return a.Station < b.Station
		}
		return rank[a.Metric] < rank[b.Metric]
	})
	out := []Statistic{}
	for _, key := range keys {
		g := groups[key]
		if sum := sums[key]; sum != nil {
			v := sum.FloatString(12)
			g.DayUsage = &v
		}
		out = append(out, *g)
	}
	return out, nil
}

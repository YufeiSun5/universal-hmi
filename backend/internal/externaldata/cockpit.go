package externaldata

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
)

// CockpitHeatSites returns the shared heat settlement roster with the
// standard site labels used in cockpit history.
func CockpitHeatSites() []Station {
	sites := make([]Station, 0, len(heatSettlementSites))
	for _, site := range heatSettlementSites {
		sites = append(sites, Station{Code: site.Code, Name: cockpitHeatSiteName(site)})
	}
	return sites
}

func cockpitEnergySiteName(code, fallback string) string {
	for _, site := range heatSettlementSites {
		if site.Code == code {
			return cockpitHeatSiteName(site)
		}
	}
	return fallback
}

func cockpitHeatSiteName(site Station) string {
	switch site.Code {
	case "02-002", "03-001", "04-001":
		return site.Name
	default:
		return siteName(site.Code)
	}
}

// CockpitEnergySites is the local site's known station catalog. The editor
// additionally merges in stations returned by the selected energy source.
func CockpitEnergySites() []Station {
	sites := make([]Station, 0, len(siteNames))
	for code, name := range siteNames {
		sites = append(sites, Station{Code: code, Name: cockpitEnergySiteName(code, name)})
	}
	slices.SortFunc(sites, func(a, b Station) int { return strings.Compare(a.Code, b.Code) })
	return sites
}

// CockpitAccess gives the shared preloader a configuration identity. Requests
// from viewers get the same screen-grant check as other external history reads.
func (s *Service) CockpitAccess(ctx context.Context, id string) (string, error) {
	source, view, err := s.source(ctx, id, true)
	if err != nil {
		return "", err
	}
	if view.Kind != "energy" {
		return "", errors.New("请选择能耗管理画面作为驾驶舱来源")
	}
	return fmt.Sprintf("%s-%d-%s-%d", view.ID, view.Revision, source.ID, source.Revision), nil
}

func (s *Service) CockpitHistory(ctx context.Context, id, part string, zones []string, now time.Time) (map[string]any, error) {
	source, view, err := s.source(ctx, id, true)
	if err != nil {
		return nil, err
	}
	if view.Kind != "energy" || len(zones) > 256 {
		return nil, errors.New("驾驶舱能耗画面或重点站区无效")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, release, err := s.database(ctx, source)
	if err != nil {
		return nil, err
	}
	defer release()
	local := now.In(beijing)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, beijing)
	switch part {
	case "today", "yesterday":
		reportDay, closed := day, local.Hour()
		if part == "yesterday" {
			reportDay, closed = day.AddDate(0, 0, -1), 24
		}
		rows, err := cockpitStats(ctx, db, true, reportDay, now)
		if err != nil {
			return nil, err
		}
		return cockpitTotals(rows, reportDay, now, closed, false), nil
	case "usage_days":
		return cockpitUsageDays(ctx, db, day, now)
	case "trends":
		values, err := cockpitPowerTrends(ctx, db, zones, now)
		if err != nil {
			return nil, err
		}
		return map[string]any{"values": values}, nil
	default:
		return nil, errors.New("无效的驾驶舱数据区块")
	}
}

func cockpitUsageDays(ctx context.Context, db *sql.DB, today, now time.Time) (map[string]any, error) {
	monthStart := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, beijing)
	weekStart := today.AddDate(0, 0, -6)
	from := monthStart
	if weekStart.Before(from) {
		from = weekStart
	}
	buckets := map[string][]map[string]any{"month": {}, "week": {}}
	for day := from; day.Before(today); day = day.AddDate(0, 0, 1) {
		rows, err := cockpitStats(ctx, db, false, day, now)
		if err != nil {
			return nil, err
		}
		result := cockpitTotals(rows, day, now, 0, true)
		if !day.Before(monthStart) {
			buckets["month"] = append(buckets["month"], result)
		}
		if !day.Before(weekStart) {
			buckets["week"] = append(buckets["week"], result)
		}
	}
	out := map[string]any{}
	for key, days := range buckets {
		labels := make([]string, 0, len(days))
		series := map[string]any{}
		for _, day := range days {
			labels = append(labels, day["date"].(string)[5:])
		}
		partial := make(map[string][]bool, len(cockpitUsageUnits))
		for metric := range cockpitUsageUnits {
			values := make([]*float64, len(days))
			availableOnly := make([]bool, len(days))
			for i, day := range days {
				values[i] = day["metrics"].(map[string]*float64)[metric]
				if values[i] == nil {
					values[i] = day["partial_metrics"].(map[string]*float64)[metric]
					availableOnly[i] = values[i] != nil
				}
			}
			series[metric] = values
			partial[metric] = availableOnly
		}
		series["labels"] = labels
		series["partial"] = partial
		out[key] = series
	}
	return out, nil
}

func cockpitStats(ctx context.Context, db *sql.DB, hourly bool, day, now time.Time) ([]Statistic, error) {
	date := day.Format("2006-01-02")
	rows, err := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", nil),
		sql.Named("site", nil), sql.Named("whole", true), sql.Named("date", date),
		sql.Named("hourly", hourly), sql.Named("asof", now.UTC()))
	if err != nil {
		return nil, statisticsError(ctx)
	}
	defer rows.Close()
	data, err := scanStatistics(rows, true, date, now.In(beijing).Format("2006-01-02"))
	if err != nil {
		return nil, statisticsError(ctx)
	}
	return data, nil
}

var cockpitUsageUnits = map[string]string{"heat": "GJ", "electricity": "kWh", "water": "t"}

type cockpitRank struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Value *float64 `json:"value"`
	Delta *float64 `json:"delta,omitempty"`
}

func cockpitTotals(rows []Statistic, day, now time.Time, closed int, includePartialDays bool) map[string]any {
	latest := map[string]map[string]Statistic{}
	sites := map[string]string{}
	// The settlement roster represents each shared heat meter once. Keep
	// the full source roster for the electricity and water denominators.
	hourly := map[string]map[string][]*float64{
		"heat":        make(map[string][]*float64, len(heatSettlementSites)),
		"electricity": {}, "water": {},
	}
	hours := hourly["heat"]
	for _, site := range heatSettlementSites {
		hours[site.Code] = make([]*float64, 24)
	}
	for _, r := range rows {
		sites[r.Station] = r.Name
		metric := energyMetric(r.Label)
		if metric == "" || r.Hour == nil || (metric == "heat" && hours[r.Station] == nil) {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, *r.Hour)
		if err != nil {
			continue
		}
		h := t.In(beijing).Hour()
		if latest[metric] == nil {
			latest[metric] = map[string]Statistic{}
		}
		old := latest[metric][r.Station]
		if old.Hour == nil || *old.Hour < *r.Hour {
			latest[metric][r.Station] = r
		}
		status := value(r.HourStatus)
		if r.Unit == cockpitUsageUnits[metric] && h < closed &&
			(status == "有效" || status == "有效含异常" || strings.HasPrefix(status, "截至采样有效")) {
			series := hourly[metric][r.Station]
			if series == nil {
				series = make([]*float64, 24)
				hourly[metric][r.Station] = series
			}
			series[h] = cockpitNumber(r.HourUsage)
		}
	}
	totals := map[string]*float64{}
	subtotals := map[string]*float64{}
	metricCoverage := map[string]int{}
	ranking := make([]cockpitRank, 0, len(heatSettlementSites))
	for _, site := range heatSettlementSites {
		heat := latest["heat"][site.Code]
		var v *float64
		if heat.Unit == "GJ" {
			v = cockpitNumber(heat.DayUsage)
		}
		ranking = append(ranking, cockpitRank{ID: site.Code, Name: cockpitHeatSiteName(site), Value: v})
	}
	metricRanking := map[string][]cockpitRank{"heat": ranking}
	for metric, unit := range cockpitUsageUnits {
		sum, count := 0.0, 0
		hasPartial := false
		if metric != "heat" {
			for id, name := range sites {
				row := latest[metric][id]
				var amount *float64
				if row.Unit == unit {
					amount = cockpitNumber(row.DayUsage)
				}
				metricRanking[metric] = append(metricRanking[metric], cockpitRank{ID: id, Name: cockpitEnergySiteName(id, name), Value: amount})
			}
		}
		for _, r := range latest[metric] {
			n := cockpitNumber(r.DayUsage)
			if n == nil || r.Unit != unit {
				continue
			}
			status := value(r.DayStatus)
			partial := includePartialDays && strings.HasPrefix(status, "部分有效")
			if partial || strings.HasPrefix(status, "截至采样有效") {
				sum += *n
				count++
				hasPartial = hasPartial || partial
			}
		}
		metricCoverage[metric] = count
		expected := len(sites)
		if metric == "heat" {
			expected = len(heatSettlementSites)
		}
		switch {
		case count > 0 && count == expected && !hasPartial:
			totals[metric] = &sum
		case count > 0:
			subtotals[metric] = &sum
		}
	}
	for _, ranked := range metricRanking {
		sortCockpitRanking(ranked)
	}
	network := make([]*float64, 24)
	partial := make([]*float64, 24)
	coverage := make([]int, 24)
	for h := 0; h < closed; h++ {
		sum, count := 0.0, 0
		for _, values := range hours {
			if values[h] != nil {
				sum += *values[h]
				count++
			}
		}
		coverage[h] = count
		switch {
		case count == len(heatSettlementSites):
			network[h] = &sum
		case count > 0:
			partial[h] = &sum
		}
	}
	return map[string]any{"date": day.Format("2006-01-02"), "at": now.UTC(), "metrics": totals,
		"partial_metrics": subtotals, "metric_coverage": metricCoverage,
		"closed_hours": closed, "hours": network, "partial_hours": partial,
		"hour_coverage": coverage, "station_count": len(sites), "heat_station_count": len(heatSettlementSites),
		"station_hours": hours, "ranking": ranking,
		"metric_rankings": metricRanking, "metric_hours": hourly}
}

// CockpitUnitRankings uses the same area for current intensity and comparison.
// A station with a missing area or incomplete hourly window keeps its row.
func CockpitUnitRankings(today, yesterday map[string]any, areas map[string]float64) map[string][]cockpitRank {
	ranks, _ := today["metric_rankings"].(map[string][]cockpitRank)
	current, _ := today["metric_hours"].(map[string]map[string][]*float64)
	previous, _ := yesterday["metric_hours"].(map[string]map[string][]*float64)
	closed, _ := today["closed_hours"].(int)
	out := make(map[string][]cockpitRank, len(ranks))
	for metric, ranks := range ranks {
		result := slices.Clone(ranks)
		for i := range result {
			row := &result[i]
			heat := row.Value
			row.Value = nil
			if area := areas[row.ID]; heat != nil && area > 0 {
				value := *heat / area
				if !math.IsInf(value, 0) && !math.IsNaN(value) {
					row.Value = &value
					row.Delta = cockpitSameHourDelta(current[metric][row.ID], previous[metric][row.ID], closed)
				}
			}
		}
		sortCockpitRanking(result)
		out[metric] = result
	}
	return out
}

func cockpitSameHourDelta(today, yesterday []*float64, closed int) *float64 {
	if closed <= 0 || len(today) < closed || len(yesterday) < closed {
		return nil
	}
	var a, b float64
	for i := 0; i < closed; i++ {
		if today[i] == nil || yesterday[i] == nil {
			return nil
		}
		a += *today[i]
		b += *yesterday[i]
	}
	if b == 0 {
		return nil
	}
	change := 100 * (a - b) / b
	if math.IsInf(change, 0) || math.IsNaN(change) {
		return nil
	}
	return &change
}

func sortCockpitRanking(ranking []cockpitRank) {
	slices.SortFunc(ranking, func(a, b cockpitRank) int {
		switch {
		case a.Value == nil && b.Value != nil:
			return 1
		case a.Value != nil && b.Value == nil:
			return -1
		case a.Value != nil && b.Value != nil && *a.Value > *b.Value:
			return -1
		case a.Value != nil && b.Value != nil && *a.Value < *b.Value:
			return 1
		}
		return strings.Compare(a.ID, b.ID)
	})
}

func cockpitNumber(text *string) *float64 {
	if text == nil {
		return nil
	}
	v, err := strconv.ParseFloat(*text, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return nil
	}
	return &v
}

func cockpitPowerTrends(ctx context.Context, db *sql.DB, zones []string, now time.Time) (map[string][]*float64, error) {
	out := map[string][]*float64{}
	if len(zones) == 0 {
		return out, nil
	}
	mappings, err := db.QueryContext(ctx, `SELECT s.StationCode,p.SampleColumn,p.Unit
FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId
WHERE s.IsEnabled=1 AND p.IsEnabled=1 AND p.PointCode='ER_SecondaryHeatRate'
 AND p.DeviceId IS NULL AND p.SampleTable='StationSample'
 AND s.StationCode IN (SELECT value FROM STRING_SPLIT(@stations,','))`,
		sql.Named("stations", strings.Join(zones, ",")))
	if err != nil {
		return nil, queryError(ctx)
	}
	factors := map[string]float64{}
	byColumn := map[string][]string{}
	for mappings.Next() {
		var zone, column string
		var unit sql.NullString
		if err := mappings.Scan(&zone, &column, &unit); err != nil || factors[zone] != 0 || !validColumn(column) {
			mappings.Close()
			return nil, queryError(ctx)
		}
		factor := map[string]float64{"gj/h": 1 / 3.6, "kw": 1.0 / 1000, "mw": 1}[strings.ToLower(strings.TrimSpace(unit.String))]
		if factor != 0 {
			factors[zone] = factor
			byColumn[column] = append(byColumn[column], zone)
			out[zone] = make([]*float64, 120)
		}
	}
	err = mappings.Err()
	mappings.Close()
	if err != nil {
		return nil, queryError(ctx)
	}
	start := now.UTC().Truncate(time.Minute).Add(-119 * time.Minute)
	for column, selected := range byColumn {
		query := "SELECT s.StationCode,sample.SampleTime,CONVERT(varchar(64),sample.[" + column + "])" +
			` FROM dbo.StationSample sample JOIN dbo.Station s ON s.StationId=sample.StationId
WHERE s.IsEnabled=1 AND s.StationCode IN (SELECT value FROM STRING_SPLIT(@stations,','))
 AND sample.SampleTime>=CONVERT(datetime2(3),@from) AND sample.SampleTime<CONVERT(datetime2(3),@to)
 AND sample.QualityCode IN (1,2) ORDER BY sample.SampleTime`
		rows, err := db.QueryContext(ctx, query, sql.Named("stations", strings.Join(selected, ",")),
			sql.Named("from", start), sql.Named("to", now.UTC()))
		if err != nil {
			return nil, queryError(ctx)
		}
		for rows.Next() {
			var zone string
			var at time.Time
			var raw sql.NullString
			if err := rows.Scan(&zone, &at, &raw); err != nil {
				rows.Close()
				return nil, queryError(ctx)
			}
			index := int(at.UTC().Sub(start).Minutes())
			if n := cockpitNumber(&raw.String); raw.Valid && n != nil && index >= 0 && index < len(out[zone]) {
				v := *n * factors[zone]
				out[zone][index] = &v
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, queryError(ctx)
		}
	}
	return out, nil
}

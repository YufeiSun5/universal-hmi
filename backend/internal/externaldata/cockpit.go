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

type CockpitHeatMeter struct {
	Station
	ConfirmArea bool `json:"confirm_area,omitempty"`
}

// Each code identifies the representative SQL row for one physical Zhongjieneng meter.
// The names follow the meter sources, including the meter carried by 国奥首站.
var cockpitHeatMeters = []CockpitHeatMeter{
	{Station: Station{"01-001", "中心站"}},
	{Station: Station{"01-003", "香港广场站"}},
	{Station: Station{"01-005", "华府怡景站"}},
	{Station: Station{"02-002", "北站"}, ConfirmArea: true},
	{Station: Station{"02-003", "国奥一二期站"}, ConfirmArea: true},
	{Station: Station{"03-001", "西站"}, ConfirmArea: true},
	{Station: Station{"04-001", "南站"}},
	{Station: Station{"04-003", "张屯"}},
}

func CockpitHeatSites() []CockpitHeatMeter {
	return slices.Clone(cockpitHeatMeters)
}

// CockpitEnergySites is the common water and electricity roster, including sites without samples.
func CockpitEnergySites() []Station {
	sites := make([]Station, 0, len(siteNames))
	for code, name := range siteNames {
		sites = append(sites, Station{Code: code, Name: name})
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
	if part == "today" {
		snapshot, err := s.cockpitToday(ctx, source, view, now.UTC())
		if err != nil {
			return nil, err
		}
		if !mayRead(ctx, view.ID) {
			return nil, authorizationDenied()
		}
		return snapshot.values, nil
	}
	local := now.In(beijing)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, beijing)
	if part == "usage_days" {
		return s.cockpitUsageDays(ctx, source, view, day, now.UTC())
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, release, err := s.database(ctx, source)
	if err != nil {
		return nil, err
	}
	defer release()
	switch part {
	case "yesterday":
		reportDay := day.AddDate(0, 0, -1)
		rows, err := cockpitStats(ctx, db, true, reportDay, now)
		if err != nil {
			return nil, err
		}
		return cockpitTotals(rows, reportDay, now, 24), nil
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

func (s *Service) cockpitUsageDays(ctx context.Context, source storedSource, view Screen, today, now time.Time) (map[string]any, error) {
	monthStart := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, beijing)
	weekStart := today.AddDate(0, 0, -6)
	from := max(min(monthStart.Format(time.DateOnly), weekStart.Format(time.DateOnly)), periodStart)
	to := today.AddDate(0, 0, -1).Format(time.DateOnly)
	var rows []Statistic
	if from <= to {
		result, err := s.queryStatistics(ctx, source, view, Request{Mode: "daily", From: from, To: to}, now)
		if err != nil {
			return nil, err
		}
		rows = result.Statistics
	}
	return cockpitUsageSeries(rows, monthStart, weekStart, today), nil
}

func cockpitUsageSeries(rows []Statistic, monthStart, weekStart, today time.Time) map[string]any {
	roster := map[string]map[string]bool{}
	for metric := range cockpitUsageUnits {
		roster[metric] = map[string]bool{}
		for _, station := range cockpitEnergyRoster(metric) {
			roster[metric][station.Code] = true
		}
	}
	type dailyUsage struct {
		total float64
		count int
	}
	totals := map[[2]string]dailyUsage{}
	for _, row := range rows {
		if !roster[row.Metric][row.Station] || row.Unit != cockpitUsageUnits[row.Metric] {
			continue
		}
		// DayUsage is the same business value already shown in energy management.
		if amount := cockpitNumber(row.DayUsage); amount != nil {
			key := [2]string{row.Date, row.Metric}
			total := totals[key]
			total.total += *amount
			total.count++
			totals[key] = total
		}
	}
	result := map[string]any{}
	for period, start := range map[string]time.Time{"month": monthStart, "week": weekStart} {
		series := map[string]any{}
		labels := make([]string, 0, 30)
		for day := start; day.Before(today); day = day.AddDate(0, 0, 1) {
			labels = append(labels, day.Format("01-02"))
		}
		partial := make(map[string][]bool, len(cockpitUsageUnits))
		for metric, stations := range roster {
			values := make([]*float64, len(labels))
			partial[metric] = make([]bool, len(labels))
			for i := range labels {
				date := start.AddDate(0, 0, i).Format(time.DateOnly)
				total := totals[[2]string{date, metric}]
				if total.count > 0 {
					values[i] = &total.total
					partial[metric][i] = total.count < len(stations)
				}
			}
			series[metric] = values
		}
		series["labels"], series["partial"] = labels, partial
		result[period] = series
	}
	return result
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
	seen := make(map[[3]string]bool, len(data))
	for _, row := range data {
		metric := energyMetric(row.Label)
		if metric == "" {
			continue
		}
		key := [3]string{row.Station, metric, *row.Hour}
		if seen[key] {
			return nil, fmt.Errorf("数据库返回重复统计记录，请核对配置")
		}
		seen[key] = true
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

func cockpitTotals(rows []Statistic, day, now time.Time, closed int) map[string]any {
	return projectCockpitTotals(rows, latestEnergyStatistics(rows), day, now, closed)
}

func projectCockpitTotals(hourlyRows []Statistic, daily map[string]map[string]Statistic, day, now time.Time, closed int) map[string]any {
	sites := CockpitEnergySites()
	hourly := map[string]map[string][]*float64{
		"heat":        make(map[string][]*float64, len(cockpitHeatMeters)),
		"electricity": {}, "water": {},
	}
	hours := hourly["heat"]
	for _, site := range cockpitHeatMeters {
		hours[site.Code] = make([]*float64, 24)
	}
	for _, r := range hourlyRows {
		metric := energyMetric(r.Label)
		if siteNames[r.Station] == "" || metric == "" || r.Hour == nil || (metric == "heat" && hours[r.Station] == nil) {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, *r.Hour)
		if err != nil {
			continue
		}
		h := t.In(beijing).Hour()
		if r.Unit == cockpitUsageUnits[metric] && h < closed {
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
	metricRanking := make(map[string][]cockpitRank, len(cockpitUsageUnits))
	for metric, unit := range cockpitUsageUnits {
		sum, count := 0.0, 0
		roster := cockpitEnergyRoster(metric)
		ranked := make([]cockpitRank, 0, len(roster))
		for _, site := range roster {
			row := daily[metric][site.Code]
			var amount *float64
			if row.Unit == unit {
				amount = cockpitNumber(row.DayUsage)
			}
			if amount != nil {
				sum += *amount
				count++
			}
			ranked = append(ranked, cockpitRank{ID: site.Code, Name: site.Name, Value: amount})
		}
		sortCockpitRanking(ranked)
		metricRanking[metric] = ranked
		metricCoverage[metric] = count
		switch {
		case count > 0 && count == len(roster):
			totals[metric] = &sum
		case count > 0:
			subtotals[metric] = &sum
		}
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
		case count == len(cockpitHeatMeters):
			network[h] = &sum
		case count > 0:
			partial[h] = &sum
		}
	}
	return map[string]any{"date": day.Format("2006-01-02"), "at": now.UTC(), "metrics": totals,
		"partial_metrics": subtotals, "metric_coverage": metricCoverage,
		"closed_hours": closed, "hours": network, "partial_hours": partial,
		"hour_coverage": coverage, "station_count": len(sites), "heat_station_count": len(cockpitHeatMeters),
		"station_hours": hours, "ranking": metricRanking["heat"],
		"metric_rankings": metricRanking, "metric_hours": hourly}
}

type CockpitAreas struct {
	Heat        map[string]float64 `json:"heat"`
	Electricity map[string]float64 `json:"electricity"`
	Water       map[string]float64 `json:"water"`
}

// LegacyCockpitAreas preserves the old denominator as a starting value where
// one site's area can be carried over to the meter's coverage.
func LegacyCockpitAreas(areas map[string]float64) CockpitAreas {
	heat := make(map[string]float64)
	electricity := make(map[string]float64)
	water := make(map[string]float64)
	for _, meter := range cockpitHeatMeters {
		if area, ok := areas[meter.Code]; ok && !meter.ConfirmArea {
			heat[meter.Code] = area
		}
	}
	for code, area := range areas {
		if siteNames[code] != "" {
			electricity[code], water[code] = area, area
		}
	}
	return CockpitAreas{Heat: heat, Electricity: electricity, Water: water}
}

// CockpitUnitRankings divides each metric by its configured area. Missing
// areas and incomplete same-hour windows retain their rows with empty readings.
func CockpitUnitRankings(today, yesterday map[string]any, areas CockpitAreas) map[string][]cockpitRank {
	ranks, _ := today["metric_rankings"].(map[string][]cockpitRank)
	current, _ := today["metric_hours"].(map[string]map[string][]*float64)
	previous, _ := yesterday["metric_hours"].(map[string]map[string][]*float64)
	closed, _ := today["closed_hours"].(int)
	out := make(map[string][]cockpitRank, len(ranks))
	byMetric := map[string]map[string]float64{"heat": areas.Heat, "electricity": areas.Electricity, "water": areas.Water}
	for metric, ranks := range ranks {
		result := slices.Clone(ranks)
		for i := range result {
			row := &result[i]
			usage := row.Value
			row.Value = nil
			if area := byMetric[metric][row.ID]; usage != nil && area > 0 {
				value := *usage / area
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

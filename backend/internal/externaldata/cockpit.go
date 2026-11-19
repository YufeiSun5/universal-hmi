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
		rows, err := cockpitStats(ctx, db, true, true, "", reportDay, now)
		if err != nil {
			return nil, err
		}
		return cockpitTotals(rows, reportDay, now, closed), nil
	case "week":
		week := map[string]any{}
		labels := []string{}
		metrics := map[string][]*float64{"heat": {}, "electricity": {}, "water": {}}
		partial := map[string][]bool{"heat": {}, "electricity": {}, "water": {}}
		for i := 6; i >= 1; i-- {
			date := day.AddDate(0, 0, -i)
			rows, err := cockpitStats(ctx, db, true, false, "", date, now)
			if err != nil {
				return nil, err
			}
			result := cockpitTotals(rows, date, now, 0)
			totals := result["metrics"].(map[string]*float64)
			subtotals := result["partial_metrics"].(map[string]*float64)
			for k := range metrics {
				amount := totals[k]
				if amount == nil {
					amount = subtotals[k]
				}
				metrics[k] = append(metrics[k], amount)
				partial[k] = append(partial[k], subtotals[k] != nil)
			}
			labels = append(labels, date.Format("01-02"))
		}
		week["labels"] = labels
		week["partial"] = partial
		for k, v := range metrics {
			week[k] = v
		}
		return week, nil
	case "zones":
		return cockpitZoneHeat(ctx, db, day, now)
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

func cockpitStats(ctx context.Context, db *sql.DB, whole, hourly bool, zones string, day, now time.Time) ([]Statistic, error) {
	var zoneList any
	if zones != "" {
		zoneList = zones
	}
	date := day.Format("2006-01-02")
	rows, err := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", zoneList),
		sql.Named("site", nil), sql.Named("whole", whole), sql.Named("date", date),
		sql.Named("hourly", hourly), sql.Named("asof", now.UTC()))
	if err != nil {
		return nil, statisticsError(ctx)
	}
	defer rows.Close()
	data, err := scanStatistics(rows, whole, date, now.In(beijing).Format("2006-01-02"))
	if err != nil {
		return nil, statisticsError(ctx)
	}
	return data, nil
}

type cockpitRank struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Value *float64 `json:"value"`
}

func cockpitTotals(rows []Statistic, day, now time.Time, closed int) map[string]any {
	latest := map[string]map[string]Statistic{}
	sites := map[string]string{}
	hours := map[string][]*float64{}
	for _, r := range rows {
		sites[r.Station] = r.Name
		metric := energyMetric(r.Label)
		if metric == "" || r.Hour == nil {
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
		if metric == "heat" && r.Unit == "GJ" {
			if hours[r.Station] == nil {
				hours[r.Station] = make([]*float64, 24)
			}
			status := value(r.HourStatus)
			if h < closed && (status == "有效" || status == "有效含异常" || strings.HasPrefix(status, "截至采样有效")) {
				hours[r.Station][h] = cockpitNumber(r.HourUsage)
			}
		}
	}
	totals := map[string]*float64{}
	subtotals := map[string]*float64{}
	metricCoverage := map[string]int{}
	ranking := make([]cockpitRank, 0, len(sites))
	for id, name := range sites {
		heat := latest["heat"][id]
		var v *float64
		if heat.Unit == "GJ" {
			v = cockpitNumber(heat.DayUsage)
		}
		ranking = append(ranking, cockpitRank{id, name, v})
	}
	for _, metric := range []string{"heat", "electricity", "water"} {
		sum, count := 0.0, 0
		unit := map[string]string{"heat": "GJ", "electricity": "kWh", "water": "t"}[metric]
		for _, r := range latest[metric] {
			n := cockpitNumber(r.DayUsage)
			if n == nil || r.Unit != unit {
				continue
			}
			if strings.HasPrefix(value(r.DayStatus), "截至采样有效") {
				sum += *n
				count++
			}
		}
		metricCoverage[metric] = count
		switch {
		case count > 0 && count == len(sites):
			totals[metric] = &sum
		case count > 0:
			subtotals[metric] = &sum
		}
	}
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
		case count > 0 && count == len(sites):
			network[h] = &sum
		case count > 0:
			partial[h] = &sum
		}
	}
	return map[string]any{"date": day.Format("2006-01-02"), "at": now.UTC(), "metrics": totals,
		"partial_metrics": subtotals, "metric_coverage": metricCoverage,
		"closed_hours": closed, "hours": network, "partial_hours": partial,
		"hour_coverage": coverage, "station_count": len(sites), "station_hours": hours, "ranking": ranking}
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

func cockpitZoneHeat(ctx context.Context, db *sql.DB, day, now time.Time) (map[string]any, error) {
	matches, err := db.QueryContext(ctx, `SELECT s.StationCode,s.StationName,w.输出列
FROM dbo.Station s LEFT JOIN dbo.Point p ON p.StationId=s.StationId AND p.IsEnabled=1 AND p.PointCode='ER_TotalHeat'
LEFT JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
WHERE s.IsEnabled=1 ORDER BY s.StationCode`)
	if err != nil {
		return nil, statisticsError(ctx)
	}
	type zoneHeat struct {
		Name   string     `json:"name"`
		Values []*float64 `json:"values"`
	}
	matrix := map[string]zoneHeat{}
	columns := map[string]string{}
	zones, mapped := []string{}, []string{}
	for matches.Next() {
		var id, name string
		var column sql.NullString
		if err = matches.Scan(&id, &name, &column); err != nil || matrix[id].Values != nil ||
			column.Valid && !validColumn(column.String) {
			matches.Close()
			return nil, statisticsError(ctx)
		}
		zones = append(zones, id)
		matrix[id] = zoneHeat{name, make([]*float64, 24)}
		if column.Valid {
			columns[id] = column.String
			mapped = append(mapped, id)
		}
	}
	err = matches.Err()
	matches.Close()
	if err != nil {
		return nil, statisticsError(ctx)
	}
	for batch := range slices.Chunk(mapped, 8) {
		rows, err := cockpitStats(ctx, db, false, true, strings.Join(batch, ","), day, now)
		if err != nil {
			return nil, err
		}
		for _, r := range rows {
			if r.Metric != columns[r.Station] || r.Unit != "GJ" || r.Hour == nil ||
				!strings.HasPrefix(value(r.HourStatus), "有效") {
				continue
			}
			t, err := time.Parse(time.RFC3339Nano, *r.Hour)
			if err == nil && t.In(beijing).Hour() < now.In(beijing).Hour() {
				matrix[r.Station].Values[t.In(beijing).Hour()] = cockpitNumber(r.HourUsage)
			}
		}
	}
	out := []zoneHeat{}
	for _, zone := range zones {
		if item, ok := matrix[zone]; ok {
			out = append(out, item)
		}
	}
	return map[string]any{"rows": out, "at": now.UTC()}, nil
}

func cockpitPowerTrends(ctx context.Context, db *sql.DB, zones []string, now time.Time) (map[string][]*float64, error) {
	out := map[string][]*float64{}
	if len(zones) == 0 {
		return out, nil
	}
	mappings, err := db.QueryContext(ctx, `SELECT s.StationCode,p.SampleColumn,p.Unit
FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId
WHERE s.IsEnabled=1 AND p.IsEnabled=1 AND p.PointCode='ER_MeterHeatRate'
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

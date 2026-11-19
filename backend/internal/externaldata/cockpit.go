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
	if view.Kind != "energy" || len(zones) > 4 {
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
		for i := 6; i >= 1; i-- {
			date := day.AddDate(0, 0, -i)
			rows, err := cockpitStats(ctx, db, true, false, "", date, now)
			if err != nil {
				return nil, err
			}
			totals := cockpitTotals(rows, date, now, 0)["metrics"].(map[string]*float64)
			for k := range metrics {
				metrics[k] = append(metrics[k], totals[k])
			}
			labels = append(labels, date.Format("01-02"))
		}
		week["labels"] = labels
		for k, v := range metrics {
			week[k] = v
		}
		return week, nil
	case "zones":
		if len(zones) == 0 {
			return map[string]any{"notice": "请在配置中绑定重点站的外部站区编码"}, nil
		}
		return cockpitZoneHeat(ctx, db, zones, day, now)
	case "trends":
		values := map[string][]*float64{}
		for _, zone := range zones {
			points, err := loadPoints(ctx, db, zone)
			if err != nil {
				return nil, err
			}
			for _, point := range points {
				if point.Code == "ER_MeterHeatRate" {
					v, err := cockpitPowerTrend(ctx, db, zone, point, now)
					if err != nil {
						return nil, err
					}
					values[zone] = v
				}
			}
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
	ID    string  `json:"id"`
	Name  string  `json:"name"`
	Value float64 `json:"value"`
}

func cockpitTotals(rows []Statistic, day, now time.Time, closed int) map[string]any {
	latest := map[string]map[string]Statistic{}
	sites := map[string]bool{}
	hours := map[string][]*float64{}
	for _, r := range rows {
		sites[r.Station] = true
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
			if h < closed && strings.HasPrefix(value(r.HourStatus), "截至采样有效") {
				hours[r.Station][h] = cockpitNumber(r.HourUsage)
			}
		}
	}
	totals := map[string]*float64{}
	ranking := []cockpitRank{}
	for _, metric := range []string{"heat", "electricity", "water"} {
		sum, count := 0.0, 0
		unit := map[string]string{"heat": "GJ", "electricity": "kWh", "water": "t"}[metric]
		for _, r := range latest[metric] {
			n := cockpitNumber(r.DayUsage)
			if n == nil || r.Unit != unit {
				continue
			}
			if metric == "heat" {
				ranking = append(ranking, cockpitRank{r.Station, r.Name, *n})
			}
			if strings.HasPrefix(value(r.DayStatus), "截至采样有效") {
				sum += *n
				count++
			}
		}
		if count > 0 && count == len(sites) {
			totals[metric] = &sum
		}
	}
	slices.SortFunc(ranking, func(a, b cockpitRank) int {
		if a.Value != b.Value {
			if a.Value > b.Value {
				return -1
			}
			return 1
		}
		return strings.Compare(a.ID, b.ID)
	})
	network := make([]*float64, 24)
	for h := 0; h < closed; h++ {
		sum, count := 0.0, 0
		for _, values := range hours {
			if values[h] != nil {
				sum += *values[h]
				count++
			}
		}
		if count > 0 && count == len(sites) {
			network[h] = &sum
		}
	}
	return map[string]any{"date": day.Format("2006-01-02"), "at": now.UTC(), "metrics": totals,
		"closed_hours": closed, "hours": network, "station_hours": hours, "ranking": ranking}
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

func cockpitZoneHeat(ctx context.Context, db *sql.DB, zones []string, day, now time.Time) (map[string]any, error) {
	zoneList := strings.Join(zones, ",")
	matches, err := db.QueryContext(ctx, `SELECT s.StationCode,s.StationName,w.输出列
FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId AND p.IsEnabled=1 AND p.PointCode='ER_TotalHeat'
JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
WHERE s.IsEnabled=1 AND s.StationCode IN (SELECT value FROM STRING_SPLIT(@stations,','))`, sql.Named("stations", zoneList))
	if err != nil {
		return nil, statisticsError(ctx)
	}
	type zoneHeat struct {
		Name   string     `json:"name"`
		Values []*float64 `json:"values"`
	}
	matrix := map[string]zoneHeat{}
	columns := map[string]string{}
	for matches.Next() {
		var id, name, column string
		if err = matches.Scan(&id, &name, &column); err != nil || columns[id] != "" || !validColumn(column) {
			matches.Close()
			return nil, statisticsError(ctx)
		}
		columns[id] = column
		matrix[id] = zoneHeat{name, make([]*float64, 24)}
	}
	err = matches.Err()
	matches.Close()
	if err != nil {
		return nil, statisticsError(ctx)
	}
	rows, err := cockpitStats(ctx, db, false, true, zoneList, day, now)
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
	out := []zoneHeat{}
	for _, zone := range zones {
		if item, ok := matrix[zone]; ok {
			out = append(out, item)
		}
	}
	return map[string]any{"rows": out, "at": now.UTC()}, nil
}

func cockpitPowerTrend(ctx context.Context, db *sql.DB, zone string, point Point, now time.Time) ([]*float64, error) {
	if !validColumn(point.Column) {
		return nil, statisticsError(ctx)
	}
	factor := 1.0
	switch strings.ToLower(point.Unit) {
	case "gj/h":
		factor = 1 / 3.6
	case "kw":
		factor = 1.0 / 1000
	case "mw":
	default:
		return nil, nil
	}
	start := now.UTC().Truncate(time.Minute).Add(-119 * time.Minute)
	query := "SELECT sample.SampleTime,CONVERT(varchar(64),sample.[" + point.Column + "])" + sampleRangeSQL +
		" AND sample.QualityCode IN (1,2) ORDER BY sample.SampleTime"
	rows, err := db.QueryContext(ctx, query, sql.Named("station", zone), sql.Named("from", start), sql.Named("to", now.UTC()))
	if err != nil {
		return nil, queryError(ctx)
	}
	defer rows.Close()
	out := make([]*float64, 120)
	for rows.Next() {
		var at time.Time
		var raw sql.NullString
		if err := rows.Scan(&at, &raw); err != nil {
			return nil, queryError(ctx)
		}
		index := int(at.UTC().Sub(start).Minutes())
		if n := cockpitNumber(&raw.String); raw.Valid && n != nil && index >= 0 && index < len(out) {
			v := *n * factor
			out[index] = &v
		}
	}
	return out, rows.Err()
}

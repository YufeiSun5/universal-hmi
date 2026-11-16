package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"slices"
	"sort"
	"strings"
	"time"
)

// These are the existing KIO point identities, never display-name matches or
// fixed ValueNN positions. The same hourly procedure remains the authority.
var keyTrendPoints = []struct{ Code, Label, Group string }{
	{"ER_TotalHeat", "一次网热量用量", "heat"},
	{"ER_SecondaryTotalHeat", "二次网热量用量", "heat"},
	{"ER_SupplyTemp", "二次网供水温度", "temperature"},
	{"ER_ReturnTemp", "二次网回水温度", "temperature"},
	{"ER_SupplyPressure", "二次网供水压力", "pressure"},
	{"ER_ReturnPressure", "二次网回水压力", "pressure"},
}

type KeyTrendSample struct {
	Time   string  `json:"time"`
	Value  *string `json:"value"`
	Low    *string `json:"low"`
	High   *string `json:"high"`
	Status string  `json:"status"`
}
type KeyTrendSeries struct {
	Station string           `json:"station"`
	Name    string           `json:"name"`
	Point   string           `json:"point"`
	Label   string           `json:"label"`
	Group   string           `json:"group"`
	Unit    string           `json:"unit"`
	Samples []KeyTrendSample `json:"samples"`
}
type KeyTrendsResult struct {
	From    string           `json:"from"`
	To      string           `json:"to"`
	Series  []KeyTrendSeries `json:"series"`
	Missing []string         `json:"missing"`
}

const keyTrendMappingSQL = `SELECT s.StationCode,s.StationName,p.PointCode,p.Unit,w.输出列
FROM dbo.Station s
LEFT JOIN dbo.Point p ON p.StationId=s.StationId AND p.IsEnabled=1
 AND p.PointCode IN ('ER_TotalHeat','ER_SecondaryTotalHeat','ER_SupplyTemp','ER_ReturnTemp','ER_SupplyPressure','ER_ReturnPressure')
LEFT JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
WHERE s.IsEnabled=1 AND s.StationCode IN (SELECT value FROM STRING_SPLIT(@stations,','))
ORDER BY s.StationCode,p.PointCode`

func keyTrendBounds(in Request, now time.Time) (time.Time, time.Time, error) {
	if len(in.Stations) == 0 || len(in.Stations) > 256 || in.Offset != 0 {
		return time.Time{}, time.Time{}, fmt.Errorf("请选择站区，最多256个")
	}
	seen := map[string]bool{}
	for _, code := range in.Stations {
		if code == "" || len(code) > 32 || strings.TrimSpace(code) != code || strings.ContainsAny(code, ",\r\n\t") || seen[code] {
			return time.Time{}, time.Time{}, fmt.Errorf("站区选择无效或重复")
		}
		seen[code] = true
	}
	if in.From == "" && in.To == "" {
		in.From = now.In(beijing).Format("2006-01-02")
		in.To = in.From
	}
	a, b, _, err := statisticsBounds("daily", Request{Station: in.Stations[0], From: in.From, To: in.To}, now)
	if err != nil {
		return a, b, fmt.Errorf("请选择2026-11-04至今天的日期区间，最多31天")
	}
	return a, b, nil
}

func canonicalTrendUnit(unit string) string {
	switch strings.TrimSpace(unit) {
	case "°C", "℃":
		return "℃"
	default:
		return strings.TrimSpace(unit)
	}
}

func (s *Service) queryKeyTrends(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	now := time.Now().UTC()
	from, to, err := keyTrendBounds(in, now)
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
	mapping, err := db.QueryContext(ctx, keyTrendMappingSQL, sql.Named("stations", strings.Join(in.Stations, ",")))
	if err != nil {
		return Result{}, statisticsError(ctx)
	}
	result := &KeyTrendsResult{From: from.Format("2006-01-02"), To: to.Format("2006-01-02"), Series: []KeyTrendSeries{}, Missing: []string{}}
	stationNames := map[string]string{}
	type binding struct{ unit, column string }
	bindings := map[string]binding{}
	for mapping.Next() {
		var station, name string
		var code, unit, column sql.NullString
		if err = mapping.Scan(&station, &name, &code, &unit, &column); err != nil {
			mapping.Close()
			return Result{}, statisticsError(ctx)
		}
		if !slices.Contains(in.Stations, station) {
			mapping.Close()
			return Result{}, fmt.Errorf("数据库返回了未选择的站区")
		}
		stationNames[station] = name
		if !code.Valid {
			continue
		}
		if !slices.ContainsFunc(keyTrendPoints, func(p struct{ Code, Label, Group string }) bool { return p.Code == code.String }) {
			mapping.Close()
			return Result{}, fmt.Errorf("重点测点映射无效")
		}
		key := station + "/" + code.String
		if _, exists := bindings[key]; exists {
			mapping.Close()
			return Result{}, fmt.Errorf("重点测点统计映射重复，请核对数据库配置")
		}
		if column.Valid && !validColumn(column.String) {
			mapping.Close()
			return Result{}, fmt.Errorf("重点测点统计输出列无效")
		}
		bindings[key] = binding{canonicalTrendUnit(unit.String), column.String}
	}
	err = mapping.Err()
	mapping.Close()
	if err != nil {
		return Result{}, statisticsError(ctx)
	}
	indices := map[string]int{}
	units := map[string]string{}
	for _, station := range in.Stations {
		name, exists := stationNames[station]
		if !exists {
			return Result{}, fmt.Errorf("站区已停用或不存在，请刷新站区列表")
		}
		for _, point := range keyTrendPoints {
			b, ok := bindings[station+"/"+point.Code]
			if !ok || b.column == "" {
				result.Missing = append(result.Missing, name+" · "+point.Label)
				continue
			}
			if b.unit == "" {
				return Result{}, fmt.Errorf("%s的%s缺少单位，请维护测点单位", name, point.Label)
			}
			if u := units[point.Group]; u != "" && u != b.unit {
				return Result{}, fmt.Errorf("%s存在不同单位（%s、%s），不能在同一坐标轴比较", point.Label, u, b.unit)
			}
			units[point.Group] = b.unit
			key := station + "/" + b.column
			if _, exists := indices[key]; exists {
				return Result{}, fmt.Errorf("重点测点复用了同一统计列，请核对数据库配置")
			}
			indices[key] = len(result.Series)
			result.Series = append(result.Series, KeyTrendSeries{Station: station, Name: name, Point: point.Code, Label: point.Label, Group: point.Group, Unit: b.unit, Samples: []KeyTrendSample{}})
		}
	}
	seen := map[string]bool{}
	count := 0
	// Bound each procedure result below scanStatistics' row budget. All selected
	// stations are included; all-select never silently truncates the selection.
	for day := from; !day.After(to); day = day.AddDate(0, 0, 1) {
		for i := 0; i < len(in.Stations); i += 8 {
			chunk := in.Stations[i:min(i+8, len(in.Stations))]
			rows, e := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", strings.Join(chunk, ",")), sql.Named("site", nil), sql.Named("whole", false), sql.Named("date", day.Format("2006-01-02")), sql.Named("hourly", true), sql.Named("asof", now))
			if e != nil {
				return Result{}, statisticsError(ctx)
			}
			batch, e := scanStatistics(rows, false, day.Format("2006-01-02"), now.In(beijing).Format("2006-01-02"))
			rows.Close()
			if e != nil {
				return Result{}, statisticsError(ctx)
			}
			for _, r := range batch {
				if !slices.Contains(chunk, r.Station) {
					return Result{}, fmt.Errorf("小时报返回了未选择的站区")
				}
				index, ok := indices[r.Station+"/"+r.Metric]
				if !ok {
					continue
				}
				series := &result.Series[index]
				if canonicalTrendUnit(r.Unit) != series.Unit {
					return Result{}, fmt.Errorf("查询期间测点单位已变化，请重新查询")
				}
				stamp, e := time.Parse(time.RFC3339Nano, value(r.Hour))
				if e != nil {
					return Result{}, statisticsError(ctx)
				}
				stamp = stamp.In(beijing)
				if stamp.Format("2006-01-02") != day.Format("2006-01-02") || stamp.Minute() != 0 || stamp.Second() != 0 || stamp.Nanosecond() != 0 {
					return Result{}, fmt.Errorf("小时报统计时刻不是北京时间整点，请核对数据")
				}
				key := r.Station + "/" + r.Metric + "/" + stamp.Format(time.RFC3339Nano)
				if seen[key] {
					return Result{}, fmt.Errorf("小时报返回重复统计时段，请核对数据库配置")
				}
				seen[key] = true
				sample := KeyTrendSample{Time: stamp.Format(time.RFC3339Nano), Status: value(r.HourStatus)}
				if series.Group == "heat" {
					sample.Value = r.HourUsage
				} else {
					sample.Low = r.HourMin
					sample.High = r.HourMax
				}
				for _, v := range []*string{sample.Value, sample.Low, sample.High} {
					if v != nil {
						if _, ok := new(big.Rat).SetString(*v); !ok {
							return Result{}, fmt.Errorf("小时报数值无效")
						}
					}
				}
				if sample.Low != nil && sample.High != nil {
					a, _ := new(big.Rat).SetString(*sample.Low)
					b, _ := new(big.Rat).SetString(*sample.High)
					if a.Cmp(b) > 0 {
						return Result{}, fmt.Errorf("小时报最小值大于最大值，请核对统计数据")
					}
				}
				series.Samples = append(series.Samples, sample)
				count++
				if count > 200000 {
					return Result{}, fmt.Errorf("曲线数据过多，请缩短日期区间或减少站区")
				}
			}
		}
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	for i := range result.Series {
		sort.Slice(result.Series[i].Samples, func(a, b int) bool { return result.Series[i].Samples[a].Time < result.Series[i].Samples[b].Time })
	}
	return Result{KeyTrends: result, SourceRevision: source.Revision, ScreenRevision: view.Revision, UTCOffsetMinutes: 480}, nil
}

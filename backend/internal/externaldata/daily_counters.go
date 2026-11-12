package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// CounterBinding is an explicit raw station/point identity, not a display name
// or a daily-consumption metric. One shared meter is bound only once by caller.
type CounterBinding struct {
	Station string
	Point   string
	Unit    string
}
type CounterReading struct {
	Station    string  `json:"station"`
	Point      string  `json:"point"`
	Date       string  `json:"date"`
	TargetTime string  `json:"target_time"`
	SampleTime *string `json:"sample_time"`
	Quality    *int64  `json:"quality"`
	Value      *string `json:"value"`
}

// DailyCounters reads the nearest raw reading within ±30 minutes of 00:00
// Beijing time, including earlier samples on the first requested day. It does
// not use the interval procedure's much wider half-day window at 1440 minutes.
// No external schema, stored procedure or historical row is modified.
func (s *Service) DailyCounters(ctx context.Context, id, fromText, toText string, bindings []CounterBinding) ([]CounterReading, error) {
	source, view, e := s.source(ctx, id, true)
	if e != nil {
		return nil, e
	}
	if view.Kind != "standard" {
		return nil, fmt.Errorf("请选择标准历史画面作为累计表底来源")
	}
	zone := time.FixedZone("Beijing", 8*3600)
	from, e := time.ParseInLocation("2006-01-02", fromText, zone)
	if e != nil {
		return nil, fmt.Errorf("开始日期无效")
	}
	to, e := time.ParseInLocation("2006-01-02", toText, zone)
	if e != nil || from.Year() < 2000 || to.Year() > 2100 || to.Before(from) || to.Sub(from) > 184*24*time.Hour || len(bindings) == 0 || len(bindings) > 32 {
		return nil, fmt.Errorf("累计表底查询最多185天、32个测点")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, source)
	if e != nil {
		return nil, e
	}
	defer close()
	out := []CounterReading{}
	seen := map[string]bool{}
	for _, binding := range bindings {
		if binding.Station == "" || len(binding.Station) > 32 || binding.Point == "" || len(binding.Point) > 128 || binding.Unit == "" || seen[binding.Station+"/"+binding.Point] {
			return nil, fmt.Errorf("重复或无效的累计点绑定")
		}
		seen[binding.Station+"/"+binding.Point] = true
		points, e := loadPoints(ctx, db, binding.Station)
		if e != nil {
			return nil, queryError(ctx)
		}
		column := ""
		for _, p := range points {
			if p.Code == binding.Point {
				if p.Unit != binding.Unit {
					return nil, fmt.Errorf("%s/%s单位改变，须核对绑定", binding.Station, binding.Point)
				}
				column = p.Column
			}
		}
		if !validColumn(column) {
			return nil, fmt.Errorf("%s/%s未找到有效采样字段", binding.Station, binding.Point)
		}
		// Identifier comes only from validated Point metadata. All inputs are bound.
		query := `WITH days(t) AS (SELECT CONVERT(datetime2(3),@from) UNION ALL SELECT DATEADD(day,1,t) FROM days WHERE t<CONVERT(datetime2(3),@to))
 SELECT d.t,r.SampleTime,r.QualityCode,CONVERT(varchar(64),r.[` + column + `])
 FROM days d OUTER APPLY(SELECT TOP(1) h.SampleTime,h.QualityCode,h.[` + column + `] FROM dbo.StationSample h JOIN dbo.Station st ON st.StationId=h.StationId
 WHERE st.StationCode=@station AND st.IsEnabled=1 AND h.SampleTime>=DATEADD(minute,-30,d.t) AND h.SampleTime<=DATEADD(minute,30,d.t)
 ORDER BY ABS(DATEDIFF_BIG(millisecond,d.t,h.SampleTime)),h.SampleTime) r ORDER BY d.t OPTION(MAXRECURSION 185)`
		start := from.UTC()
		end := to.UTC()
		rows, e := db.QueryContext(ctx, query, sql.Named("from", start), sql.Named("to", end), sql.Named("station", binding.Station))
		if e != nil {
			return nil, interfaceFailure(ctx, "总统计表底", "", e)
		}
		count := 0
		for rows.Next() {
			var target time.Time
			var sample sql.NullTime
			var quality sql.NullInt64
			var value sql.NullString
			if e = rows.Scan(&target, &sample, &quality, &value); e != nil {
				rows.Close()
				return nil, interfaceFailure(ctx, "总统计表底", "读取", e)
			}
			expected := start.AddDate(0, 0, count)
			if !target.Equal(expected) {
				rows.Close()
				return nil, fmt.Errorf("表底目标时间不完整")
			}
			count++
			reading := CounterReading{Station: binding.Station, Point: binding.Point, Date: target.In(zone).Format("2006-01-02"), TargetTime: target.In(zone).Format(time.RFC3339)}
			if sample.Valid {
				if sample.Time.Before(target.Add(-30*time.Minute)) || sample.Time.After(target.Add(30*time.Minute)) {
					rows.Close()
					return nil, fmt.Errorf("表底采样超出00:00前后30分钟")
				}
				stamp := sample.Time.In(zone).Format(time.RFC3339Nano)
				reading.SampleTime = &stamp
			}
			if quality.Valid {
				q := quality.Int64
				reading.Quality = &q
			}
			if sample.Valid && quality.Valid && (quality.Int64 == 1 || quality.Int64 == 2) && value.Valid && strings.TrimSpace(value.String) != "" {
				v := value.String
				reading.Value = &v
			}
			out = append(out, reading)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return nil, interfaceFailure(ctx, "总统计表底", "读取", e)
		}
		if count != int(to.Sub(from)/(24*time.Hour))+1 {
			return nil, fmt.Errorf("表底日期不完整")
		}
	}
	if !mayRead(ctx, id) {
		return nil, authorizationDenied()
	}
	return out, nil
}

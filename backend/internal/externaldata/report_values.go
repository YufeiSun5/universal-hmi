package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// ReportValueRequest is a bounded, read-only contract for spreadsheet bindings.
// Targets are explicit business instants, not UI cell addresses or SQL fragments.
type ReportValueRequest struct {
	Screen        string         `json:"screen"`
	Station       string         `json:"station"`
	Point         string         `json:"point"`
	Unit          string         `json:"unit"`
	Mode          string         `json:"mode"`
	WindowMinutes int            `json:"window_minutes"`
	Targets       []ReportTarget `json:"targets"`
}
type ReportTarget struct {
	From string `json:"from"`
	To   string `json:"to"`
}
type ReportValue struct {
	Target     string  `json:"target"`
	Value      *string `json:"value"`
	SampleTime *string `json:"sample_time,omitempty"`
	Quality    *int64  `json:"quality,omitempty"`
}

func (s *Service) ReportPoints(ctx context.Context, id, station string) ([]Point, error) {
	v, view, e := s.source(ctx, id, true)
	if e != nil {
		return nil, e
	}
	if view.Kind != "standard" && view.Kind != "daily" {
		return nil, fmt.Errorf("请选择原始历史或日结算数据源")
	}
	if station == "" || len(station) > 32 {
		return nil, fmt.Errorf("请选择站区")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, v)
	if e != nil {
		return nil, e
	}
	defer close()
	points, e := loadPoints(ctx, db, station)
	if e != nil {
		return nil, queryError(ctx)
	}
	if !mayRead(ctx, id) {
		return nil, authorizationDenied()
	}
	return points, nil
}

func (s *Service) ReportValues(ctx context.Context, in ReportValueRequest) ([]ReportValue, error) {
	v, view, e := s.source(ctx, in.Screen, true)
	if e != nil {
		return nil, e
	}
	if len(in.Targets) == 0 || len(in.Targets) > 366 || in.Station == "" || len(in.Station) > 32 || in.Point == "" || len(in.Point) > 128 || len(in.Unit) > 32 || in.WindowMinutes < 0 || in.WindowMinutes > 180 {
		return nil, fmt.Errorf("历史绑定参数无效（每批最多366格，容差0至180分钟）")
	}
	from, to := make([]time.Time, len(in.Targets)), make([]time.Time, len(in.Targets))
	for i, t := range in.Targets {
		from[i], e = time.Parse(time.RFC3339, t.From)
		if e != nil {
			return nil, fmt.Errorf("历史目标时间无效")
		}
		to[i], e = time.Parse(time.RFC3339, t.To)
		if e != nil || to[i].Before(from[i]) || to[i].Sub(from[i]) > 31*24*time.Hour || from[i].Year() < 2000 || to[i].Year() > 2101 {
			return nil, fmt.Errorf("每格区间须在0至31天之间")
		}
	}
	if in.Mode == "daily_usage" || in.Mode == "daily_subtotal" {
		if view.Kind != "daily" {
			return nil, fmt.Errorf("已结算日值必须选择日报来源，不能由原始表底替代")
		}
		return s.reportDailyValues(ctx, in, from, to)
	}
	if view.Kind != "standard" {
		return nil, fmt.Errorf("原始值与区间统计必须选择原始历史来源")
	}
	if in.Mode != "nearest" && in.Mode != "latest" && in.Mode != "min" && in.Mode != "max" && in.Mode != "average" {
		return nil, fmt.Errorf("不支持的历史取值方式")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, v)
	if e != nil {
		return nil, e
	}
	defer close()
	points, e := loadPoints(ctx, db, in.Station)
	if e != nil {
		return nil, queryError(ctx)
	}
	column := ""
	for _, p := range points {
		if p.Code == in.Point {
			if p.Unit != in.Unit {
				return nil, fmt.Errorf("测点单位与绑定不一致")
			}
			column = p.Column
		}
	}
	if !validColumn(column) {
		return nil, fmt.Errorf("绑定测点不存在或已停用")
	}
	args := []any{sql.Named("station", in.Station), sql.Named("window", in.WindowMinutes)}
	values := []string{}
	for i := range from {
		values = append(values, fmt.Sprintf("(%d,CAST(@t%d AS datetime2(3)),CAST(@e%d AS datetime2(3)))", i, i, i))
		args = append(args, sql.Named(fmt.Sprintf("t%d", i), from[i].UTC()), sql.Named(fmt.Sprintf("e%d", i), to[i].UTC()))
	}
	base := `WITH targets(i,t,e) AS (SELECT * FROM (VALUES ` + strings.Join(values, ",") + `) v(i,t,e)) `
	q := base + `SELECT d.i,r.SampleTime,r.QualityCode,CONVERT(varchar(64),r.value) FROM targets d OUTER APPLY (SELECT TOP(1) h.SampleTime,h.QualityCode,h.[` + column + `] AS value FROM dbo.StationSample h JOIN dbo.Station st ON st.StationId=h.StationId WHERE st.StationCode=@station AND st.IsEnabled=1 AND h.SampleTime>=DATEADD(minute,-@window,d.t) AND h.SampleTime<=DATEADD(minute,@window,d.t) ORDER BY ABS(DATEDIFF_BIG(millisecond,d.t,h.SampleTime)),h.SampleTime) r ORDER BY d.i`
	if in.Mode == "latest" {
		q = base + `SELECT d.i,r.SampleTime,r.QualityCode,CONVERT(varchar(64),r.value) FROM targets d OUTER APPLY (SELECT TOP(1) h.SampleTime,h.QualityCode,h.[` + column + `] AS value FROM dbo.StationSample h JOIN dbo.Station st ON st.StationId=h.StationId WHERE st.StationCode=@station AND st.IsEnabled=1 AND h.SampleTime>=d.t AND h.SampleTime<=d.e ORDER BY h.SampleTime DESC) r ORDER BY d.i`
	} else if in.Mode != "nearest" {
		aggregate := map[string]string{"min": "MIN", "max": "MAX", "average": "AVG"}[in.Mode]
		q = base + `SELECT d.i,NULL,NULL,CONVERT(varchar(64),` + aggregate + `(CAST(h.[` + column + `] AS decimal(28,8)))) FROM targets d LEFT JOIN (dbo.StationSample h JOIN dbo.Station st ON st.StationId=h.StationId AND st.StationCode=@station AND st.IsEnabled=1) ON h.SampleTime>=d.t AND h.SampleTime<d.e AND h.QualityCode IN (1,2) GROUP BY d.i ORDER BY d.i`
		for i := range from {
			if !to[i].After(from[i]) {
				return nil, fmt.Errorf("区间统计的结束时间须晚于开始时间")
			}
		}
	}
	rows, e := db.QueryContext(ctx, q, args...)
	if e != nil {
		return nil, interfaceFailure(ctx, "报表历史绑定", "", e)
	}
	defer rows.Close()
	out := []ReportValue{}
	for rows.Next() {
		var i int
		var stamp sql.NullTime
		var quality sql.NullInt64
		var value sql.NullString
		if e = rows.Scan(&i, &stamp, &quality, &value); e != nil {
			return nil, queryError(ctx)
		}
		if i != len(out) || i >= len(from) {
			return nil, fmt.Errorf("历史结果顺序不完整")
		}
		r := ReportValue{Target: in.Targets[i].From}
		if stamp.Valid {
			x := stamp.Time.In(beijing).Format(time.RFC3339Nano)
			r.SampleTime = &x
		}
		if quality.Valid {
			x := quality.Int64
			r.Quality = &x
		}
		if value.Valid && ((in.Mode != "nearest" && in.Mode != "latest") || stamp.Valid && quality.Valid && (quality.Int64 == 1 || quality.Int64 == 2)) {
			x := value.String
			r.Value = &x
		}
		out = append(out, r)
	}
	if e = rows.Err(); e != nil {
		return nil, queryError(ctx)
	}
	if len(out) != len(from) {
		return nil, fmt.Errorf("历史结果数量不完整")
	}
	if !mayRead(ctx, in.Screen) {
		return nil, authorizationDenied()
	}
	return out, nil
}

func (s *Service) reportDailyValues(ctx context.Context, in ReportValueRequest, from, to []time.Time) ([]ReportValue, error) {
	first, last := from[0], from[0]
	for i, t := range from {
		local := t.In(beijing)
		if local.Hour() != 0 || local.Minute() != 0 || local.Second() != 0 || to[i].Sub(t) != 24*time.Hour {
			return nil, fmt.Errorf("已结算日值只支持北京时间完整自然日")
		}
		if t.Before(first) {
			first = t
		}
		if t.After(last) {
			last = t
		}
	}
	if last.Sub(first) > 365*24*time.Hour {
		return nil, fmt.Errorf("日结算查询最多366天")
	}
	values := map[string]*string{}
	for start := first; !start.After(last); start = start.AddDate(0, 0, 31) {
		end := start.AddDate(0, 0, 30)
		if end.After(last) {
			end = last
		}
		result, e := s.Query(ctx, in.Screen, Request{Station: in.Station, From: start.In(beijing).Format("2006-01-02"), To: end.In(beijing).Format("2006-01-02"), Mode: "daily"})
		if e != nil {
			return nil, e
		}
		for _, r := range result.Statistics {
			if r.Metric != in.Point {
				continue
			}
			if r.Unit != in.Unit {
				return nil, fmt.Errorf("日结算单位与绑定不一致")
			}
			if _, ok := values[r.Date]; ok {
				return nil, fmt.Errorf("日结算结果重复")
			}
			if in.Mode == "daily_usage" {
				values[r.Date] = r.DayUsage
			} else {
				values[r.Date] = r.DaySubtotal
			}
		}
	}
	out := make([]ReportValue, len(from))
	for i, t := range from {
		out[i] = ReportValue{Target: in.Targets[i].From, Value: values[t.In(beijing).Format("2006-01-02")]}
	}
	return out, nil
}

package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"regexp"
	"slices"
	"sort"
	"time"
)

const slidingProcedure = `EXEC dbo.usp_气温水电热滑动对比 @本期开始时间=@from,@历史开始时间=@historyFrom,@本期结束时间=@to,@历史结束时间=@historyTo,@整站编码=@station,@返回类型=@kind,@水换算系数=@water,@电换算系数=@electricity,@热换算系数=@heat`
const beijingClock = "2006-01-02T15:04:05.000"

var positiveFactor = regexp.MustCompile(`^(?:0|[1-9][0-9]{0,7})(?:\.[0-9]{1,10})?$`)
var slidingDetailFields = []string{"序号", "整站编码", "指标", "单位", "本期开始", "本期结束", "历史开始", "历史结束", "片段秒数", "本期用量", "本期状态", "本期成员最早截止", "本期成员最晚截止", "历史原值", "历史折算用量", "历史换算系数", "历史状态", "历史取数说明", "用量可比", "用量差值", "用量变化百分比", "本期平均气温", "历史整点气温", "气温可比", "本期气温来源站区", "本期气温口径", "历史气温口径"}
var slidingSummaryFields = []string{"整站编码", "指标", "单位", "选择片段数", "选择秒数", "本期有效秒数", "历史有效秒数", "本期有效用量小计", "历史有效用量小计", "本期气温有效秒数", "历史气温有效秒数", "本期有效时段平均气温", "历史有效时段平均气温", "用量可比片段数", "用量可比秒数", "本期配对用量", "历史配对用量", "气温可比秒数", "本期配对平均气温", "历史配对平均气温", "气温用量共同可比秒数", "本期用量配对段平均气温", "历史用量配对段平均气温", "本期开始时间", "本期结束时间", "历史开始时间", "历史结束时间", "用量差值", "用量变化百分比", "用量状态", "气温状态", "本期气温来源站区", "历史气温序列", "气温说明"}

// API timestamps carry an explicit offset. SQL datetime2 receives Beijing wall
// time, regardless of either the server's or the browser's local time zone.
func slidingTime(raw string) (time.Time, error) {
	t, e := time.Parse(time.RFC3339Nano, raw)
	if e != nil {
		return t, fmt.Errorf("请选择北京时间日期和时间（UTC+8）")
	}
	if t.Nanosecond()%1000000 != 0 {
		return t, fmt.Errorf("时间精度最多为毫秒")
	}
	return t.In(beijing), nil
}
func slidingBounds(in Request, now time.Time) (Request, error) {
	bad := func() (Request, error) {
		return in, fmt.Errorf("本期从2026-11-04开始且不能晚于现在；窗口须正向、等长、最多366天，历史须在本期前结束，两侧起点分钟和秒须相同")
	}
	a, e := slidingTime(in.From)
	if e != nil {
		return in, e
	}
	h, e := slidingTime(in.HistoryFrom)
	if e != nil {
		return in, e
	}
	b := now.In(beijing).Truncate(time.Millisecond)
	if in.To != "" {
		b, e = slidingTime(in.To)
		if e != nil {
			return in, e
		}
	}
	j := h.Add(b.Sub(a))
	if in.HistoryTo != "" {
		j, e = slidingTime(in.HistoryTo)
		if e != nil {
			return in, e
		}
	}
	if a.Format("2006-01-02") < periodStart || h.Year() < 2000 || !b.After(a) || b.After(now) || j.After(a) || b.Sub(a) != j.Sub(h) || b.Sub(a) > 366*24*time.Hour || a.Sub(h)%time.Hour != 0 {
		return bad()
	}
	if in.Offset != 0 || (in.Station != "" && !siteCode.MatchString(in.Station)) || !slices.Contains([]string{"汇总", "明细"}, in.ComparisonType) || (in.ComparisonType == "明细" && in.Station == "") {
		return in, fmt.Errorf("请选择有效整站及汇总或明细结果；曲线明细须选择一个整站")
	}
	if in.IncludeDetails && (in.Station == "" || in.ComparisonType != "汇总") {
		return in, fmt.Errorf("合并汇总与曲线查询须选择一个整站")
	}
	for _, p := range []*string{&in.WaterFactor, &in.ElectricityFactor, &in.HeatFactor} {
		if *p == "" {
			*p = "1"
		}
		n, ok := new(big.Rat).SetString(*p)
		if !positiveFactor.MatchString(*p) || !ok || n.Sign() <= 0 {
			return in, fmt.Errorf("水、电、热换算系数须为有效正数")
		}
	}
	in.From = a.Format(time.RFC3339Nano)
	in.To = b.Format(time.RFC3339Nano)
	in.HistoryFrom = h.Format(time.RFC3339Nano)
	in.HistoryTo = j.Format(time.RFC3339Nano)
	return in, nil
}
func (s *Service) querySlidingComparison(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	untilNow := in.To == ""
	original := in
	in, e := slidingBounds(in, time.Now())
	if e != nil {
		return Result{}, e
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, source)
	if e != nil {
		return Result{}, e
	}
	defer close()
	if untilNow {
		// The procedure rejects future endpoints using the SQL Server clock.
		// Freeze this request from that same clock, not the application host's.
		var databaseNow time.Time
		if err := db.QueryRowContext(ctx, "SELECT SYSUTCDATETIME()").Scan(&databaseNow); err != nil {
			return Result{}, interfaceFailure(ctx, "气温水电热对比", "读取数据库时间", err)
		}
		in, e = slidingBounds(original, databaseNow)
		if e != nil {
			return Result{}, e
		}
	}
	wall := func(raw string) string { t, _ := slidingTime(raw); return t.Format(beijingClock) }
	var station any
	if in.Station != "" {
		station = in.Station
	}
	kind := in.ComparisonType
	if in.IncludeDetails {
		kind = "全部"
	}
	rows, e := db.QueryContext(ctx, slidingProcedure, sql.Named("from", wall(in.From)), sql.Named("historyFrom", wall(in.HistoryFrom)), sql.Named("to", wall(in.To)), sql.Named("historyTo", wall(in.HistoryTo)), sql.Named("station", station), sql.Named("kind", kind), sql.Named("water", in.WaterFactor), sql.Named("electricity", in.ElectricityFactor), sql.Named("heat", in.HeatFactor))
	if e != nil {
		return Result{}, interfaceFailure(ctx, "气温水电热对比", "执行存储过程", e)
	}
	defer rows.Close()
	var detail []map[string]*string
	if in.IncludeDetails {
		detail, e = scanInterfaceSet(rows, slidingDetailFields, 30000, "+08:00")
		if e != nil {
			return Result{}, interfaceFailure(ctx, "气温水电热对比", "读取明细字段", e)
		}
		check := in
		check.ComparisonType = "明细"
		if e = validateSlidingRows(check, detail); e != nil {
			return Result{}, interfaceFailure(ctx, "气温水电热对比", "校验明细", e)
		}
		if !rows.NextResultSet() {
			return Result{}, interfaceFailure(ctx, "气温水电热对比", "读取汇总", fmt.Errorf("missing summary result set: %v", rows.Err()))
		}
	}
	fields := slidingSummaryFields
	if in.ComparisonType == "明细" {
		fields = slidingDetailFields
	}
	batch, e := scanInterfaceRows(rows, fields, 30000, "+08:00")
	if e != nil {
		return Result{}, interfaceFailure(ctx, "气温水电热对比", "读取返回字段", e)
	}
	if e = validateSlidingRows(in, batch); e != nil {
		return Result{}, interfaceFailure(ctx, "气温水电热对比", "校验结果", e)
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	result := Result{Points: []Point{}, Rows: []Row{}, Comparisons: batch, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision}
	if in.IncludeDetails {
		result.ComparisonDetails = detail
		result.ComparisonDays = comparisonDays(detail)
	}
	if in.ComparisonType == "明细" {
		result.ComparisonDays = comparisonDays(batch)
	}
	return result, nil
}

func validateSlidingRows(in Request, batch []map[string]*string) error {
	seen := map[string]bool{}
	sequences := map[string][]map[string]*string{}
	stationMetrics := map[string]map[string]bool{}
	a, _ := slidingTime(in.From)
	b, _ := slidingTime(in.To)
	h, _ := slidingTime(in.HistoryFrom)
	for _, m := range batch {
		st, metric := value(m["整站编码"]), value(m["指标"])
		if !siteCode.MatchString(st) || (in.Station != "" && st != in.Station) || !slices.Contains([]string{"水", "电", "热"}, metric) {
			return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
		}
		key := st + "/" + metric
		if stationMetrics[st] == nil {
			stationMetrics[st] = map[string]bool{}
		}
		stationMetrics[st][metric] = true
		if in.ComparisonType == "汇总" {
			for k, want := range map[string]string{"本期开始时间": in.From, "本期结束时间": in.To, "历史开始时间": in.HistoryFrom, "历史结束时间": in.HistoryTo} {
				t, err := slidingTime(value(m[k]))
				expected, _ := slidingTime(want)
				if err != nil || !t.Equal(expected) {
					return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
				}
			}
		} else {
			x, e1 := slidingTime(value(m["本期开始"]))
			y, e2 := slidingTime(value(m["本期结束"]))
			u, e3 := slidingTime(value(m["历史开始"]))
			v, e4 := slidingTime(value(m["历史结束"]))
			if e1 != nil || e2 != nil || e3 != nil || e4 != nil || x.Before(a) || y.After(b) || !y.After(x) || y.Sub(x) > time.Hour || x.Sub(a) != u.Sub(h) || y.Sub(x) != v.Sub(u) {
				return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
			}
			seconds, ok := new(big.Rat).SetString(value(m["片段秒数"]))
			want := new(big.Rat).SetFrac64(y.Sub(x).Milliseconds(), 1000)
			if !ok || seconds.Cmp(want) != 0 {
				return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
			}
			sequences[key] = append(sequences[key], m)
			key += "/" + x.Format(time.RFC3339Nano)
		}
		if seen[key] {
			return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
		}
		seen[key] = true
	}
	for _, metrics := range stationMetrics {
		if len(metrics) != 3 {
			return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
		}
	}
	for _, sequence := range sequences {
		sort.Slice(sequence, func(i, j int) bool { return value(sequence[i]["本期开始"]) < value(sequence[j]["本期开始"]) })
		next := a
		for _, row := range sequence {
			start, _ := slidingTime(value(row["本期开始"]))
			end, _ := slidingTime(value(row["本期结束"]))
			if !start.Equal(next) {
				return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
			}
			next = end
		}
		if !next.Equal(b) {
			return fmt.Errorf("返回的站点、指标或时间片段不符合查询条件")
		}
	}
	return nil
}

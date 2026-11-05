package externaldata

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

const periodStart = "2026-11-04"
const intervalProcedure = `EXEC dbo.usp_查询站区间隔历史 @站区编码=@station,@开始UTC=@from,@结束UTC=@to,@间隔分钟=@interval,@每页行数=@size,@跳过行数=@offset`
const settlementProcedure = `EXEC dbo.usp_查询站区日结算 @开始日期=@from,@结束日期=@to,@站区编码=@station`
const comparisonProcedure = `EXEC dbo.usp_整站水电热自选日期对比 @整站编码=@station,@本期开始日期=@from,@本期结束日期=@to,@历史开始日期=@historyFrom,@历史结束日期=@historyTo,@指标=@metric,@返回类型=@kind,@历史换算系数=@factor`

// Scan driver decimals without float conversion; retain NULL and original labels.
func scanInterfaceRows(rows *sql.Rows, required []string, limit int, offset string) ([]map[string]*string, error) {
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	for _, c := range required {
		if !slices.Contains(cols, c) {
			return nil, fmt.Errorf("missing column %s", c)
		}
	}
	out := []map[string]*string{}
	for rows.Next() {
		vals := make([]any, len(cols))
		dest := make([]any, len(cols))
		for i := range vals {
			dest[i] = &vals[i]
		}
		if err = rows.Scan(dest...); err != nil {
			return nil, err
		}
		m := map[string]*string{}
		for i, c := range cols {
			m[c] = nil
			if vals[i] == nil {
				continue
			}
			var v string
			switch x := vals[i].(type) {
			case time.Time:
				v = x.Format("2006-01-02T15:04:05.999999999") + offset
			case []byte:
				v = string(x)
			case string:
				v = x
			default:
				v = fmt.Sprint(x)
			}
			m[c] = &v
		}
		out = append(out, m)
		if len(out) > limit {
			return nil, fmt.Errorf("result row limit")
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if rows.NextResultSet() {
		return nil, fmt.Errorf("unexpected extra result set")
	}
	return out, rows.Err()
}

func interfaceError(ctx context.Context, name string) error {
	if ctx.Err() != nil {
		return queryError(ctx)
	}
	return fmt.Errorf("%s查询失败，请核对已部署接口、返回字段和软件连接账号的只读执行权限", name)
}

func (s *Service) queryInterval(ctx context.Context, db *sql.DB, source storedSource, view Screen, in Request, from, to time.Time, points []Point) (Result, error) {
	result := Result{Points: points, Rows: []Row{}, Offset: in.Offset, UTCOffsetMinutes: source.UTCOffsetMinutes, SourceRevision: source.Revision, ScreenRevision: view.Revision, HistoryColumns: view.HistoryColumns}
	sort.Slice(points, func(i, j int) bool { return points[i].Column < points[j].Column })
	schema := make([][4]string, 0, len(points))
	for _, p := range points {
		schema = append(schema, [4]string{p.Code, p.Name, p.Unit, p.Column})
	}
	encoded, _ := json.Marshal(schema)
	result.MappingID = fmt.Sprintf("%x", sha256.Sum256(encoded))
	rows, err := db.QueryContext(ctx, intervalProcedure, sql.Named("station", in.Station), sql.Named("from", from), sql.Named("to", to), sql.Named("interval", in.Interval), sql.Named("size", in.PageSize), sql.Named("offset", in.Offset))
	if err != nil {
		return Result{}, interfaceError(ctx, "间隔历史")
	}
	defer rows.Close()
	required := []string{"StationCode", "SlotIndex", "TotalSlots", "HasMore", "TargetTimeUTC", "ActualSampleTimeUTC", "QualityCode"}
	for i := 1; i <= 60; i++ {
		required = append(required, fmt.Sprintf("Value%02d", i))
	}
	batch, err := scanInterfaceRows(rows, required, in.PageSize, "Z")
	if err != nil {
		return Result{}, interfaceError(ctx, "间隔历史")
	}
	zone := time.FixedZone("source", source.UTCOffsetMinutes*60)
	interval := time.Duration(in.Interval) * time.Minute
	expectedTotal := int((to.Sub(from) + interval - 1) / interval)
	for i, m := range batch {
		index, e1 := strconv.Atoi(value(m["SlotIndex"]))
		total, e2 := strconv.Atoi(value(m["TotalSlots"]))
		more, e3 := strconv.ParseBool(value(m["HasMore"]))
		target, e4 := time.Parse(time.RFC3339Nano, value(m["TargetTimeUTC"]))
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil || value(m["StationCode"]) != in.Station || index != in.Offset+i || total != expectedTotal || more != (in.Offset+in.PageSize < total) || !target.Equal(from.Add(time.Duration(index)*interval)) {
			return Result{}, interfaceError(ctx, "间隔历史")
		}
		result.Total = total
		result.HasMore = more
		r := Row{TargetTime: target.In(zone).Format(time.RFC3339Nano), Match: "missing", Values: make([]*string, len(points))}
		if m["ActualSampleTimeUTC"] != nil {
			sample, e := time.Parse(time.RFC3339Nano, *m["ActualSampleTimeUTC"])
			if e != nil || sample.Before(from) || !sample.Before(to) {
				return Result{}, interfaceError(ctx, "间隔历史")
			}
			stamp := sample.In(zone).Format(time.RFC3339Nano)
			r.SampleTime = &stamp
			r.Match = "nearest"
			if sample.Equal(target) {
				r.Match = "exact"
			}
		}
		if m["QualityCode"] != nil {
			q, e := strconv.ParseInt(*m["QualityCode"], 10, 64)
			if e != nil {
				return Result{}, interfaceError(ctx, "间隔历史")
			}
			r.Quality = &q
		}
		for j, p := range points {
			r.Values[j] = m[p.Column]
		}
		result.Rows = append(result.Rows, r)
	}
	if len(batch) != max(0, min(in.PageSize, expectedTotal-in.Offset)) {
		return Result{}, fmt.Errorf("间隔历史目标时间页不完整，请重新查询")
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return result, nil
}

func comparisonBounds(in Request, now time.Time) (Request, error) {
	bad := func() (Request, error) {
		return in, fmt.Errorf("本期从2026-11-04至今天，历史须为已结束日期；两段窗口须等长且最多366天，换算系数须为有效正数")
	}
	parse := func(v string) (time.Time, error) { return time.ParseInLocation("2006-01-02", v, beijing) }
	a, e1 := parse(in.From)
	b, e2 := parse(in.To)
	h, e3 := parse(in.HistoryFrom)
	j, e4 := parse(in.HistoryTo)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
		return bad()
	}
	if b.Before(a) {
		a, b = b, a
	}
	if j.Before(h) {
		h, j = j, h
	}
	today := now.In(beijing).Format("2006-01-02")
	if a.Format("2006-01-02") < periodStart || b.Format("2006-01-02") > today || j.Format("2006-01-02") >= today || h.Year() < 2000 || b.Sub(a) != j.Sub(h) || b.Sub(a) > 365*24*time.Hour || in.Offset != 0 || (in.Station != "" && !siteCode.MatchString(in.Station)) || !slices.Contains([]string{"", "水", "电", "热"}, in.Metric) || !slices.Contains([]string{"明细", "汇总"}, in.ComparisonType) {
		return bad()
	}
	if in.HistoryFactor != "" {
		if !regexp.MustCompile(`^(?:0|[1-9][0-9]{0,7})(?:\.[0-9]{1,10})?$`).MatchString(in.HistoryFactor) {
			return bad()
		}
		n, ok := new(big.Rat).SetString(in.HistoryFactor)
		if !ok || n.Sign() <= 0 {
			return bad()
		}
	}
	in.From = a.Format("2006-01-02")
	in.To = b.Format("2006-01-02")
	in.HistoryFrom = h.Format("2006-01-02")
	in.HistoryTo = j.Format("2006-01-02")
	return in, nil
}

var settlementFields = []string{"统计日期", "站区编码", "站区名称", "测点编码", "测点", "单位", "输出列", "有日表记录", "已结算小计", "完整日用量", "有效小时数", "日状态码", "日状态", "统计行最大小时", "日异常字段"}

func (s *Service) querySettlement(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	now := time.Now()
	start, end, _, err := statisticsBounds("daily", in, now)
	if err != nil {
		return Result{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer close()
	rows, err := db.QueryContext(ctx, settlementProcedure, sql.Named("from", start.Format("2006-01-02")), sql.Named("to", end.Format("2006-01-02")), sql.Named("station", in.Station))
	if err != nil {
		return Result{}, interfaceError(ctx, "日结算")
	}
	defer rows.Close()
	batch, err := scanInterfaceRows(rows, settlementFields, 25000, "+08:00")
	if err != nil {
		return Result{}, interfaceError(ctx, "日结算")
	}
	rows.Close()
	ranges, err := readSettlementRanges(ctx, db, batch, start.Format("2006-01-02"), end.Format("2006-01-02"), in.Station)
	if err != nil {
		return Result{}, interfaceError(ctx, "日报范围与统计类型")
	}
	result := Result{Points: []Point{}, Rows: []Row{}, Statistics: []Statistic{}, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision, StatisticsColumns: view.StatisticsColumns}
	seen := map[string]bool{}
	for _, m := range batch {
		date := strings.Split(value(m["统计日期"]), "T")[0]
		station := value(m["站区编码"])
		point := value(m["测点编码"])
		column := value(m["输出列"])
		key := date + "/" + station + "/" + point
		if date < start.Format("2006-01-02") || date > end.Format("2006-01-02") || station != in.Station || point == "" || column == "" || seen[key] {
			return Result{}, interfaceError(ctx, "日结算")
		}
		seen[key] = true
		var anomaly *string
		if raw := value(m["日异常字段"]); raw != "" {
			var fields map[string]json.RawMessage
			if json.Unmarshal([]byte(raw), &fields) != nil {
				return Result{}, interfaceError(ctx, "日结算")
			}
			if v, ok := fields[column]; ok && string(v) != "null" {
				text := string(v)
				anomaly = &text
			}
		}
		r := ranges[key]
		result.Statistics = append(result.Statistics, Statistic{Station: station, Name: value(m["站区名称"]), Metric: point, Label: value(m["测点"]), Unit: value(m["单位"]), Date: date, StatisticKind: value(r["statistic_kind"]), DayMin: r["day_min"], DayMax: r["day_max"], DayUsage: m["完整日用量"], DaySubtotal: m["已结算小计"], DayStatus: m["日状态"], DayRecord: m["有日表记录"], ValidHours: m["有效小时数"], DayStatusCode: m["日状态码"], DayAnomaly: anomaly, SampleMax: m["统计行最大小时"], CurrentDay: date == now.In(beijing).Format("2006-01-02")})
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	sort.SliceStable(result.Statistics, func(i, j int) bool {
		a, b := result.Statistics[i], result.Statistics[j]
		return a.Date+a.Station+a.Metric < b.Date+b.Station+b.Metric
	})
	return result, nil
}

var comparisonDetailFields = []string{"序号", "整站编码", "甲方站名", "本期日期", "历史日期", "指标", "本期单位", "本期日用量", "本期状态", "本期最晚参与采样时间", "历史日用量", "历史状态", "历史取数方式", "历史参与列", "历史单位", "历史日用量折算", "双方完整日有效", "可比", "差值", "变化百分比", "对比状态"}
var comparisonSummaryFields = []string{"整站编码", "甲方站名", "指标", "本期单位", "本期开始日期", "本期结束日期", "历史开始日期", "历史结束日期", "选择天数", "本期完整有效天数", "历史有效天数", "双方完整日有效天数", "参与对比天数", "排除天数", "本期配对用量", "历史配对用量", "差值", "变化百分比", "历史含异常天数", "汇总状态"}

func (s *Service) queryComparison(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	in, err := comparisonBounds(in, time.Now())
	if err != nil {
		return Result{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer close()
	nullable := func(v string) any {
		if v == "" {
			return nil
		}
		return v
	}
	rows, err := db.QueryContext(ctx, comparisonProcedure, sql.Named("station", nullable(in.Station)), sql.Named("from", in.From), sql.Named("to", in.To), sql.Named("historyFrom", in.HistoryFrom), sql.Named("historyTo", in.HistoryTo), sql.Named("metric", nullable(in.Metric)), sql.Named("kind", in.ComparisonType), sql.Named("factor", nullable(in.HistoryFactor)))
	if err != nil {
		return Result{}, interfaceError(ctx, "同期对比")
	}
	defer rows.Close()
	fields := comparisonDetailFields
	if in.ComparisonType == "汇总" {
		fields = comparisonSummaryFields
	}
	batch, err := scanInterfaceRows(rows, fields, 25000, "+08:00")
	if err != nil {
		return Result{}, interfaceError(ctx, "同期对比")
	}
	seen := map[string]bool{}
	for _, m := range batch {
		station := value(m["整站编码"])
		metric := value(m["指标"])
		if !siteCode.MatchString(station) || (in.Station != "" && station != in.Station) || !slices.Contains([]string{"水", "电", "热"}, metric) || (in.Metric != "" && metric != in.Metric) {
			return Result{}, interfaceError(ctx, "同期对比")
		}
		key := station + "/" + metric
		if in.ComparisonType == "明细" {
			a, e1 := time.ParseInLocation("2006-01-02", strings.Split(value(m["本期日期"]), "T")[0], beijing)
			h, e2 := time.ParseInLocation("2006-01-02", strings.Split(value(m["历史日期"]), "T")[0], beijing)
			start, _ := time.ParseInLocation("2006-01-02", in.From, beijing)
			old, _ := time.ParseInLocation("2006-01-02", in.HistoryFrom, beijing)
			if e1 != nil || e2 != nil || a.Format("2006-01-02") < in.From || a.Format("2006-01-02") > in.To || a.Sub(start) != h.Sub(old) {
				return Result{}, interfaceError(ctx, "同期对比")
			}
			key += "/" + a.Format("2006-01-02")
		} else {
			for col, want := range map[string]string{"本期开始日期": in.From, "本期结束日期": in.To, "历史开始日期": in.HistoryFrom, "历史结束日期": in.HistoryTo} {
				if strings.Split(value(m[col]), "T")[0] != want {
					return Result{}, interfaceError(ctx, "同期对比")
				}
			}
		}
		if seen[key] {
			return Result{}, interfaceError(ctx, "同期对比")
		}
		seen[key] = true
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return Result{Points: []Point{}, Rows: []Row{}, Comparisons: batch, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision}, nil
}

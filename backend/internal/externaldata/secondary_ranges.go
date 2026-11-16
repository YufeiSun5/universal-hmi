package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"time"
)

type secondaryRange struct {
	hour, point string
	low, high   *string
	complete    bool
}

// Sum simultaneous, quality-qualified samples BEFORE finding extrema. Adding
// two independently computed Min/Max values would invent a range that may
// never have occurred. Effective source versions are checked for every sample;
// an old mapping is never read through today's column silently.
func secondaryRangeSQL(bindings map[string]secondaryBinding) (string, error) {
	values := []string{}
	for _, pair := range secondaryMeterPairs[:2] {
		a, b := bindings[pair.first], bindings[pair.second]
		if !validColumn(a.sample) || !validColumn(b.sample) || a.sample == b.sample {
			return "", fmt.Errorf("东南区同步采样列无效")
		}
		values = append(values, fmt.Sprintf("(N'%s',N'%s',N'%s',N'%s',sample.[%s]+sample.[%s])", pair.first, pair.second, a.sample, b.sample, a.sample, b.sample))
	}
	return `;WITH definitions AS (
 SELECT p.PointId,p.StationId,p.PointCode FROM dbo.Point p JOIN dbo.Station s ON s.StationId=p.StationId
 WHERE s.StationCode=@station AND s.IsEnabled=1 AND p.IsEnabled=1 AND p.DeviceId IS NULL
 AND p.SampleTable='StationSample' AND p.ValueType='N'
 AND p.PointCode IN ('ER_FlowRate','ER_Secondary2FlowRate','ER_SecondaryHeatRate','ER_Secondary2HeatRate')
), versions AS (
 SELECT m.*,LEAD(m.生效UTC) OVER(PARTITION BY m.PointId ORDER BY m.生效UTC) next_version
 FROM dbo.统计测点来源 m JOIN definitions p ON p.PointId=m.PointId
), paired AS (
 SELECT DATEADD(hour,8,DATEADD(hour,DATEDIFF(hour,CONVERT(datetime2(3),'20000101'),sample.SampleTime),CONVERT(datetime2(3),'20000101'))) period,
 x.first_code point,va.生效UTC first_version,vb.生效UTC second_version,
 CASE WHEN va.来源列=x.first_column AND vb.来源列=x.second_column AND va.来源状态=N'已接入' AND vb.来源状态=N'已接入'
 AND va.算差额=0 AND vb.算差额=0 THEN x.total END reading
 FROM dbo.StationSample sample JOIN dbo.Station station ON station.StationId=sample.StationId
 CROSS APPLY(VALUES ` + strings.Join(values, ",") + `)x(first_code,second_code,first_column,second_column,total)
 JOIN definitions a ON a.StationId=sample.StationId AND a.PointCode=x.first_code
 JOIN definitions b ON b.StationId=sample.StationId AND b.PointCode=x.second_code
 LEFT JOIN versions va ON va.PointId=a.PointId AND sample.SampleTime>=va.生效UTC AND (va.next_version IS NULL OR sample.SampleTime<va.next_version)
 LEFT JOIN versions vb ON vb.PointId=b.PointId AND sample.SampleTime>=vb.生效UTC AND (vb.next_version IS NULL OR sample.SampleTime<vb.next_version)
 WHERE station.StationCode=@station AND station.IsEnabled=1 AND sample.SampleTime>=@from AND sample.SampleTime<@to
 AND sample.SampleTime<=@asof AND sample.QualityCode IN(1,2)
)
SELECT period,point,MIN(reading) low,MAX(reading) high,COUNT_BIG(*) total,COUNT_BIG(reading) paired,
 COUNT(DISTINCT first_version) first_versions,COUNT(DISTINCT second_version) second_versions
FROM paired GROUP BY period,point ORDER BY period,point`, nil
}

func readSecondaryRanges(ctx context.Context, db *sql.DB, bindings map[string]secondaryBinding, start, end, asof time.Time) (map[string]secondaryRange, error) {
	query, err := secondaryRangeSQL(bindings)
	if err != nil {
		return nil, err
	}
	rows, err := db.QueryContext(ctx, query, sql.Named("station", southeastStation), sql.Named("from", start.UTC()), sql.Named("to", end.AddDate(0, 0, 1).UTC()), sql.Named("asof", asof.UTC()))
	if err != nil {
		return nil, interfaceFailure(ctx, "东南区二次网同步范围", "读取", err)
	}
	defer rows.Close()
	batch, err := scanInterfaceRows(rows, []string{"period", "point", "low", "high", "total", "paired", "first_versions", "second_versions"}, 31*24*2, "+08:00")
	if err != nil {
		return nil, interfaceError(ctx, "东南区二次网同步范围")
	}
	out := map[string]secondaryRange{}
	for _, m := range batch {
		point, hour := value(m["point"]), value(m["period"])
		at, err := time.Parse(time.RFC3339Nano, hour)
		if err != nil || at.Before(start) || !at.Before(end.AddDate(0, 0, 1)) || at.Minute() != 0 || at.Second() != 0 || at.Nanosecond() != 0 || (point != secondaryMeterPairs[0].first && point != secondaryMeterPairs[1].first) {
			return nil, fmt.Errorf("东南区同步范围返回了无效时段或测点")
		}
		hour = at.In(beijing).Format(time.RFC3339Nano)
		key := hour + "/" + point
		if _, exists := out[key]; exists {
			return nil, fmt.Errorf("东南区同步范围返回重复时段")
		}
		counts := map[string]int64{}
		for _, field := range []string{"total", "paired", "first_versions", "second_versions"} {
			n, err := strconv.ParseInt(value(m[field]), 10, 64)
			if err != nil || n < 0 {
				return nil, fmt.Errorf("东南区同步采样计数无效")
			}
			counts[field] = n
		}
		if counts["paired"] > counts["total"] {
			return nil, fmt.Errorf("东南区同步采样计数不一致")
		}
		r := secondaryRange{hour: hour, point: point, low: m["low"], high: m["high"], complete: counts["total"] > 0 && counts["paired"] == counts["total"] && counts["first_versions"] == 1 && counts["second_versions"] == 1}
		for _, v := range []*string{r.low, r.high} {
			if v != nil && !statisticDecimal.MatchString(*v) {
				return nil, fmt.Errorf("东南区同步范围数值无效")
			}
		}
		if r.low != nil && r.high != nil {
			lo, _ := new(big.Rat).SetString(*r.low)
			hi, _ := new(big.Rat).SetString(*r.high)
			if lo.Cmp(hi) > 0 {
				return nil, fmt.Errorf("东南区同步范围最小值大于最大值")
			}
		} else {
			r.complete = false
		}
		out[key] = r
	}
	return out, nil
}

func applySecondaryRange(r *Statistic, a, b Statistic, pair secondaryPair, daily bool, ranges map[string]secondaryRange) {
	r.AggregationIncomplete = true
	if !daily {
		v, ok := ranges[value(r.Hour)+"/"+pair.first]
		if ok && v.complete && secondaryHourUsable(a) && secondaryHourUsable(b) && a.HourMin != nil && a.HourMax != nil && b.HourMin != nil && b.HourMax != nil {
			r.HourMin, r.HourMax = v.low, v.high
			r.AggregationIncomplete = false
		}
		if r.AggregationIncomplete {
			text := "同步采样或两组统计不完整"
			r.HourStatus = &text
		}
		return
	}
	// Daily reports use the persisted settlement horizon, including today's
	// latest settled hours. Never pull newer raw samples into an older day row.
	if a.StatisticKind != "range" || b.StatisticKind != "range" || a.DayMin == nil || a.DayMax == nil || b.DayMin == nil || b.DayMax == nil {
		return
	}
	last, err := time.Parse(time.RFC3339Nano, value(a.SampleMax))
	other, err2 := time.Parse(time.RFC3339Nano, value(b.SampleMax))
	if err != nil || err2 != nil || !last.Equal(other) || last.In(beijing).Format("2006-01-02") != r.Date || last.Minute() != 0 || last.Second() != 0 || last.Nanosecond() != 0 {
		text := "两组日结算进度缺失或不一致"
		r.DayStatus = &text
		return
	}
	var lo, hi *string
	count := 0
	for _, v := range ranges {
		if v.point != pair.first || !strings.HasPrefix(v.hour, r.Date+"T") {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, v.hour)
		if at.After(last) {
			continue
		}
		if !v.complete {
			text := "日内同步采样不完整或映射变化"
			r.DayStatus = &text
			return
		}
		count++
		x, _ := new(big.Rat).SetString(value(v.low))
		y, _ := new(big.Rat).SetString(value(v.high))
		if lo == nil {
			lo, hi = v.low, v.high
		} else {
			oldLo, _ := new(big.Rat).SetString(*lo)
			oldHi, _ := new(big.Rat).SetString(*hi)
			if x.Cmp(oldLo) < 0 {
				lo = v.low
			}
			if y.Cmp(oldHi) > 0 {
				hi = v.high
			}
		}
	}
	if count == 0 || (value(r.ValidHours) == "24" && count != 24) {
		text := "日结算对应的同步原始采样不完整"
		r.DayStatus = &text
		return
	}
	r.DayMin, r.DayMax = lo, hi
	r.AggregationIncomplete = value(r.ValidHours) != "24"
}

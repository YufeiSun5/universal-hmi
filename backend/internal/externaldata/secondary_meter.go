package externaldata

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
)

// Only this station has the explicitly commissioned FE201 + FE202 layout.
// This is a read-side report projection; source points and stored totals stay intact.
const southeastStation = "01-001-01"

type secondaryPair struct{ first, second, label, unit, kind string }

var secondaryMeterPairs = []secondaryPair{
	{"ER_FlowRate", "ER_Secondary2FlowRate", "二次网供水流量（合计）", "t/h", "range"},
	{"ER_SecondaryHeatRate", "ER_Secondary2HeatRate", "二次网瞬时热量（合计）", "GJ/h", "range"},
	{"ER_SecondaryTotalHeat", "ER_Secondary2TotalHeat", "二次网累计热量（合计）", "GJ", "usage"},
	{"ER_SecondaryTotalFlow", "ER_Secondary2TotalFlow", "二次网累计流量（合计）", "t", "usage"},
}

type secondaryBinding struct{ column, sample, unit string }

const secondaryMappingSQL = `SELECT p.PointCode,p.Unit,w.输出列,p.SampleColumn
FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId
LEFT JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
WHERE s.IsEnabled=1 AND s.StationCode=@station AND p.IsEnabled=1
 AND p.DeviceId IS NULL AND p.SampleTable='StationSample' AND p.ValueType='N'
 AND p.PointCode IN ('ER_FlowRate','ER_Secondary2FlowRate','ER_SecondaryHeatRate','ER_Secondary2HeatRate',
 'ER_SecondaryTotalHeat','ER_Secondary2TotalHeat','ER_SecondaryTotalFlow','ER_Secondary2TotalFlow')`

func loadSecondaryBindings(ctx context.Context, db *sql.DB) (map[string]secondaryBinding, error) {
	rows, err := db.QueryContext(ctx, secondaryMappingSQL, sql.Named("station", southeastStation))
	if err != nil {
		return nil, interfaceError(ctx, "东南区二次网计量定义")
	}
	defer rows.Close()
	out := map[string]secondaryBinding{}
	columns, samples := map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var code string
		var unit, column, sample sql.NullString
		if err := rows.Scan(&code, &unit, &column, &sample); err != nil {
			return nil, err
		}
		if _, exists := out[code]; exists || columns[column.String] || samples[sample.String] || !validColumn(column.String) || !validColumn(sample.String) {
			return nil, fmt.Errorf("东南区二次网计量映射缺失、重复或无效，请核对FE201/FE202定义")
		}
		out[code] = secondaryBinding{column.String, sample.String, strings.TrimSpace(unit.String)}
		columns[column.String], samples[sample.String] = true, true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, pair := range secondaryMeterPairs {
		for _, code := range []string{pair.first, pair.second} {
			binding, ok := out[code]
			if !ok {
				return nil, fmt.Errorf("东南区二次网合计缺少%s定义，不能用单组值代替", code)
			}
			if binding.unit != pair.unit {
				return nil, fmt.Errorf("东南区%s单位应为%s，请核对数据库定义；不自动换算", code, pair.unit)
			}
		}
	}
	return out, nil
}

var statisticDecimal = regexp.MustCompile(`^-?[0-9]{1,38}(\.[0-9]{1,12})?$`)

// Keep the decimal scale and exact precision, including real zero. A missing
// component never becomes zero or a one-meter subtotal labelled as the total.
func secondarySum(a, b *string) (*string, error) {
	if a == nil || b == nil {
		return nil, nil
	}
	scale := 0
	for _, s := range []string{*a, *b} {
		if !statisticDecimal.MatchString(s) {
			return nil, fmt.Errorf("二次网统计数值无效")
		}
		if dot := strings.IndexByte(s, '.'); dot >= 0 {
			scale = max(scale, len(s)-dot-1)
		}
	}
	x, _ := new(big.Rat).SetString(*a)
	y, _ := new(big.Rat).SetString(*b)
	v := new(big.Rat).Add(x, y).FloatString(scale)
	return &v, nil
}

func secondaryStatus(a, b *string) *string {
	x, y := value(a), value(b)
	if x == "" {
		x = "缺测"
	}
	if y == "" {
		y = "缺测"
	}
	v := x
	if x != y {
		v = "东区：" + x + "；南区：" + y
	}
	return &v
}

func secondaryHourUsable(r Statistic) bool {
	switch value(r.HourStatus) {
	case "有效", "有效含异常", "采样已滞后":
		return true
	}
	return false
}

func secondarySampleBounds(a, b Statistic) (*string, *string) {
	var lo, hi *string
	for _, stamp := range []*string{a.SampleMin, a.SampleMax, b.SampleMin, b.SampleMax} {
		if stamp == nil {
			continue
		}
		if lo == nil || *stamp < *lo {
			lo = stamp
		}
		if hi == nil || *stamp > *hi {
			hi = stamp
		}
	}
	return lo, hi
}

func combineSecondaryUsage(r *Statistic, a, b Statistic, daily bool) error {
	var err error
	if secondaryHourUsable(a) && secondaryHourUsable(b) {
		r.HourUsage, err = secondarySum(a.HourUsage, b.HourUsage)
		if err != nil {
			return err
		}
	}
	if daily && (a.StatisticKind != "usage" || b.StatisticKind != "usage") {
		r.AggregationIncomplete = true
		r.DayStatus = secondaryStatus(a.DayStatus, b.DayStatus)
		return nil
	}
	if r.DayUsage, err = secondarySum(a.DayUsage, b.DayUsage); err != nil {
		return err
	}
	if r.DaySubtotal, err = secondarySum(a.DaySubtotal, b.DaySubtotal); err != nil {
		return err
	}
	r.AggregationIncomplete = (daily && r.DayUsage == nil) || (!daily && r.HourUsage == nil)
	return nil
}

// Replace the two meter records only in the report response. Every other
// station/metric is retained unchanged. An absent member still produces a
// visible, explicitly incomplete aggregate at each returned period.
func combineSecondaryStatistics(rows []Statistic, bindings map[string]secondaryBinding, pairs []secondaryPair, daily bool, ranges map[string]secondaryRange) ([]Statistic, error) {
	out := make([]Statistic, 0, len(rows))
	groups := map[string]map[string]Statistic{}
	bases := map[string]Statistic{}
	member := map[string]bool{}
	identity := func(code string) string {
		if daily {
			return code
		}
		return bindings[code].column
	}
	for _, pair := range pairs {
		member[identity(pair.first)], member[identity(pair.second)] = true, true
	}
	for _, r := range rows {
		if r.Station != southeastStation {
			out = append(out, r)
			continue
		}
		key := r.Date + "/" + value(r.Hour)
		if daily {
			key = r.Date
		}
		if groups[key] == nil {
			groups[key] = map[string]Statistic{}
			bases[key] = r
		}
		if _, exists := groups[key][r.Metric]; exists {
			return nil, fmt.Errorf("东南区返回重复计量时段")
		}
		groups[key][r.Metric] = r
		if !member[r.Metric] {
			out = append(out, r)
		}
	}
	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		group, base := groups[key], bases[key]
		for _, pair := range pairs {
			a, b := group[identity(pair.first)], group[identity(pair.second)]
			for _, r := range []Statistic{a, b} {
				if r.Metric != "" && r.Unit != pair.unit {
					return nil, fmt.Errorf("东南区%s的计量单位已变化，请重新核对定义", pair.label)
				}
			}
			r := Statistic{Station: southeastStation, Name: base.Name, Date: base.Date, Hour: base.Hour, CurrentDay: base.CurrentDay,
				Metric: identity(pair.first), Label: pair.label, Unit: pair.unit, StatisticKind: pair.kind, Aggregation: "FE201+FE202",
				HourStatus: secondaryStatus(a.HourStatus, b.HourStatus), DayStatus: secondaryStatus(a.DayStatus, b.DayStatus)}
			r.SampleMin, r.SampleMax = secondarySampleBounds(a, b)
			if a.DayRecord != nil || b.DayRecord != nil {
				record := "false"
				if (value(a.DayRecord) == "true" || value(a.DayRecord) == "1") && (value(b.DayRecord) == "true" || value(b.DayRecord) == "1") {
					record = "true"
				}
				r.DayRecord = &record
			}
			// A minimum of per-meter hour counts is not the number of common
			// valid hours. Only a full 24+24 proves 24 shared valid hours.
			if value(a.ValidHours) == "24" && value(b.ValidHours) == "24" {
				r.ValidHours = a.ValidHours
			}
			if a.DayAnomaly != nil || b.DayAnomaly != nil {
				data, _ := json.Marshal(map[string]*string{"FE201": a.DayAnomaly, "FE202": b.DayAnomaly})
				text := string(data)
				r.DayAnomaly = &text
			}
			if pair.kind == "usage" {
				if err := combineSecondaryUsage(&r, a, b, daily); err != nil {
					return nil, err
				}
			} else {
				applySecondaryRange(&r, a, b, pair, daily, ranges)
			}
			if r.AggregationIncomplete {
				if daily {
					r.ValidHours = nil
				}
				status := r.HourStatus
				if daily {
					status = r.DayStatus
				}
				text := "两组不完整；" + value(status)
				if daily {
					r.DayStatus = &text
				} else {
					r.HourStatus = &text
				}
			}
			out = append(out, r)
		}
	}
	return out, nil
}

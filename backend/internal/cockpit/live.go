package cockpit

import (
	"context"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

var primaryLiveColumns = map[string]string{
	"高温水供水温度": "supply_temp", "高温水回水温度": "return_temp",
	"高温水供水压力": "supply_pressure", "高温水回水压力": "return_pressure",
	"一次网瞬时流量": "flow", "一次网瞬时热量": "power",
}

var secondaryLiveColumns = map[string]string{
	"二网供水温度": "supply_temp", "二网回水温度": "return_temp",
	"二网供水压力": "supply_pressure", "二网回水压力": "return_pressure",
	"二网供水流量": "flow", "二网热量瞬时值": "power",
}

func liveColumnBindings(columns []overview.Column, group string, names map[string]string) map[string]overview.Column {
	bindings := map[string]overview.Column{}
	for _, col := range columns {
		if key := names[col.Name]; col.Group == group && key != "" {
			if _, duplicate := bindings[key]; duplicate {
				bindings[key] = overview.Column{}
			} else {
				bindings[key] = col
			}
		}
	}
	return bindings
}

func reading(sample storage.Sample) (float64, bool) {
	value, ok := sample.Value.(float64)
	return value, ok && sample.Quality == "good" && !math.IsInf(value, 0) && !math.IsNaN(value)
}

func sampleUnit(sample storage.Sample, column overview.Column) string {
	if unit := strings.TrimSpace(sample.Unit); unit != "" {
		return unit
	}
	return strings.TrimSpace(column.Unit)
}

func powerMW(sample storage.Sample, column overview.Column) (float64, bool) {
	value, ok := reading(sample)
	switch strings.ToLower(sampleUnit(sample, column)) {
	case "gj/h":
		return value / 3.6, ok
	case "mw":
		return value, ok
	case "kw":
		return value / 1000, ok
	default:
		return 0, false
	}
}

type stationAge struct {
	name string
	last time.Time
}

func (s *Service) Live(ctx context.Context) (map[string]any, error) {
	if !authorized(ctx, false) {
		return nil, authorization.ErrDenied
	}
	c, err := s.config()
	if err != nil {
		return nil, err
	}
	// All-station access has been checked above. The engine independently
	// authorizes each selected ID, including linked variable dependencies.
	doc, err := s.overview.Get(context.Background(), nil)
	if err != nil {
		return nil, err
	}
	primary := liveColumnBindings(doc.Columns, "一次网", primaryLiveColumns)
	secondary := liveColumnBindings(doc.Columns, "二次网", secondaryLiveColumns)
	stations := map[string]stationAge{}
	rowsByID := map[string]overview.Row{}
	ids := []string{}
	requested := map[string]bool{}
	collect := func(id string) {
		if id != "" && !requested[id] {
			requested[id] = true
			ids = append(ids, id)
		}
	}
	collect(doc.Outdoor.PointID)
	for _, row := range doc.Rows {
		rowsByID[row.ID] = row
		for _, bindings := range []map[string]overview.Column{primary, secondary} {
			for _, col := range bindings {
				collect(row.Bindings[col.ID])
			}
		}
	}
	snapshot, err := s.runtime.SubscriptionSnapshot(ctx, ids)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	samples := map[string]storage.Sample{}
	values, _ := snapshot["values"].([]storage.Sample)
	for _, sample := range values {
		samples[sample.PointID] = sample
	}
	for _, row := range doc.Rows {
		key := row.Site + "\x00" + row.Name
		entry := stations[key]
		entry.name = row.Name
		for _, col := range primary {
			v := samples[row.Bindings[col.ID]]
			at := v.SourceTime
			if at.IsZero() {
				at = v.ReceivedTime
			}
			if at.After(entry.last) && !at.After(now) {
				entry.last = at
			}
		}
		stations[key] = entry
	}
	keys := make([]string, 0, len(stations))
	for k := range stations {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	status := make([]map[string]any, 0, len(keys))
	for _, key := range keys {
		row := stations[key]
		state, seconds := "unknown", 0
		if !row.last.IsZero() {
			seconds = int(now.Sub(row.last).Seconds())
			switch {
			case seconds >= c.OfflineMinutes*60:
				state = "offline"
			case seconds >= c.DelayMinutes*60:
				state = "delayed"
			default:
				state = "online"
			}
		}
		status = append(status, map[string]any{"name": row.name, "state": state, "age": seconds})
	}

	out := map[string]any{"title": c.Title, "stations": status}
	if outdoor, ok := reading(samples[doc.Outdoor.PointID]); ok {
		out["outdoor"] = outdoor
	}
	if len(doc.Rows) == 0 {
		out["notice"] = "数据总览尚未配置测点"
	} else if len(c.PowerRows) == 0 {
		out["notice"] = "尚未配置站所功率汇总"
	}
	readingsByZone := make([]map[string]any, 0, len(doc.Rows))
	for _, row := range doc.Rows {
		name := row.Name
		if row.Area != "" {
			name += " · " + row.Area
		}
		readings := map[string]any{"name": name, "zone": c.ZoneCodes[row.ID]}
		for key, col := range secondary {
			sample := samples[row.Bindings[col.ID]]
			value, ok := reading(sample)
			unit := sampleUnit(sample, col)
			if key == "power" {
				value, ok = powerMW(sample, col)
				unit = "MW"
			}
			if ok {
				readings[key] = map[string]any{"value": value, "unit": unit}
			}
		}
		readingsByZone = append(readingsByZone, readings)
	}
	out["rows"] = readingsByZone
	if power := livePower(c.PowerRows, rowsByID, primary["power"], samples); power != nil {
		out["power"] = *power
	}
	return out, nil
}

func powerGroup(row overview.Row) string {
	if row.Site != "" {
		return row.Site
	}
	return row.Name
}

func livePower(ids []string, rows map[string]overview.Row, column overview.Column, samples map[string]storage.Sample) *float64 {
	if len(ids) == 0 {
		return nil
	}
	points := map[string]bool{}
	sum := 0.0
	for _, id := range ids {
		row, exists := rows[id]
		if !exists {
			return nil
		}
		point := row.Bindings[column.ID]
		if points[point] {
			continue
		}
		value, ok := powerMW(samples[point], column)
		if !ok {
			return nil
		}
		points[point] = true
		sum += value
	}
	return &sum
}

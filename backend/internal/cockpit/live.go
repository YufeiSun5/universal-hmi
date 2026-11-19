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

var liveColumns = map[string]string{
	"高温水供水温度": "supply_temp", "高温水回水温度": "return_temp",
	"高温水供水压力": "supply_pressure", "高温水回水压力": "return_pressure",
	"一次网瞬时流量": "flow", "一次网瞬时热量": "power",
}

func liveColumnIDs(columns []overview.Column) map[string]string {
	ids := map[string]string{}
	for _, col := range columns {
		if key := liveColumns[col.Name]; col.Group == "一次网" && key != "" {
			if _, duplicate := ids[key]; duplicate {
				ids[key] = ""
			} else {
				ids[key] = col.ID
			}
		}
	}
	return ids
}

func reading(sample storage.Sample) (float64, bool) {
	value, ok := sample.Value.(float64)
	return value, ok && sample.Quality == "good" && !math.IsInf(value, 0) && !math.IsNaN(value)
}

func powerMW(sample storage.Sample) (float64, bool) {
	value, ok := reading(sample)
	switch strings.ToLower(strings.TrimSpace(sample.Unit)) {
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
	columns := liveColumnIDs(doc.Columns)
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
		for _, col := range columns {
			collect(row.Bindings[col])
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
		for _, col := range columns {
			v := samples[row.Bindings[col]]
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
	} else if len(c.FocusRows) == 0 {
		out["notice"] = "尚未配置重点站或功率汇总"
	}
	focus := []map[string]any{}
	for _, id := range c.FocusRows {
		row, exists := rowsByID[id]
		if !exists {
			continue
		}
		name := row.Name
		if row.Area != "" {
			name += " · " + row.Area
		}
		readings := map[string]any{"name": name, "zone": c.ZoneCodes[id]}
		for key, col := range columns {
			sample := samples[row.Bindings[col]]
			value, ok := reading(sample)
			unit := sample.Unit
			if key == "power" {
				value, ok = powerMW(sample)
				unit = "MW"
			}
			if ok {
				readings[key] = map[string]any{"value": value, "unit": unit}
			}
		}
		focus = append(focus, readings)
	}
	out["rows"] = focus
	out["groups"] = livePower(c.PowerRows, rowsByID, columns["power"], samples, c.RatedMW, out)
	return out, nil
}

func powerGroup(row overview.Row) string {
	if row.Site != "" {
		return row.Site
	}
	return row.Name
}

func livePower(ids []string, rows map[string]overview.Row, column string, samples map[string]storage.Sample, rated map[string]float64, out map[string]any) []map[string]any {
	type total struct {
		value   float64
		missing bool
	}
	points := map[string]string{}
	groups := map[string]total{}
	all, incomplete := 0.0, false
	for _, id := range ids {
		row, exists := rows[id]
		if !exists {
			incomplete = true
			continue
		}
		group := powerGroup(row)
		sum := groups[group]
		point := row.Bindings[column]
		if existing, duplicate := points[point]; point != "" && duplicate {
			if existing != group {
				sum.missing = true
				groups[group] = sum
			}
			continue
		}
		if point != "" {
			points[point] = group
		}
		if value, ok := powerMW(samples[point]); ok {
			sum.value += value
			all += value
		} else {
			incomplete = true
			sum.missing = true
		}
		groups[group] = sum
	}
	if len(ids) > 0 && !incomplete {
		out["power"] = all
	}
	results := make([]map[string]any, 0, len(groups))
	for title, sum := range groups {
		row := map[string]any{"name": title}
		if !sum.missing {
			row["power"] = sum.value
			if rated[title] > 0 {
				row["load_percent"] = 100 * sum.value / rated[title]
			}
		}
		results = append(results, row)
	}
	sort.Slice(results, func(i, j int) bool { return results[i]["name"].(string) < results[j]["name"].(string) })
	return results
}

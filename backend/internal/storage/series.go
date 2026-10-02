package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	MaxSeriesSelection = 6
	MinSeriesPoints    = 20
	MaxSeriesPoints    = 600
	MaxSeriesSummaries = 256
	SeriesTimeout      = 3 * time.Second
)

// SeriesSample is an original, frozen row, never an averaged or synthetic value.
// BreakBefore forbids connecting to the preceding returned row for this point.
// It includes discontinuities in rows removed by quality/value filters.
type SeriesSample struct {
	Sample
	BreakBefore bool `json:"break_before,omitempty"`
}

type SeriesSummary struct {
	PointID string   `json:"point_id"`
	Station string   `json:"station"`
	Name    string   `json:"name"`
	Unit    string   `json:"unit"`
	Version string   `json:"version"`
	Count   int64    `json:"count"`
	Valid   int64    `json:"valid"`
	Min     *float64 `json:"min"`
	Max     *float64 `json:"max"`
	Mean    *float64 `json:"mean"`
	// Latest is the chronologically latest valid numeric value in this group.
	Latest *float64 `json:"latest"`
}

type SeriesResult struct {
	Items     []SeriesSample  `json:"items"`
	Summaries []SeriesSummary `json:"summaries"`
	Count     int64           `json:"count"`
	Returned  int             `json:"returned"`
	Sampled   bool            `json:"sampled"`
	Before    int64           `json:"before"`
	Boundary  int64           `json:"boundary"`
	From      int64           `json:"from"`
	To        int64           `json:"to"`
}

func ValidatePointSelection(f Filter, required bool) error {
	if f.PointID != "" && len(f.PointIDs) > 0 {
		return fmt.Errorf("choose point_id or point_ids, not both")
	}
	ids := f.PointIDs
	if f.PointID != "" {
		ids = []string{f.PointID}
	}
	if len(ids) > MaxSeriesSelection || required && len(ids) == 0 {
		return fmt.Errorf("select 1..%d point IDs", MaxSeriesSelection)
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if id == "" || strings.TrimSpace(id) != id || len(id) > 256 || seen[id] {
			return fmt.Errorf("point IDs must be nonempty, unique, and at most 256 bytes")
		}
		seen[id] = true
	}
	return nil
}

type seriesKey struct{ point, station, unit, version string }
type seriesRow struct {
	Sample
	valueJSON, rawJSON string
	source             int64
	numeric            sql.NullFloat64
	valid              bool
	run                uint64
}

type seriesBucket struct{ first, last, min, max, gap *seriesRow }

func (b *seriesBucket) add(r *seriesRow) {
	if b.first == nil {
		b.first = r
	}
	b.last = r
	if r.valid {
		if b.min == nil || r.numeric.Float64 < b.min.numeric.Float64 {
			b.min = r
		}
		if b.max == nil || r.numeric.Float64 > b.max.numeric.Float64 {
			b.max = r
		}
	} else if b.gap == nil {
		b.gap = r
	}
}

type seriesGroup struct {
	count, first, last int64
	budget             int
	buckets            []seriesBucket
	exact              []*seriesRow
	summary            SeriesSummary
}

type seriesPoint struct {
	groups      []*seriesGroup
	key         seriesKey
	connectable bool
	run         uint64
}

// Series scans a database cursor, retaining at most maxPoints original rows per
// point plus 256 summaries. Large ranges use temporal buckets containing at most
// first/last/min/max/one invalid marker for every frozen unit/version group.
// Budgets that cannot represent every group fail explicitly. No LIMIT can truncate the
// requested range, and even hidden discontinuities advance the connection run.
// A read transaction freezes both retention changes and the sequence boundary.
func (s *Store) Series(ctx context.Context, f Filter, maxPoints int) (SeriesResult, error) {
	out := SeriesResult{Items: []SeriesSample{}, Summaries: []SeriesSummary{}}
	if err := ValidatePointSelection(f, true); err != nil {
		return out, err
	}
	if maxPoints < MinSeriesPoints || maxPoints > MaxSeriesPoints {
		return out, fmt.Errorf("max_points must be %d..%d", MinSeriesPoints, MaxSeriesPoints)
	}
	if f.Before < -1 || f.After < 0 || f.From < 0 || f.To < 0 || f.From > 0 && f.To > 0 && f.From > f.To {
		return out, fmt.Errorf("invalid series range")
	}
	for _, n := range []*float64{f.Min, f.Max} {
		if n != nil && (math.IsNaN(*n) || math.IsInf(*n, 0)) {
			return out, fmt.Errorf("finite numeric filter required")
		}
	}
	if f.Min != nil && f.Max != nil && *f.Min > *f.Max {
		return out, fmt.Errorf("numeric range reversed")
	}
	ctx, cancel := context.WithTimeout(ctx, SeriesTimeout)
	defer cancel()
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return out, err
	}
	defer tx.Rollback()
	var boundary int64
	if err := tx.QueryRowContext(ctx, "SELECT COALESCE(MAX(seq),-1) FROM samples").Scan(&boundary); err != nil {
		return out, err
	}
	if f.Before == 0 || f.Before > boundary {
		f.Before = boundary
	}
	out.Before, out.Boundary = f.Before, f.Before
	w, args := where(f)
	bounds, err := tx.QueryContext(ctx, "SELECT point_id,station,unit,version,COUNT(*),MIN(source_time),MAX(source_time) FROM samples WHERE "+w+" GROUP BY point_id,station,unit,version ORDER BY point_id,station,unit,version LIMIT ?", append(args, MaxSeriesSummaries+1)...)
	if err != nil {
		return out, err
	}
	points := map[string]*seriesPoint{}
	groups := map[seriesKey]*seriesGroup{}
	for bounds.Next() {
		var key seriesKey
		g := &seriesGroup{}
		if err = bounds.Scan(&key.point, &key.station, &key.unit, &key.version, &g.count, &g.first, &g.last); err != nil {
			bounds.Close()
			return out, err
		}
		if len(groups) == MaxSeriesSummaries {
			bounds.Close()
			return out, fmt.Errorf("history contains more than %d unit/version groups; narrow the time range", MaxSeriesSummaries)
		}
		if out.Count == 0 || g.first < out.From {
			out.From = g.first
		}
		if out.Count == 0 || g.last > out.To {
			out.To = g.last
		}
		out.Count += g.count
		g.summary = SeriesSummary{PointID: key.point, Station: key.station, Unit: key.unit, Version: key.version}
		groups[key] = g
		p := points[key.point]
		if p == nil {
			p = &seriesPoint{}
			points[key.point] = p
		}
		p.groups = append(p.groups, g)
	}
	err = bounds.Err()
	bounds.Close()
	if err != nil {
		return out, err
	}
	if out.Count == 0 {
		return out, ctx.Err()
	}
	for _, p := range points {
		remaining := maxPoints
		for _, g := range p.groups {
			g.budget = int(min(g.count, 5))
			remaining -= g.budget
		}
		if remaining < 0 {
			return out, fmt.Errorf("max_points cannot represent all frozen unit/version groups; increase max_points or narrow the time range")
		}
		// Reserve each group's extrema and gap marker, then distribute the spare
		// budget evenly among groups that still have additional original rows.
		for remaining > 0 {
			added := false
			for _, g := range p.groups {
				if remaining > 0 && int64(g.budget) < g.count {
					g.budget++
					remaining--
					added = true
				}
			}
			if !added {
				break
			}
		}
		for _, g := range p.groups {
			if g.count <= int64(g.budget) {
				g.exact = make([]*seriesRow, 0, int(g.count))
			} else {
				g.buckets = make([]seriesBucket, g.budget/5)
			}
		}
	}

	// Include excluded values/qualities in the cursor solely to identify breaks.
	// No such row contributes to returned samples, statistics, or result count.
	contextFilter := f
	contextFilter.Quality, contextFilter.Min, contextFilter.Max = "", nil, nil
	cw, contextArgs := where(contextFilter)
	query := "SELECT seq,point_id,station,name,value,raw,numeric,unit,quality,source_time,received_time,version,CASE WHEN " + w + " THEN 1 ELSE 0 END FROM samples WHERE " + cw + " ORDER BY point_id,source_time,seq"
	rows, err := tx.QueryContext(ctx, query, append(args, contextArgs...)...)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			return out, err
		}
		r := &seriesRow{}
		var received int64
		var included bool
		if err := rows.Scan(&r.Seq, &r.PointID, &r.Station, &r.Name, &r.valueJSON, &r.rawJSON, &r.numeric, &r.Unit, &r.Quality, &r.source, &received, &r.Version, &included); err != nil {
			return out, err
		}
		p := points[r.PointID]
		if p == nil {
			continue
		}
		key := seriesKey{r.PointID, r.Station, r.Unit, r.Version}
		r.valid = r.numeric.Valid && !math.IsInf(r.numeric.Float64, 0) && !math.IsNaN(r.numeric.Float64) && (r.Quality == "good" || r.Quality == "imported")
		connectable := included && r.valid
		if !connectable || !p.connectable || key != p.key {
			p.run++
		}
		p.key, p.connectable = key, connectable
		if !included {
			continue
		}
		r.run = p.run
		r.SourceTime, r.ReceivedTime = time.UnixMilli(r.source).UTC(), time.UnixMilli(received).UTC()
		g := groups[key]
		summary := &g.summary
		summary.Name = r.Name
		summary.Count++
		if r.valid {
			n := r.numeric.Float64
			summary.Valid++
			if summary.Min == nil || n < *summary.Min {
				v := n
				summary.Min = &v
			}
			if summary.Max == nil || n > *summary.Max {
				v := n
				summary.Max = &v
			}
			if summary.Mean == nil {
				v := n
				summary.Mean = &v
			} else {
				// Avoid overflow for finite values at opposite float64 extremes.
				count := float64(summary.Valid)
				mean := *summary.Mean
				if math.Signbit(mean) == math.Signbit(n) {
					mean += (n - mean) / count
				} else {
					mean = mean*((count-1)/count) + n/count
				}
				*summary.Mean = mean
			}
			v := n
			summary.Latest = &v
		}
		if g.exact != nil {
			g.exact = append(g.exact, r)
		} else {
			index := 0
			if g.last != g.first {
				// Unsigned differences avoid signed overflow and preserve tiny
				// intervals even when absolute millisecond timestamps are large.
				elapsed := uint64(r.source) - uint64(g.first)
				span := uint64(g.last) - uint64(g.first)
				index = int(float64(elapsed) / float64(span) * float64(len(g.buckets)))
			}
			if index < 0 {
				index = 0
			}
			if index >= len(g.buckets) {
				index = len(g.buckets) - 1
			}
			g.buckets[index].add(r)
		}
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	rows.Close()
	for _, g := range groups {
		out.Summaries = append(out.Summaries, g.summary)
	}
	sort.Slice(out.Summaries, func(i, j int) bool {
		a, b := out.Summaries[i], out.Summaries[j]
		if a.PointID != b.PointID {
			return a.PointID < b.PointID
		}
		if a.Station != b.Station {
			return a.Station < b.Station
		}
		if a.Unit != b.Unit {
			return a.Unit < b.Unit
		}
		return a.Version < b.Version
	})
	for _, p := range points {
		retained := make([]*seriesRow, 0, maxPoints)
		for _, g := range p.groups {
			if g.exact != nil {
				retained = append(retained, g.exact...)
				continue
			}
			for _, bucket := range g.buckets {
				for _, r := range []*seriesRow{bucket.first, bucket.last, bucket.min, bucket.max, bucket.gap} {
					if r != nil {
						retained = append(retained, r)
					}
				}
			}
		}
		sort.Slice(retained, func(i, j int) bool {
			if retained[i].source != retained[j].source {
				return retained[i].source < retained[j].source
			}
			return retained[i].Seq < retained[j].Seq
		})
		var previous *seriesRow
		for _, r := range retained {
			if previous != nil && previous.Seq == r.Seq {
				continue
			}
			if err := json.Unmarshal([]byte(r.valueJSON), &r.Value); err != nil {
				return out, err
			}
			if err := json.Unmarshal([]byte(r.rawJSON), &r.Raw); err != nil {
				return out, err
			}
			out.Items = append(out.Items, SeriesSample{Sample: r.Sample, BreakBefore: !r.valid || previous != nil && previous.run != r.run})
			previous = r
		}
	}
	sort.Slice(out.Items, func(i, j int) bool {
		a, b := out.Items[i], out.Items[j]
		if !a.SourceTime.Equal(b.SourceTime) {
			return a.SourceTime.Before(b.SourceTime)
		}
		return a.Seq < b.Seq
	})
	out.Returned = len(out.Items)
	out.Sampled = int64(out.Returned) < out.Count
	return out, ctx.Err()
}

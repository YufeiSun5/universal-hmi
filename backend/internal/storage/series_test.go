package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"
)

func seriesStore(t *testing.T, rows []Sample) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err := s.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	return s
}
func seriesFixture(point string, at int, value any) Sample {
	return Sample{PointID: point, Station: "A", Name: "Frozen " + point, Value: value, Raw: value, Unit: "bar", Quality: "good", SourceTime: time.UnixMilli(1700000000000 + int64(at)), ReceivedTime: time.UnixMilli(1700000000100 + int64(at)), Version: "v1"}
}
func TestSeriesSpansFullRangePreservesExtremaAndOriginalRows(t *testing.T) {
	rows := make([]Sample, 4000)
	for i := range rows {
		rows[i] = seriesFixture("p", i*1000, float64(i%17))
	}
	rows[1501].Value, rows[1501].Raw = -9000.0, -4500.0
	rows[3201].Value, rows[3201].Raw = 12000.0, 6000.0
	s := seriesStore(t, rows)
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err != nil {
		t.Fatal(err)
	}
	if got.Count != 4000 || got.Returned != len(got.Items) || got.Returned > 600 || !got.Sampled || got.Before != 4000 || got.Boundary != got.Before {
		t.Fatalf("incorrect bounds/counts: %+v", got)
	}
	if !got.Items[0].SourceTime.Equal(rows[0].SourceTime) || !got.Items[len(got.Items)-1].SourceTime.Equal(rows[3999].SourceTime) || got.From != rows[0].SourceTime.UnixMilli() || got.To != rows[3999].SourceTime.UnixMilli() {
		t.Fatal("series was truncated to a page")
	}
	found := map[int64]bool{}
	for _, r := range got.Items {
		found[r.Seq] = true
		original := rows[r.Seq-1]
		if r.Value != original.Value || r.Raw != original.Raw || r.Unit != original.Unit || r.Version != original.Version || !r.SourceTime.Equal(original.SourceTime) {
			t.Fatalf("synthetic/changed row %+v", r)
		}
	}
	if !found[1502] || !found[3202] {
		t.Fatal("lost range extrema")
	}
	if len(got.Summaries) != 1 || got.Summaries[0].Count != 4000 || got.Summaries[0].Valid != 4000 || *got.Summaries[0].Min != -9000 || *got.Summaries[0].Max != 12000 || *got.Summaries[0].Latest != rows[3999].Value.(float64) {
		t.Fatalf("wrong full range summary: %+v", got.Summaries)
	}
}

func TestSeriesMultiplePointsStationAndAllFiltersShareSnapshot(t *testing.T) {
	rows := []Sample{}
	for i := 0; i < 20; i++ {
		for _, point := range []string{"a", "b", "c"} {
			r := seriesFixture(point, i, float64(i))
			if i%2 == 1 {
				r.Quality = "imported"
			}
			rows = append(rows, r)
			r.Station = "B"
			rows = append(rows, r)
		}
	}
	s := seriesStore(t, rows)
	boundary, _ := s.Boundary()
	if err := s.Append(context.Background(), []Sample{seriesFixture("a", 100, 10.0)}); err != nil {
		t.Fatal(err)
	}
	min, max := 4.0, 16.0
	f := Filter{PointIDs: []string{"a", "b"}, Station: "A", Quality: "good", Min: &min, Max: &max, From: rows[0].SourceTime.Add(2 * time.Millisecond).UnixMilli(), To: rows[0].SourceTime.Add(18 * time.Millisecond).UnixMilli(), Before: boundary, After: 20}
	got, err := s.Series(context.Background(), f, 600)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := s.Query(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	stats, err := s.Stats(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	if got.Count != int64(stats.Count) || len(got.Items) != len(raw) || got.Sampled {
		t.Fatalf("filter disagreement: count %d stats %+v raw %d", got.Count, stats, len(raw))
	}
	sequences := map[int64]bool{}
	for _, r := range raw {
		sequences[r.Seq] = true
	}
	for _, r := range got.Items {
		if !sequences[r.Seq] || r.Station != "A" || r.PointID == "c" || r.Seq > boundary || r.Value.(float64) < 4 || r.Value.(float64) > 16 {
			t.Fatalf("escaped filter %+v", r)
		}
	}
	if len(got.Summaries) != 2 {
		t.Fatalf("wrong groups %+v", got.Summaries)
	}
}

func TestSeriesPreservesGapsIncludingExcludedRowsAndFrozenGroups(t *testing.T) {
	rows := []Sample{}
	for i := 0; i < 3000; i++ {
		rows = append(rows, seriesFixture("p", i, float64(i%10)))
	}
	rows[100].Quality = "bad"
	rows[130].Value = nil
	rows[160].Unit = "psi"
	rows[160].Version = "v2"
	rows[160].Value = 500.0
	rows[190].Value = 99.0
	s := seriesStore(t, rows)
	max := 20.0
	got, err := s.Series(context.Background(), Filter{PointID: "p", Quality: "good", Max: &max}, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Items) > 20 || got.Count != 2996 {
		t.Fatalf("bounds %+v", got)
	}
	// Every interval spanning an omitted invalid/value/version transition must break.
	for i := 1; i < len(got.Items); i++ {
		a, b := got.Items[i-1], got.Items[i]
		for _, hidden := range []int64{101, 131, 161, 191} {
			if a.Seq < hidden && b.Seq > hidden && !b.BreakBefore {
				t.Fatalf("joined hidden gap %d between %d and %d", hidden, a.Seq, b.Seq)
			}
		}
	}
	all, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err != nil {
		t.Fatal(err)
	}
	if len(all.Summaries) != 2 {
		t.Fatalf("units/versions merged: %+v", all.Summaries)
	}
	var invalid int
	for i, r := range all.Items {
		if r.Quality == "bad" || r.Value == nil {
			invalid++
			if !r.BreakBefore {
				t.Fatal("invalid row lacks break")
			}
			if i+1 < len(all.Items) && !all.Items[i+1].BreakBefore {
				t.Fatal("line resumed through invalid row")
			}
		}
	}
	if invalid == 0 {
		t.Fatal("no original gap marker retained")
	}
	for _, summary := range all.Summaries {
		if summary.Unit == "bar" && (summary.Count != 2999 || summary.Valid != 2997) {
			t.Fatalf("bad/null statistics included %+v", summary)
		}
	}
}

func TestSeriesSmallRangeChronologyFrozenVersionsAndNullOnlySummary(t *testing.T) {
	rows := []Sample{seriesFixture("p", 3, 3.0), seriesFixture("p", 0, 1.0), seriesFixture("p", 2, nil), seriesFixture("p", 1, 2.0), seriesFixture("p", 4, nil)}
	rows[0].Version = "v2"
	rows[0].Unit = "psi"
	rows[4].Version = "v3"
	s := seriesStore(t, rows)
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 20)
	if err != nil {
		t.Fatal(err)
	}
	if got.Sampled || len(got.Items) != 5 || got.Items[0].Seq != 2 || got.Items[4].Seq != 5 {
		t.Fatalf("wrong chronology %+v", got)
	}
	if got.Items[1].BreakBefore || !got.Items[2].BreakBefore || !got.Items[3].BreakBefore || !got.Items[4].BreakBefore {
		t.Fatalf("bad connection flags %+v", got.Items)
	}
	for _, s := range got.Summaries {
		if s.Version == "v3" && (s.Valid != 0 || s.Min != nil || s.Max != nil || s.Mean != nil || s.Latest != nil) {
			t.Fatalf("invalid converted to zero %+v", s)
		}
	}
}

func TestSeriesBudgetBoundForSixDenseSameTimestampPoints(t *testing.T) {
	rows := []Sample{}
	ids := []string{}
	for p := 0; p < 6; p++ {
		id := fmt.Sprintf("p%d", p)
		ids = append(ids, id)
		for i := 0; i < 1200; i++ {
			rows = append(rows, seriesFixture(id, 0, float64(i)))
		}
	}
	s := seriesStore(t, rows)
	got, err := s.Series(context.Background(), Filter{PointIDs: ids}, 20)
	if err != nil {
		t.Fatal(err)
	}
	if got.Count != 7200 || got.Returned > 120 || len(got.Summaries) != 6 {
		t.Fatalf("unbounded result count=%d returned=%d groups=%d", got.Count, got.Returned, len(got.Summaries))
	}
	for _, s := range got.Summaries {
		if *s.Min != 0 || *s.Max != 1199 || *s.Mean != 599.5 || s.Count != 1200 {
			t.Fatalf("summary incomplete %+v", s)
		}
	}
}

func TestSeriesRejectsUnboundedGroupsAndInvalidSelection(t *testing.T) {
	rows := make([]Sample, 257)
	for i := range rows {
		rows[i] = seriesFixture("p", i, 1.0)
		rows[i].Version = fmt.Sprintf("v%d", i)
	}
	s := seriesStore(t, rows)
	_, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err == nil || !strings.Contains(err.Error(), "narrow the time range") {
		t.Fatalf("group overflow silently truncated: %v", err)
	}
	for _, f := range []Filter{{}, {PointID: "p", PointIDs: []string{"p"}}, {PointIDs: []string{"p", "p"}}, {PointIDs: []string{""}}, {PointIDs: []string{"p", "q", "r", "s", "t", "u", "v"}}, {PointID: "p", From: 2, To: 1}, {PointID: "p", Before: -2}} {
		if _, err := s.Series(context.Background(), f, 600); err == nil {
			t.Fatalf("accepted %+v", f)
		}
	}
	for _, budget := range []int{0, 19, 601} {
		if _, err := s.Series(context.Background(), Filter{PointID: "p"}, budget); err == nil {
			t.Fatalf("accepted budget %d", budget)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.Series(ctx, Filter{PointID: "p"}, 600); err == nil {
		t.Fatal("ignored cancellation")
	}
}

func TestSeriesEmptyBoundaryRemainsEmptyAfterAppend(t *testing.T) {
	s := seriesStore(t, nil)
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err != nil {
		t.Fatal(err)
	}
	if got.Before != -1 || got.Boundary != -1 || got.Count != 0 || got.Items == nil || got.Summaries == nil {
		t.Fatalf("bad empty snapshot %+v", got)
	}
	if err := s.Append(context.Background(), []Sample{seriesFixture("p", 0, 1.0)}); err != nil {
		t.Fatal(err)
	}
	got, err = s.Series(context.Background(), Filter{PointID: "p", Before: got.Before}, 600)
	if err != nil || got.Count != 0 {
		t.Fatalf("empty boundary moved %+v %v", got, err)
	}
}

func TestSeriesMeanRemainsFiniteForExtremeFiniteValues(t *testing.T) {
	s := seriesStore(t, []Sample{seriesFixture("p", 0, math.MaxFloat64), seriesFixture("p", 1, math.MaxFloat64), seriesFixture("p", 2, -math.MaxFloat64), seriesFixture("p", 3, -math.MaxFloat64)})
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err != nil {
		t.Fatal(err)
	}
	mean := *got.Summaries[0].Mean
	if math.IsInf(mean, 0) || math.IsNaN(mean) || math.Abs(mean) > math.MaxFloat64*1e-15 {
		t.Fatalf("overflow mean %g", mean)
	}
	if _, err := json.Marshal(got); err != nil {
		t.Fatalf("nonserializable statistics: %v", err)
	}
}

func TestSeriesDeadlineBoundsWaitingForDatabase(t *testing.T) {
	s := seriesStore(t, nil)
	conn, err := s.DB.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err = s.Series(ctx, Filter{PointID: "p"}, 600)
	if err != context.DeadlineExceeded {
		t.Fatalf("did not honor caller deadline: %v", err)
	}
}

func TestSeriesRetainsBriefFrozenSemanticGroupsAndTheirExtrema(t *testing.T) {
	rows := make([]Sample, 4000)
	for i := range rows {
		rows[i] = seriesFixture("p", i, float64(i%10))
	}
	rows[1255].Unit = "psi"
	rows[1255].Version = "v2"
	rows[1777].Station = "B"
	rows[1777].Version = "v3"
	s := seriesStore(t, rows)
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 600)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[int64]bool{}
	for _, r := range got.Items {
		seen[r.Seq] = true
	}
	if !seen[1256] || !seen[1778] || got.Returned > 600 || len(got.Summaries) != 3 {
		t.Fatalf("silently lost semantic group: seq1256=%v seq1778=%v returned=%d summaries=%d", seen[1256], seen[1778], got.Returned, len(got.Summaries))
	}
	for i, r := range got.Items {
		if r.Seq == 1256 || r.Seq == 1778 {
			if !r.BreakBefore || i+1 >= len(got.Items) || !got.Items[i+1].BreakBefore {
				t.Fatalf("joined frozen group boundaries: %+v", r)
			}
		}
	}
}

func TestSeriesRejectsBudgetThatCannotRepresentEveryFrozenGroup(t *testing.T) {
	rows := []Sample{}
	for v := 0; v < 5; v++ {
		for i := 0; i < 20; i++ {
			r := seriesFixture("p", v*20+i, float64(i))
			r.Version = fmt.Sprintf("v%d", v)
			rows = append(rows, r)
		}
	}
	s := seriesStore(t, rows)
	if _, err := s.Series(context.Background(), Filter{PointID: "p"}, 20); err == nil || !strings.Contains(err.Error(), "increase max_points") {
		t.Fatalf("silently dropped semantics: %v", err)
	}
	got, err := s.Series(context.Background(), Filter{PointID: "p"}, 25)
	if err != nil {
		t.Fatal(err)
	}
	if got.Returned > 25 || len(got.Summaries) != 5 {
		t.Fatalf("group budget failed: %+v", got)
	}
	seen := map[string]bool{}
	for _, r := range got.Items {
		seen[r.Version] = true
	}
	if len(seen) != 5 {
		t.Fatalf("missing plotted groups: %+v", seen)
	}
}

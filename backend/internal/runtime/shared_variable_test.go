package runtime

import (
	"context"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

// Exercise cross-station dependencies through real SQLite writes, using the
// production evaluation/policy scan with an explicit clock and no UI or device.
func TestSharedInputDerivedStationsStoreIndependentHistory(t *testing.T) {
	e, ps := policyFixture(t)
	x := policyPoint(t, ps, "Source", "X", 10000)
	input := func(station, expression string) points.CreateInput {
		return points.CreateInput{Station: station, Name: "derived", DataType: "FLOAT", SourceType: "virtual", Expression: expression, Inputs: []string{x.ID}, Unit: "bar", StaleMS: 10000}
	}
	a, err := ps.Create(input("A", "v[0]*10"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := ps.Create(input("B", "v[0]/10"))
	if err != nil {
		t.Fatal(err)
	}
	policyApply(t, e)
	oldVersion := e.version
	for i, p := range []points.Definition{a, b} {
		if err := e.SetPolicy(p.Station, Policy{Enabled: true, IntervalMS: (i + 1) * 1000, RetentionDays: 7, PointIDs: []string{p.ID}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.SetPolicy("A", Policy{IntervalMS: 1000, RetentionDays: 7, PointIDs: []string{x.ID}}); err == nil {
		t.Fatal("station policy accepted another station's original point")
	}
	base := time.Now().UTC().Truncate(time.Millisecond)
	e.ingest(x, 100.0, "good", base, base)
	evaluateAndDrain(t, e, base)
	assertHistory := func(p points.Definition, values []any, qualities []string) []storage.Sample {
		t.Helper()
		rows, err := e.Store.Query(context.Background(), storage.Filter{Station: p.Station})
		if err != nil || len(rows) != len(values) {
			t.Fatalf("station %s: rows=%+v, err=%v, want %d", p.Station, rows, err, len(values))
		}
		for i, r := range rows {
			if r.PointID != p.ID || r.Station != p.Station || r.Value != values[i] || r.Quality != qualities[i] || r.Unit != "bar" {
				t.Fatalf("station %s row %d: %+v", p.Station, i, r)
			}
		}
		return rows
	}
	assertHistory(a, []any{1000.0}, []string{"good"})
	assertHistory(b, []any{10.0}, []string{"good"})
	at := base.Add(time.Second)
	e.ingest(x, 200.0, "good", at, at)
	evaluateAndDrain(t, e, at)
	assertHistory(a, []any{1000.0, 2000.0}, []string{"good", "good"})
	assertHistory(b, []any{10.0}, []string{"good"})
	if e.live[x.ID].Value != 200.0 || e.live[b.ID].Value != 20.0 {
		t.Fatal("derived values changed the original or failed to update live")
	}
	evaluateAndDrain(t, e, base.Add(2*time.Second))
	assertHistory(b, []any{10.0, 20.0}, []string{"good", "good"})
	at = base.Add(3 * time.Second)
	e.ingest(x, 200.0, "bad", at, at)
	evaluateAndDrain(t, e, at)
	evaluateAndDrain(t, e, base.Add(4*time.Second))
	assertHistory(a, []any{1000.0, 2000.0, 2000.0, nil, nil}, []string{"good", "good", "good", "bad", "bad"})
	assertHistory(b, []any{10.0, 20.0, nil}, []string{"good", "good", "bad"})
	if _, err := ps.Update(a.ID, input("A", "v[0]*20")); err != nil {
		t.Fatal(err)
	}
	policyApply(t, e)
	at = base.Add(6 * time.Second)
	e.ingest(x, 100.0, "good", at, at)
	evaluateAndDrain(t, e, at)
	rows := assertHistory(a, []any{1000.0, 2000.0, 2000.0, nil, nil, 2000.0}, []string{"good", "good", "good", "bad", "bad", "good"})
	if rows[0].Version != oldVersion || rows[5].Version == oldVersion || rows[5].Version != e.version || !rows[0].SourceTime.Equal(base) {
		t.Fatal("formula change lost frozen historical version or source time")
	}
	assertHistory(b, []any{10.0, 20.0, nil, 10.0}, []string{"good", "good", "bad", "good"})
	rows, err = e.Store.Query(context.Background(), storage.Filter{PointID: x.ID})
	if err != nil || len(rows) != 0 {
		t.Fatal("referencing the original unexpectedly enabled its storage")
	}
}

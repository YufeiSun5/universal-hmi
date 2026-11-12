package totalreports

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"testing"
	"time"
)

type counterFixture struct {
	calls  int
	values []externaldata.CounterReading
	during func()
}

func (c *counterFixture) Screens(context.Context) ([]externaldata.Screen, error) {
	return []externaldata.Screen{{ID: "source", Kind: "standard"}}, nil
}
func (c *counterFixture) DailyCounters(_ context.Context, source, from, to string, bindings []externaldata.CounterBinding) ([]externaldata.CounterReading, error) {
	c.calls++
	if c.during != nil {
		c.during()
	}
	return c.values, nil
}
func TestHeatSyncPreservesFormulaAndCachesAutomaticReads(t *testing.T) {
	s, ctx := fixture(t)
	tpl := testTemplate()
	tpl.Kind = "heat"
	for i := range tpl.Daily {
		tpl.Daily[i].Editable = false
	}
	tpl.Bindings = []HeatBinding{{Column: 3, Station: "zone", Point: "ER_TotalHeat", Unit: "GJ"}}
	if e := s.SaveTemplate(ctx, tpl); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	value := "0.00000000"
	reader := &counterFixture{values: []externaldata.CounterReading{{Station: "zone", Point: "ER_TotalHeat", Date: "2026-11-05", Value: &value}}}
	s.SetCounterReader(reader)
	if _, e = s.Acquire(ctx, "heat", 2026, LeaseRequest{Client: "formula-editor", Addresses: []string{"E4"}}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Patch(ctx, "heat", 2026, Patch{ID: "formula-change", Client: "formula-editor", Changes: []Change{{"E4", "=SUM(D4)-SUM(D3)", 0, nil}}}); e != nil {
		t.Fatal(e)
	}
	in := HeatSync{From: "2026-11-05", To: "2026-11-05", Auto: true}
	got, e := s.SyncHeat(ctx, 2026, in)
	if e != nil || got.Valid != 1 || got.Changed != 1 {
		t.Fatal(got, e)
	}
	if _, e = s.SyncHeat(ctx, 2026, in); e != nil || reader.calls != 1 {
		t.Fatal("uncached automatic read", reader.calls, e)
	}
	reader.values[0].Value = nil
	in.Auto = false
	got, e = s.SyncHeat(ctx, 2026, in)
	if e != nil || got.Valid != 0 || got.Changed != 1 {
		t.Fatal(got, e)
	}
	d, e = s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	values := map[string]string{}
	for _, c := range d.Cells {
		values[c.Address] = c.Value
	}
	if values["D3"] != "" || values["E4"] != "=SUM(D4)-SUM(D3)" {
		t.Fatal(values["D3"], values["E4"])
	}
	now := s.now()
	s.now = func() time.Time { return now.Add(6 * time.Minute) }
	in.Auto = true
	if _, e = s.SyncHeat(ctx, 2026, in); e != nil || reader.calls != 3 {
		t.Fatal(reader.calls, e)
	}
	reader.during = func() {
		if _, e = s.SaveHeatSettings(ctx, HeatSettings{Screen: "source"}); e != nil {
			t.Fatal(e)
		}
	}
	in.Auto = false
	if _, e = s.SyncHeat(ctx, 2026, in); e != ErrConflict {
		t.Fatal("changed source accepted", e)
	}
}

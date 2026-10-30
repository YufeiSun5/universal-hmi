package equipment

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"math"
	"testing"
)

func TestSignalPriorityAndInvalidInputs(t *testing.T) {
	fault := &Signal{"f", "x != 0"}
	running := &Signal{"r", "x >= 0.5 && x <= 100"}
	for _, tt := range []struct {
		name         string
		signals      Signals
		f, r         any
		fq, rq, want string
	}{
		{"unconfigured", Signals{}, nil, nil, "", "", "unconfigured"},
		{"fault priority", Signals{fault, running}, true, nil, "good", "bad", "fault"},
		{"running range", Signals{fault, running}, false, 35.2, "good", "good", "running"},
		{"stopped low", Signals{fault, running}, false, 0.1, "good", "good", "stopped"},
		{"stopped high", Signals{nil, running}, nil, 101.0, "", "good", "stopped"},
		{"range boundary", Signals{nil, running}, nil, 0.5, "", "good", "running"},
		{"bad fault cannot infer running", Signals{fault, running}, nil, 35.0, "bad", "good", "unknown"},
		{"fault only clear", Signals{Fault: fault}, false, nil, "good", "", "unknown"},
		{"fault only triggered", Signals{Fault: fault}, true, nil, "good", "", "fault"},
		{"missing", Signals{Running: running}, nil, nil, "", "missing", "unknown"},
		{"stale", Signals{Running: running}, nil, 35.0, "", "stale", "unknown"},
		{"offline", Signals{Running: running}, nil, 35.0, "", "offline", "unknown"},
		{"string", Signals{Running: running}, nil, "35", "", "good", "unknown"},
		{"nonfinite", Signals{Running: running}, nil, math.Inf(1), "", "good", "unknown"},
		{"divide zero", Signals{Running: &Signal{"r", "x / (x - x) > 1"}}, nil, 2.0, "", "good", "unknown"},
		{"bool run", Signals{Running: &Signal{"r", "x == 1"}}, nil, true, "", "good", "running"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, _ := evaluateSignals(tt.signals, map[string]storage.Sample{"f": {Value: tt.f, Quality: tt.fq}, "r": {Value: tt.r, Quality: tt.rq}})
			if got != tt.want {
				t.Fatalf("got %s want %s", got, tt.want)
			}
		})
	}
	state, _ := evaluateSignals(Signals{fault, running}, map[string]storage.Sample{"f": {Value: true, Quality: "good"}})
	if state != "unknown" {
		t.Fatal("hidden running reference exposed a derived state", state)
	}
	for _, s := range []string{"x", "true", "x > 0; x < 4", "len(x) > 0", "x[0] > 0", "x ** 2 > 0", "x > 1 && 2", "x > 1e999", "y > 1"} {
		if _, err := compileCondition(s); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
	for _, s := range []string{"x != 0", "!(x < 0) && (x * 2 + 1) / 3 >= 1", "x == 0 || x > 10"} {
		if _, err := compileCondition(s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
}

type signalPorts struct {
	calls int
	ids   []string
}

func (p *signalPorts) Visible(context.Context) ([]points.Definition, error) {
	return []points.Definition{{ID: "r", Station: "A", DataType: "FLOAT"}}, nil
}
func (p *signalPorts) ReadPointsFor(_ context.Context, ids []string) (map[string]storage.Sample, error) {
	p.calls++
	p.ids = ids
	return map[string]storage.Sample{"r": {Value: 3.0, Quality: "good"}}, nil
}
func TestStatusPersistenceScopeAndRevision(t *testing.T) {
	repo := &memory{}
	p := &signalPorts{}
	dir := t.TempDir()
	stations := func() ([]string, error) { return []string{"A", "B"}, nil }
	s, err := Open(repo, dir, stations, StatusPorts{p, p})
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.Save(actor("A", true), Device{Station: "A", Name: "pump", Code: "P1", Category: "水泵", Signals: Signals{Running: &Signal{"r", "x > 1"}}})
	if err != nil {
		t.Fatal(err)
	}
	s, err = Open(repo, dir, stations, StatusPorts{p, p})
	if err != nil {
		t.Fatal(err)
	}
	result, err := s.Statuses(actor("A", false), []string{d.ID})
	if err != nil || len(result) != 1 || result[0].State != "running" || result[0].Revision != d.Revision || p.calls != 1 {
		t.Fatal(result, err)
	}
	visible, err := s.Get(actor("A", false), d.ID)
	if err != nil || visible.Signals.Running != nil {
		t.Fatal("runtime exposed config", visible, err)
	}
	if _, err = s.Statuses(actor("B", false), []string{d.ID}); err != ErrMissing {
		t.Fatal(err)
	}
	if p.calls != 1 {
		t.Fatal("unauthorized query read inputs")
	}
	reads := repo.reads
	if _, err = s.Statuses(actor("A", false), []string{d.ID}); err != nil || repo.reads != reads {
		t.Fatal("status query reread full register", err)
	}
	repo.fail = true
	changed := d
	changed.Signals = Signals{}
	if _, err = s.Save(actor("A", true), changed); err == nil {
		t.Fatal("save should fail")
	}
	result, err = s.Statuses(actor("A", false), []string{d.ID})
	if err != nil || result[0].State != "running" {
		t.Fatal("failed save invalidated durable state", result, err)
	}
	repo.fail = false
	if _, err = s.Save(actor("A", false), d); err == nil {
		t.Fatal("viewer edited binding")
	}
	d.Signals.Running.PointID = "hidden"
	if _, err = s.Save(actor("A", true), d); err == nil {
		t.Fatal("invalid reference saved")
	}
	d.Signals = Signals{}
	d, err = s.Save(actor("A", true), d)
	if err != nil {
		t.Fatal(err)
	}
	result, err = s.Statuses(actor("A", false), []string{d.ID})
	if err != nil || result[0].State != "unconfigured" {
		t.Fatal(result, err)
	}
	if _, err = s.Statuses(actor("A", false), make([]string, 101)); err == nil {
		t.Fatal("accepted unbounded selection")
	}
}

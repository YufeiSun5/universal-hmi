package runtime

import (
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestVirtualRecoversFromInvalidEvaluationBeforeDelayedInputs(t *testing.T) {
	for _, initialQuality := range []string{"missing", "bad"} {
		t.Run(initialQuality, func(t *testing.T) {
			e, ps := setup(t)
			a := point(t, ps, "a", false)
			b := point(t, ps, "b", false)
			output := point(t, ps, "output", true)
			average, err := ps.Create(points.CreateInput{Station: "IO-01", Name: "average", DataType: "FLOAT", SourceType: "virtual", Expression: "(v[0]+v[1])/2", Inputs: []string{a.ID, b.ID}, StaleMS: 10000})
			if err != nil {
				t.Fatal(err)
			}
			chained, err := ps.Create(points.CreateInput{Station: "IO-01", Name: "chained", DataType: "FLOAT", SourceType: "virtual", Expression: "v[0]+1", Inputs: []string{average.ID}, StaleMS: 10000})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := e.Apply(); err != nil {
				t.Fatal(err)
			}
			rule := Rule{ID: "physical-input-rule", Name: "physical inputs", Enabled: true, Logic: "and", Conditions: []Condition{{a.ID, ">", 40}, {b.ID, ">=", 50}}, HoldMS: 200, CooldownMS: 1000, Trigger: "rising", Actions: []Action{{"write", output.ID, 66}}}
			if err := e.SetRules([]Rule{rule}); err != nil {
				t.Fatal(err)
			}
			e.mu.Lock()
			defer e.mu.Unlock()
			// The good source sample is generated before the invalid evaluation,
			// but arrives afterwards, as can happen in the MQTT queue.
			base := time.Now().UTC().Add(-2 * time.Second)
			if initialQuality == "bad" {
				e.ingest(a, 21.0, "bad", base, base)
				e.ingest(b, 22.0, "bad", base, base)
			}
			e.evaluate(base.Add(200 * time.Millisecond))
			for _, p := range []points.Definition{average, chained} {
				if sample := e.live[p.ID]; sample.Quality != "bad" || sample.Value != nil {
					t.Fatalf("invalid input produced a valid virtual sample: %+v", sample)
				}
			}
			if _, exists := e.live[output.ID]; exists {
				t.Fatal("invalid inputs triggered the rule")
			}
			source := base.Add(100 * time.Millisecond)
			received := base.Add(300 * time.Millisecond)
			e.ingest(a, 21.0, "good", source, received)
			e.ingest(b, 22.0, "good", source.Add(50*time.Millisecond), received)
			e.evaluate(received)
			e.evaluate(received.Add(200 * time.Millisecond))
			if sample := e.live[output.ID]; sample.Value != 66.0 {
				t.Fatalf("physical-input rule did not execute: %+v", sample)
			}
			for i, p := range []points.Definition{average, chained} {
				sample := e.live[p.ID]
				if sample.Quality != "good" || sample.Value != 53.0+float64(i) || !sample.SourceTime.Equal(source) {
					t.Errorf("rule executed but virtual did not recover with the oldest input time: %+v", sample)
				}
			}
		})
	}
}

func TestVirtualInvalidationAndRecoveryPreservePhysicalOrderingAndFreshness(t *testing.T) {
	for _, invalidQuality := range []string{"bad-first", "bad-second", "stale"} {
		t.Run(invalidQuality, func(t *testing.T) {
			e, ps := setup(t)
			a := point(t, ps, "a", false)
			b := point(t, ps, "b", false)
			average, err := ps.Create(points.CreateInput{Station: "IO-01", Name: "average", DataType: "FLOAT", SourceType: "virtual", Expression: "(v[0]+v[1])/2", Inputs: []string{a.ID, b.ID}, StaleMS: 10000})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := e.Apply(); err != nil {
				t.Fatal(err)
			}
			e.mu.Lock()
			defer e.mu.Unlock()
			base := time.Now().UTC().Add(-20 * time.Second)
			e.ingest(a, 21.0, "good", base, base)
			e.ingest(b, 22.0, "good", base.Add(50*time.Millisecond), base.Add(50*time.Millisecond))
			e.evaluate(base.Add(100 * time.Millisecond))
			if sample := e.live[average.ID]; sample.Quality != "good" || sample.Value != 53.0 || !sample.SourceTime.Equal(base) {
				t.Fatalf("initial virtual sample: %+v", sample)
			}
			invalidAt := base.Add(11 * time.Second)
			if invalidQuality != "stale" {
				invalidAt = base.Add(2 * time.Second)
				invalid := a
				if invalidQuality == "bad-second" {
					invalid = b
				}
				e.ingest(invalid, 21.0, "bad", base.Add(500*time.Millisecond), invalidAt)
			}
			e.evaluate(invalidAt)
			if sample := e.live[average.ID]; sample.Quality != "bad" || sample.Value != nil {
				t.Fatalf("%s input failed to invalidate virtual: %+v", invalidQuality, sample)
			}
			// Both fresh inputs predate the invalid calculation; the second is
			// older, so preserving only the first input's time is also wrong.
			source := invalidAt.Add(-time.Second)
			received := invalidAt.Add(time.Second)
			e.ingest(a, 31.0, "good", source.Add(100*time.Millisecond), received)
			e.ingest(b, 32.0, "good", source, received)
			e.evaluate(received)
			if sample := e.live[average.ID]; sample.Quality != "good" || sample.Value != 73.0 || !sample.SourceTime.Equal(source) {
				t.Fatalf("virtual did not recover with oldest input freshness: %+v", sample)
			}
			if accepted := e.ingest(a, 99.0, "good", base, received); accepted || e.live[a.ID].Raw != 31.0 {
				t.Fatal("recovery allowed an out-of-order physical input to overwrite the latest sample")
			}
			e.evaluate(received.Add(time.Second))
			if sample := e.live[average.ID]; sample.Value != 73.0 || !sample.SourceTime.Equal(source) {
				t.Fatalf("reevaluation changed the value or refreshed its source time: %+v", sample)
			}
			if e.good(average.ID, source.Add(10001*time.Millisecond)) {
				t.Fatal("recovered virtual remained fresh beyond its oldest input")
			}
		})
	}
}

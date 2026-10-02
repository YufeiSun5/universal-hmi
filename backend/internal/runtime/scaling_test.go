package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestReadScalingOffsetAndTypeValidation(t *testing.T) {
	for _, tt := range []struct {
		name, kind    string
		raw           any
		scale, offset float64
		want          any
		good          bool
	}{
		{"identity", "FLOAT", 12.5, 1, 0, 12.5, true},
		{"positive", "FLOAT", 21.0, 2, 10, 52.0, true},
		{"negative", "FLOAT", 4.0, -2, 10, 2.0, true},
		{"fractional", "FLOAT", -3.0, .25, -1.5, -2.25, true},
		{"numeric_string", "FLOAT", "4.5", 2, -1, 8.0, true},
		{"scaled_integer_fractional_engineering", "INT", 3.0, .25, .125, .875, true},
		{"negative_integer", "INT", -4.0, -2, 1, 9.0, true},
		{"fractional_raw_integer", "INT", 1.5, 2, 0, nil, false},
		{"unsafe_integer", "INT", 9007199254740992.0, 1, 0, nil, false},
		{"negative_unsafe_integer", "INT", -9007199254740992.0, 1, 0, nil, false},
		{"largest_exact_integer", "INT", 9007199254740991.0, 1, 0, 9007199254740991.0, true},
		{"overflow", "FLOAT", math.MaxFloat64, 2, 0, nil, false},
		{"nan", "FLOAT", math.NaN(), 1, 0, nil, false},
		{"infinity", "FLOAT", math.Inf(1), 1, 0, nil, false},
		{"nan_string", "FLOAT", "NaN", 1, 0, nil, false},
		{"missing", "FLOAT", nil, 1, 0, nil, false},
		{"invalid_string", "FLOAT", "invalid", 1, 0, nil, false},
		{"boolean_true", "BOOL", true, 1, 0, true, true},
		{"boolean_zero", "BOOL", 0.0, 1, 0, false, true},
		{"boolean_one", "BOOL", "1", 1, 0, true, true},
		{"boolean_invalid", "BOOL", 2.0, 1, 0, nil, false},
		{"string", "STRING", "status", 1, 0, "status", true},
		{"string_invalid", "STRING", 2.0, 1, 0, nil, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := &Engine{live: map[string]storage.Sample{}, version: "test-version"}
			p := points.Definition{ID: "point", Station: "A", Name: tt.name, DataType: tt.kind, ScaleFactor: tt.scale, Offset: tt.offset, Unit: "unit"}
			now := time.Now().UTC()
			good := e.ingest(p, tt.raw, "good", now, now)
			sample := e.live[p.ID]
			if good != tt.good || sample.Value != tt.want {
				t.Fatalf("read %v * %g + %g: good=%v value=%v; want good=%v value=%v", tt.raw, tt.scale, tt.offset, good, sample.Value, tt.good, tt.want)
			}
			wantQuality := "bad"
			if tt.good {
				wantQuality = "good"
			}
			if sample.Quality != wantQuality {
				t.Fatalf("quality=%s want=%s", sample.Quality, wantQuality)
			}
			wantRaw := tt.raw
			if number, ok := tt.raw.(float64); ok && (math.IsNaN(number) || math.IsInf(number, 0)) {
				wantRaw = fmt.Sprint(number)
			}
			if sample.Raw != wantRaw {
				t.Fatalf("raw value changed: got=%v want=%v", sample.Raw, wantRaw)
			}
			if sample.PointID != p.ID || sample.Unit != p.Unit || sample.Version != e.version || sample.SourceTime != now || sample.ReceivedTime != now {
				t.Fatalf("conversion lost sample metadata: %+v", sample)
			}
		})
	}
}

func TestWriteScalingOffsetAndRepresentability(t *testing.T) {
	for _, tt := range []struct {
		name, kind                string
		scale, offset, value, raw float64
		wantErr                   bool
	}{
		{"positive", "FLOAT", 2, 10, 70, 30, false},
		{"negative", "FLOAT", -2, 10, 2, 4, false},
		{"fractional", "FLOAT", .25, -1.5, -2.25, -3, false},
		{"integer_decimal", "INT", .1, 0, 1.2, 12, false},
		{"integer_decimal_offset", "INT", .1, -17, 12345661.9, 123456789, false},
		{"integer_negative", "INT", -.25, 1.5, 2.25, -3, false},
		{"boolean_zero", "BOOL", 1, 0, 0, 0, false},
		{"boolean_one", "BOOL", 1, 0, 1, 1, false},
		{"boolean_fraction", "BOOL", 1, 0, .5, 0, true},
		{"boolean_two", "BOOL", 1, 0, 2, 0, true},
		{"integer_fractional_raw", "INT", 2, 10, 11, 0, true},
		{"large_identity_fraction", "INT", 1, 0, 1000000000000000.25, 0, true},
		{"large_negative_identity_fraction", "INT", 1, 0, -1000000000000000.25, 0, true},
		{"large_binary_factor_fraction", "INT", 4, 0, 4000000000000001, 0, true},
		{"large_negative_binary_factor_fraction", "INT", -4, 0, -4000000000000001, 0, true},
		{"large_binary_factor_offset_fraction", "INT", .25, .125, 250000000000000.1875, 0, true},
		{"large_negative_binary_factor_offset_fraction", "INT", .25, -.125, -250000000000000.1875, 0, true},
		{"integer_near_zero_not_roundoff", "INT", 1e12, 0, 100, 0, true},
		{"integer_offset_must_not_hide_fraction", "INT", 1, 1e12, math.Nextafter(1e12, math.Inf(1)), 0, true},
		{"integer_offset_must_not_hide_residual", "INT", 1, 1e12, math.Nextafter(1e12+1, math.Inf(1)), 0, true},
		{"integer_safe_max", "INT", 1, 0, 9007199254740991, 9007199254740991, false},
		{"integer_unsafe", "INT", 1, 0, 9007199254740992, 0, true},
		{"inverse_overflow", "FLOAT", .5, 0, math.MaxFloat64, 0, true},
		{"inverse_underflow", "FLOAT", 1e300, 0, 1e-100, 0, true},
		{"offset_cancellation", "FLOAT", 1, 1e16, 1, 0, true},
		{"integer_exact_decimal_severe_cancellation", "INT", 5, 1e16, 5, 0, true},
		{"integer_negative_exact_decimal_severe_cancellation", "INT", 5, -1e16, -5, 0, true},
		{"nan", "FLOAT", 1, 0, math.NaN(), 0, true},
		{"infinite", "FLOAT", 1, 0, math.Inf(1), 0, true},
		{"smallest_float", "FLOAT", 1, 0, math.SmallestNonzeroFloat64, math.SmallestNonzeroFloat64, false},
		{"largest_float", "FLOAT", 1, 0, math.MaxFloat64, math.MaxFloat64, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e, ps := setup(t)
			p, err := ps.Create(points.CreateInput{Station: "A", Name: tt.name, DataType: tt.kind, SourceType: "manual", ScaleFactor: &tt.scale, Offset: tt.offset, Writable: true})
			if err != nil {
				t.Fatal(err)
			}
			version, err := e.Apply()
			if err != nil {
				t.Fatal(err)
			}
			id := "scaling-" + tt.name
			r, err := e.Write(Write{CommandID: id, PointID: p.ID, Version: version, Value: tt.value})
			if (err != nil) != tt.wantErr {
				t.Fatalf("result=%+v error=%v; want error=%v", r, err, tt.wantErr)
			}
			e.mu.Lock()
			sample, exists := e.live[p.ID]
			e.mu.Unlock()
			if tt.wantErr {
				if exists {
					t.Fatalf("rejected write changed runtime: %+v", sample)
				}
				if _, err := e.Command(id); err == nil {
					t.Fatal("rejected write persisted an intent")
				}
				return
			}
			if !exists || sample.Raw != tt.raw || sample.Quality != "good" || r.State != "readback_confirmed" {
				t.Fatalf("incorrect inverse or local confirmation: sample=%+v result=%+v", sample, r)
			}
			want := any(tt.value)
			if tt.kind == "BOOL" {
				want = tt.value == 1
			}
			if got, ok := sample.Value.(float64); ok {
				if math.Abs(got-tt.value) > 1e-14*math.Abs(tt.value) {
					t.Fatalf("round trip=%g request=%g", got, tt.value)
				}
			} else if sample.Value != want {
				t.Fatalf("round trip=%v request=%v", sample.Value, want)
			}
		})
	}
}

func TestScaledReadbackMatchesRawCommandWithoutOffsetTolerance(t *testing.T) {
	for _, tt := range []struct {
		name, kind                                     string
		scale, offset, requested, wrongRaw, correctRaw float64
	}{
		{"large_offset_integer", "INT", 1, 1e12, 1e12 + 1, 2, 1},
		{"large_offset_float", "FLOAT", 1, 1e12, 1e12 + 1, 2, 1},
		{"tiny_scale", "FLOAT", 1e-12, 0, 1e-12, 0, 1},
		{"negative_factor", "INT", -2, 1e12, 1e12 - 2, 2, 1},
		{"large_integer", "INT", 1, 0, 1e12, 1e12 + 1, 1e12},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e, ps := setup(t)
			p, err := ps.Create(points.CreateInput{Station: "A", Name: tt.name, DataType: tt.kind, SourceType: "mqtt", SourceID: "source", SourcePath: "path", Topic: "topic", ScaleFactor: &tt.scale, Offset: tt.offset})
			if err != nil {
				t.Fatal(err)
			}
			version, err := e.Apply()
			if err != nil {
				t.Fatal(err)
			}
			published := time.Now().Add(-time.Second)
			id := "scaled-readback-" + tt.name
			e.mu.Lock()
			defer e.mu.Unlock()
			e.pending[id] = &pendingWrite{Target: p, Result: Result{CommandID: id, PointID: p.ID, Value: tt.requested, Version: version, State: "acknowledged", At: published.Add(-time.Second), PublishedAt: &published}}
			now := time.Now()
			raw := acquisition.Raw{SourceID: "source", Topic: "topic", Path: "path", Value: tt.wrongRaw, Quality: "good", Time: now}
			e.observeReadbackLocked(p, raw, now)
			if e.pending[id] == nil {
				t.Fatal("different raw value falsely confirmed command")
			}
			raw.Value = tt.correctRaw
			e.observeReadbackLocked(p, raw, now)
			if e.pending[id] != nil {
				t.Fatal("matching raw value did not confirm command")
			}
		})
	}
}

func TestScalingSaveApplyAndHistoryRemainSeparate(t *testing.T) {
	e, ps := setup(t)
	scale := 2.0
	in := points.CreateInput{Station: "A", Name: "scaled", DataType: "FLOAT", SourceType: "manual", Unit: "old", ScaleFactor: &scale, Offset: 10, Writable: true}
	p, err := ps.Create(in)
	if err != nil {
		t.Fatal(err)
	}
	oldVersion, err := e.Apply()
	if err != nil {
		t.Fatal(err)
	}
	if err = e.Manual(p.ID, 4.0); err != nil {
		t.Fatal(err)
	}
	if err = e.SnapshotStation("A"); err != nil {
		t.Fatal(err)
	}
	scale, in.Offset, in.Unit = -3, -2, "new"
	if _, err = ps.Update(p.ID, in); err != nil {
		t.Fatal(err)
	}
	if err = e.Manual(p.ID, 5.0); err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	before := e.live[p.ID]
	e.mu.Unlock()
	if before.Value != 20.0 || before.Version != oldVersion || before.Unit != "old" {
		t.Fatalf("saved draft changed active conversion: %+v", before)
	}
	newVersion, err := e.Apply()
	if err != nil {
		t.Fatal(err)
	}
	if oldVersion == newVersion {
		t.Fatal("conversion activation kept previous version")
	}
	if _, err = e.Write(Write{CommandID: "old-scaling-version", PointID: p.ID, Value: 20, Version: oldVersion}); err == nil {
		t.Fatal("old conversion version accepted")
	}
	if err = e.Manual(p.ID, 4.0); err != nil {
		t.Fatal(err)
	}
	if err = e.SnapshotStation("A"); err != nil {
		t.Fatal(err)
	}
	rows, err := e.Store.Query(context.Background(), storage.Filter{PointID: p.ID})
	if err != nil || len(rows) != 2 {
		t.Fatalf("history=%+v error=%v", rows, err)
	}
	seen := map[string]bool{}
	for _, row := range rows {
		key := fmt.Sprintf("%v/%v/%s/%s", row.Raw, row.Value, row.Unit, row.Version)
		seen[key] = true
	}
	if !seen["4/18/old/"+oldVersion] || !seen["4/-14/new/"+newVersion] {
		t.Fatalf("historical conversion changed: %+v", rows)
	}
}

func TestNegativeScalingUsesEngineeringRangeInclusively(t *testing.T) {
	e, ps := setup(t)
	scale, min, max := -2.0, -10.0, 10.0
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "range", DataType: "FLOAT", SourceType: "manual", Writable: true, ScaleFactor: &scale, Offset: 4, Min: &min, Max: &max})
	if err != nil {
		t.Fatal(err)
	}
	version, err := e.Apply()
	if err != nil {
		t.Fatal(err)
	}
	for i, tt := range []struct {
		engineering, raw float64
		valid            bool
	}{
		{-10, 7, true}, {10, -3, true}, {-10.001, 0, false}, {10.001, 0, false},
	} {
		r, err := e.Write(Write{CommandID: fmt.Sprintf("range-write-%d", i), PointID: p.ID, Version: version, Value: tt.engineering})
		if (err == nil) != tt.valid {
			t.Fatalf("engineering range %g: result=%+v error=%v", tt.engineering, r, err)
		}
		if tt.valid {
			e.mu.Lock()
			sample := e.live[p.ID]
			e.mu.Unlock()
			if sample.Raw != tt.raw {
				t.Fatalf("inverse=%v want=%g", sample.Raw, tt.raw)
			}
		}
	}
}

func TestIntegerScalingRoundTripAcrossMagnitudes(t *testing.T) {
	for _, scale := range []float64{1, -1, .1, -.25, .3, 2, 1000} {
		for _, offset := range []float64{0, -17, .125} {
			for _, raw := range []float64{0, 1, -1, 12, -73, 123456789, -123456789, 1e12} {
				p := points.Definition{DataType: "INT", ScaleFactor: scale, Offset: offset}
				engineering := float64(raw*scale) + offset
				got, ok := encodeEngineering(p, engineering)
				if !ok || got != raw {
					t.Fatalf("raw=%g factor=%g offset=%g engineering=%g inverse=%g valid=%v", raw, scale, offset, engineering, got, ok)
				}
			}
		}
	}
}

func TestScalingEncoderRejectsUnencodableValues(t *testing.T) {
	// Encoding is the same guard for manual and physical targets, and does not
	// depend on MQTT connectivity. Exercise it directly for dangerous inputs.
	for _, tt := range []struct {
		kind                 string
		scale, offset, value float64
	}{
		{"INT", 1e12, 0, 100},
		{"FLOAT", 1, 1e16, 1},
		{"FLOAT", 1e300, 0, 1e-100},
		{"FLOAT", 0, 0, 1},
		{"FLOAT", math.Inf(1), 0, 1},
		{"FLOAT", 1, math.NaN(), 1},
		{"BOOL", 2, 0, 1},
		{"STRING", 1, 0, 1},
	} {
		if raw, ok := encodeEngineering(points.Definition{DataType: tt.kind, ScaleFactor: tt.scale, Offset: tt.offset}, tt.value); ok {
			t.Fatalf("unencodable %+v accepted as %g", tt, raw)
		}
	}
}

func TestNonFiniteRawKeepsBadQualityAndSerializableDiagnostics(t *testing.T) {
	for _, tt := range []struct {
		name       string
		raw        any
		diagnostic string
	}{
		{"nan", math.NaN(), "NaN"},
		{"positive_infinity", math.Inf(1), "+Inf"},
		{"negative_infinity", math.Inf(-1), "-Inf"},
		{"float32_nan", float32(math.NaN()), "NaN"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e, ps := setup(t)
			p, err := ps.Create(points.CreateInput{Station: "A", Name: tt.name, DataType: "FLOAT", SourceType: "manual"})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = e.Apply(); err != nil {
				t.Fatal(err)
			}
			if err = e.Manual(p.ID, tt.raw); err != nil {
				t.Fatal(err)
			}
			if _, err = json.Marshal(e.Snapshot()); err != nil {
				t.Fatalf("bad raw broke runtime response: %v", err)
			}
			if err = e.SnapshotStation("A"); err != nil {
				t.Fatalf("bad raw broke storage: %v", err)
			}
			rows, err := e.Store.Query(context.Background(), storage.Filter{PointID: p.ID})
			if err != nil || len(rows) != 1 {
				t.Fatalf("history=%+v error=%v", rows, err)
			}
			if rows[0].Raw != tt.diagnostic || rows[0].Value != nil || rows[0].Quality != "bad" {
				t.Fatalf("invalid raw lost diagnostics or became usable: %+v", rows[0])
			}
		})
	}
}

func TestVirtualDivisionByZeroDoesNotBreakRuntimeOrHistory(t *testing.T) {
	for _, tt := range []struct {
		name       string
		input      float64
		diagnostic string
	}{
		{"zero", 0, "NaN"}, {"positive", 1, "+Inf"}, {"negative", -1, "-Inf"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e, ps := setup(t)
			input, err := ps.Create(points.CreateInput{Station: "A", Name: "input", DataType: "FLOAT", SourceType: "manual"})
			if err != nil {
				t.Fatal(err)
			}
			virtual, err := ps.Create(points.CreateInput{Station: "A", Name: "virtual", DataType: "FLOAT", SourceType: "virtual", Expression: "v[0]/0", Inputs: []string{input.ID}})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = e.Apply(); err != nil {
				t.Fatal(err)
			}
			if err = e.Manual(input.ID, tt.input); err != nil {
				t.Fatal(err)
			}
			e.mu.Lock()
			e.evaluate(time.Now())
			e.mu.Unlock()
			if _, err = json.Marshal(e.Snapshot()); err != nil {
				t.Fatalf("virtual division by zero broke runtime response: %v", err)
			}
			if err = e.SnapshotStation("A"); err != nil {
				t.Fatalf("virtual division by zero broke storage: %v", err)
			}
			rows, err := e.Store.Query(context.Background(), storage.Filter{PointID: virtual.ID})
			if err != nil || len(rows) != 1 {
				t.Fatalf("history=%+v error=%v", rows, err)
			}
			if rows[0].Raw != tt.diagnostic || rows[0].Value != nil || rows[0].Quality != "bad" {
				t.Fatalf("invalid virtual result lost diagnostics or became usable: %+v", rows[0])
			}
		})
	}
}

func TestIntegerDecimalZeroCrossingsRemainWritable(t *testing.T) {
	for _, tt := range []struct {
		name               string
		scale, offset, raw float64
	}{
		{"positive_scale_negative_offset", .1, -.3, 3},
		{"positive_scale_six", .1, -.6, 6},
		{"negative_scale_six", -.1, .6, 6},
		{"positive_scale_twelve", .1, -1.2, 12},
		{"positive_scale_positive_offset", .1, .3, -3},
		{"negative_scale_negative_offset", -.1, -.3, -3},
		{"negative_scale_positive_offset", -.1, .3, 3},
		{"hundredths_negative_offset", .01, -.07, 7},
		{"negative_hundredths_positive_offset", -.01, .07, 7},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e, ps := setup(t)
			p, err := ps.Create(points.CreateInput{Station: "A", Name: tt.name, DataType: "INT", SourceType: "manual", ScaleFactor: &tt.scale, Offset: tt.offset, Writable: true})
			if err != nil {
				t.Fatal(err)
			}
			version, err := e.Apply()
			if err != nil {
				t.Fatal(err)
			}
			result, err := e.Write(Write{CommandID: "decimal-zero-" + tt.name, PointID: p.ID, Version: version, Value: 0})
			if err != nil || result.State != "readback_confirmed" {
				t.Fatalf("exact decimal zero was not writable: %+v %v", result, err)
			}
			e.mu.Lock()
			sample := e.live[p.ID]
			e.mu.Unlock()
			// The read path reports the actual float64 forward result, including
			// its tiny decimal residual; it does not invent an exact zero sample.
			wantEngineering := float64(tt.raw*tt.scale) + tt.offset
			if sample.Raw != tt.raw || sample.Value != wantEngineering || sample.Quality != "good" {
				t.Fatalf("incorrect decimal zero encoding/readback: %+v", sample)
			}
		})
	}
}

func TestIntegerDecimalZeroCrossingsAcrossMagnitudes(t *testing.T) {
	for _, sign := range []float64{1, -1} {
		for _, raw := range []float64{1, 3, 6, 12, 99, 123, 999, 10000, 1000000, 123456789, 1e15} {
			p := points.Definition{DataType: "INT", ScaleFactor: .1 * sign, Offset: -raw / 10 * sign}
			got, ok := encodeEngineering(p, 0)
			if !ok || got != raw {
				t.Fatalf("decimal zero raw=%g scale=%g offset=%g inverse=%g valid=%v", raw, p.ScaleFactor, p.Offset, got, ok)
			}
		}
	}
}

func TestScalingRoundsProductBeforeOffsetOnEveryArchitecture(t *testing.T) {
	for _, tt := range []struct {
		name                     string
		raw, scale, offset, want float64
	}{
		{"positive_cancellation", -1999999999999999, 5, 1e16, 4},
		{"negative_cancellation", 1999999999999999, 5, -1e16, -4},
		{"positive_decimal_zero", 123456789, .1, -12345678.9, 0},
		{"negative_decimal_zero", 123456789, -.1, 12345678.9, 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			// These vectors deliberately distinguish rounded multiplication
			// followed by addition from a single-rounding fused operation.
			if fused := math.FMA(tt.raw, tt.scale, tt.offset); fused == tt.want {
				t.Fatalf("test vector does not distinguish FMA: %g", fused)
			}
			if got := engineeringValue(tt.raw, tt.scale, tt.offset); got != tt.want {
				t.Fatalf("conversion fused multiplication and offset: got=%g want=%g", got, tt.want)
			}
			e := &Engine{live: map[string]storage.Sample{}, version: "rounding-contract"}
			p := points.Definition{ID: "point", DataType: "INT", ScaleFactor: tt.scale, Offset: tt.offset}
			now := time.Now().UTC()
			if !e.ingest(p, tt.raw, "good", now, now) || e.live[p.ID].Value != tt.want {
				t.Fatalf("acquisition uses different rounding: %+v", e.live[p.ID])
			}
			if raw, ok := encodeEngineering(p, tt.want); !ok || raw != tt.raw {
				t.Fatalf("write inverse differs from acquisition: raw=%g valid=%v want=%g", raw, ok, tt.raw)
			}
		})
	}
}

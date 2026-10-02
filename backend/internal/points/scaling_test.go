package points

import (
	"errors"
	"math"
	"path/filepath"
	"testing"
)

func TestScalingConfigurationValidationAndPersistence(t *testing.T) {
	for _, tt := range []struct {
		name, kind    string
		scale, offset float64
		wantErr       bool
	}{
		{"identity", "FLOAT", 1, 0, false},
		{"negative", "FLOAT", -2, -10, false},
		{"fractional", "INT", .1, .25, false},
		{"zero", "FLOAT", 0, 0, true},
		{"nan_scale", "FLOAT", math.NaN(), 0, true},
		{"infinite_scale", "FLOAT", math.Inf(1), 0, true},
		{"nan_offset", "FLOAT", 1, math.NaN(), true},
		{"infinite_offset", "FLOAT", 1, math.Inf(-1), true},
		{"boolean_identity", "BOOL", 1, 0, false},
		{"boolean_scale", "BOOL", 2, 0, true},
		{"boolean_offset", "BOOL", 1, 1, true},
		{"string_identity", "STRING", 1, 0, false},
		{"string_scale", "STRING", -1, 0, true},
		{"string_offset", "STRING", 1, -1, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "points.json")
			s, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			p, err := s.Create(CreateInput{Station: "A", Name: tt.name, DataType: tt.kind, SourceType: "manual", ScaleFactor: &tt.scale, Offset: tt.offset})
			if tt.wantErr {
				if !errors.Is(err, ErrInvalid) || len(s.List()) != 0 {
					t.Fatalf("invalid conversion saved: %+v %v", p, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			reopened, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			if got := reopened.List(); len(got) != 1 || got[0].ScaleFactor != tt.scale || got[0].Offset != tt.offset || got[0].ID != p.ID {
				t.Fatalf("conversion did not survive restart: %+v", got)
			}
		})
	}
}

func TestInvalidScalingUpdateAndBatchAreAtomic(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "points.json"))
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.Create(CreateInput{Station: "A", Name: "original", DataType: "FLOAT", SourceType: "manual", Offset: 5})
	if err != nil {
		t.Fatal(err)
	}
	zero := 0.0
	invalid := CreateInput{Station: "A", Name: "invalid", DataType: "FLOAT", SourceType: "manual", ScaleFactor: &zero}
	if _, err := s.Update(p.ID, invalid); !errors.Is(err, ErrInvalid) {
		t.Fatalf("zero scaling update accepted: %v", err)
	}
	if _, err := s.CreateBatch([]CreateInput{{Station: "B", Name: "valid", DataType: "FLOAT", SourceType: "manual"}, invalid}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("zero scaling batch accepted: %v", err)
	}
	if got := s.List(); len(got) != 1 || got[0].ID != p.ID || got[0].Offset != 5 || got[0].ScaleFactor != 1 {
		t.Fatalf("failed changes mutated configuration: %+v", got)
	}
}

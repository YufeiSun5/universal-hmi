package externaldata

import (
	"context"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestSoutheastKeyTrendIncludesBothSecondaryHeatMeters(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	m.ExpectQuery(regexp.QuoteMeta(keyTrendMappingSQL)).WithArgs("01-001-01").WillReturnRows(
		sqlmock.NewRows([]string{"station", "name", "point", "unit", "column"}).
			AddRow("01-001-01", "中心站东南区", "ER_SecondaryTotalHeat", "GJ", "Value31").
			AddRow("01-001-01", "中心站东南区", "ER_Secondary2TotalHeat", "GJ", "Value38"))
	at := time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC)
	m.ExpectQuery(regexp.QuoteMeta(statisticsProcedure)).WillReturnRows(statisticRows(false).
		AddRow("01-001-01", "中心站东南区", "Value31", "东区热量", "GJ", at, at, "3.25", nil, nil, "有效", nil, nil, nil, "不完整").
		AddRow("01-001-01", "中心站东南区", "Value38", "南区热量", "GJ", at, at, "7.75", nil, nil, "有效", nil, nil, nil, "不完整"))
	m.ExpectClose()
	r, err := s.Query(context.Background(), view.ID, Request{Mode: "key_trends", Stations: []string{"01-001-01"}, From: "2026-11-15", To: "2026-11-15"})
	if err != nil {
		t.Fatal(err)
	}
	if len(r.KeyTrends.Series) != 1 || len(r.KeyTrends.Series[0].Samples) != 1 || value(r.KeyTrends.Series[0].Samples[0].Value) != "11.00" {
		t.Fatalf("expected one summed secondary series: %+v", r.KeyTrends)
	}
	if err := m.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func secondaryTestBindings() map[string]secondaryBinding {
	out := map[string]secondaryBinding{}
	columns := []string{"Value05", "Value36", "Value16", "Value37", "Value31", "Value38", "Value32", "Value39"}
	for i, pair := range secondaryMeterPairs {
		for j, code := range []string{pair.first, pair.second} {
			out[code] = secondaryBinding{columns[2*i+j], columns[2*i+j], pair.unit}
		}
	}
	return out
}

func TestSecondaryDecimalSumPrecisionNullAndZero(t *testing.T) {
	for _, tc := range []struct{ a, b, want string }{
		{"12345678901234567890.12345678", "0.87654322", "12345678901234567891.00000000"},
		{"0.00000000", "0", "0.00000000"}, {"-1.50", "2.25", "0.75"},
	} {
		got, err := secondarySum(&tc.a, &tc.b)
		if err != nil || value(got) != tc.want {
			t.Fatal(got, err, tc)
		}
	}
	a := "1"
	if got, err := secondarySum(&a, nil); got != nil || err != nil {
		t.Fatal(got, err)
	}
	bad := "1/3"
	if _, err := secondarySum(&a, &bad); err == nil {
		t.Fatal("accepted a fraction instead of a decimal")
	}
}

func TestSecondaryHourlyProjectionPreservesSharedMetricsAndNeverAddsExtrema(t *testing.T) {
	bindings := secondaryTestBindings()
	stamp := "2026-11-15T09:00:00+08:00"
	text := func(s string) *string { return &s }
	shared := Statistic{Station: southeastStation, Name: "东南区", Date: "2026-11-15", Hour: &stamp, Metric: "Value01", Label: "供温", Unit: "℃", HourMin: text("30"), HourMax: text("40")}
	other := shared
	other.Station = "01-001-02"
	input := []Statistic{shared, other}
	ranges := map[string]secondaryRange{}
	for _, pair := range secondaryMeterPairs {
		for i, code := range []string{pair.first, pair.second} {
			r := Statistic{Station: southeastStation, Name: "东南区", Date: shared.Date, Hour: &stamp, Metric: bindings[code].column, Unit: pair.unit, HourStatus: text("有效")}
			if pair.kind == "range" {
				// Independent extrema are [0,100] for each meter; their
				// simultaneous total was always 100, never 0 or 200.
				r.HourMin, r.HourMax = text("0"), text("100")
			} else {
				r.HourUsage = text([]string{"3.25", "7.75"}[i])
			}
			input = append(input, r)
		}
		if pair.kind == "range" {
			ranges[stamp+"/"+pair.first] = secondaryRange{hour: stamp, point: pair.first, low: text("100"), high: text("100"), complete: true}
		}
	}
	got, err := combineSecondaryStatistics(input, bindings, secondaryMeterPairs, false, ranges)
	if err != nil || len(got) != 6 || !reflect.DeepEqual(got[0], shared) || !reflect.DeepEqual(got[1], other) {
		t.Fatal(got, err)
	}
	for _, r := range got[2:] {
		if r.Aggregation != "FE201+FE202" || r.AggregationIncomplete || !strings.Contains(r.Label, "合计") {
			t.Fatal(r)
		}
		if r.StatisticKind == "range" && (value(r.HourMin) != "100" || value(r.HourMax) != "100" || r.HourUsage != nil) {
			t.Fatal(r)
		}
		if r.StatisticKind == "usage" && (value(r.HourUsage) != "11.00" || r.HourMin != nil) {
			t.Fatal(r)
		}
	}
	// Missing FE202 is a visible missing total, not FE201's 3.25.
	filtered := []Statistic{}
	for _, r := range input {
		if r.Metric != "Value38" {
			filtered = append(filtered, r)
		}
	}
	got, err = combineSecondaryStatistics(filtered, bindings, secondaryMeterPairs, false, ranges)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range got {
		if r.Station == southeastStation && r.Metric == "Value31" && (r.HourUsage != nil || !r.AggregationIncomplete || !strings.Contains(value(r.HourStatus), "不完整")) {
			t.Fatal(r)
		}
	}
	// Reject duplicate members and changed units; never silently double count.
	if _, err = combineSecondaryStatistics(append(input, input[2]), bindings, secondaryMeterPairs, false, ranges); err == nil {
		t.Fatal("accepted duplicate")
	}
	input[2].Unit = "m³/h"
	if _, err = combineSecondaryStatistics(input, bindings, secondaryMeterPairs, false, ranges); err == nil {
		t.Fatal("accepted unit drift")
	}
}

func TestSecondaryDailyProjectionKeepsPartialSeparateAndUsesSettledHorizon(t *testing.T) {
	text := func(s string) *string { return &s }
	bindings := secondaryTestBindings()
	day := "2026-11-15"
	rows := []Statistic{}
	for _, pair := range secondaryMeterPairs {
		for _, code := range []string{pair.first, pair.second} {
			r := Statistic{Station: southeastStation, Name: "东南区", Date: day, Metric: code, Unit: pair.unit, StatisticKind: pair.kind, DayRecord: text("true"), ValidHours: text("2"), SampleMax: text(day + "T01:00:00+08:00"), DayStatus: text("不完整")}
			if pair.kind == "usage" {
				r.DaySubtotal = text("2.5")
			} else {
				r.DayMin, r.DayMax = text("0"), text("100")
			}
			rows = append(rows, r)
		}
	}
	ranges := map[string]secondaryRange{}
	for _, pair := range secondaryMeterPairs[:2] {
		for i, hour := range []string{"00", "01", "02"} {
			stamp := day + "T" + hour + ":00:00+08:00"
			v := []string{"90", "110", "999"}[i]
			ranges[stamp+"/"+pair.first] = secondaryRange{hour: stamp, point: pair.first, low: &v, high: &v, complete: true}
		}
	}
	got, err := combineSecondaryStatistics(rows, bindings, secondaryMeterPairs, true, ranges)
	if err != nil || len(got) != 4 {
		t.Fatal(got, err)
	}
	for _, r := range got {
		if !r.AggregationIncomplete || r.ValidHours != nil {
			t.Fatal("did not preserve partial semantics", r)
		}
		if r.StatisticKind == "usage" && (r.DayUsage != nil || value(r.DaySubtotal) != "5.0") {
			t.Fatal(r)
		}
		if r.StatisticKind == "range" && (value(r.DayMin) != "90" || value(r.DayMax) != "110") {
			t.Fatal("included raw sample beyond settled horizon", r)
		}
	}
	// A missing member's subtotal is never replaced by zero.
	rows[5].DaySubtotal = nil
	got, err = combineSecondaryStatistics(rows, bindings, secondaryMeterPairs, true, ranges)
	if err != nil || got[2].DayUsage != nil || got[2].DaySubtotal != nil {
		t.Fatal(got, err)
	}
	// One unmatched simultaneous sample invalidates the aggregate range.
	key := day + "T01:00:00+08:00/" + secondaryMeterPairs[0].first
	v := ranges[key]
	v.complete = false
	ranges[key] = v
	got, err = combineSecondaryStatistics(rows, bindings, secondaryMeterPairs, true, ranges)
	if err != nil || got[0].DayMin != nil || got[0].DayMax != nil {
		t.Fatal(got, err)
	}
}

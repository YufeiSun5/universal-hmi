package externaldata

import (
	"context"
	"errors"
	"fmt"
	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestKeyTrendDateAndStationBounds(t *testing.T) {
	now := time.Date(2026, 11, 16, 23, 0, 0, 0, time.UTC)
	a, b, e := keyTrendBounds(Request{Stations: []string{"A"}}, now)
	if e != nil || a.Format("2006-01-02") != "2026-11-17" || !a.Equal(b) {
		t.Fatal(a, b, e)
	}
	for _, r := range []Request{
		{Stations: nil}, {Stations: []string{"A", "A"}}, {Stations: []string{"A,B"}},
		{Stations: []string{"A"}, From: "2026-11-17", To: "2026-11-16"},
		{Stations: []string{"A"}, From: "2026-11-04", To: "2026-12-10"},
		{Stations: []string{"A"}, From: "2026-11-04", To: "2026-11-05", Offset: 1},
	} {
		if _, _, e = keyTrendBounds(r, now); e == nil {
			t.Fatal("accepted invalid range", r)
		}
	}
}

func TestKeyTrendsUseHourlyUsageAndRangeWithRemappedColumns(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	mapping := sqlmock.NewRows([]string{"station", "name", "point", "unit", "column"})
	for _, station := range []string{"A", "B"} {
		for i, p := range keyTrendPoints {
			unit := "GJ"
			if p.Group == "temperature" {
				unit = "℃"
			}
			if p.Group == "pressure" {
				unit = "MPa"
			}
			mapping.AddRow(station, station+"站", p.Code, unit, fmt.Sprintf("Value%02d", 60-i))
		}
	}
	m.ExpectQuery(regexp.QuoteMeta(keyTrendMappingSQL)).WithArgs("A,B").WillReturnRows(mapping)
	for _, day := range []int{4, 5} {
		at := time.Date(2026, 11, day, 9, 0, 0, 0, time.UTC)
		batch := statisticRows(false)
		for _, station := range []string{"A", "B"} {
			batch.AddRow(station, station+"站", "Value60", "累计热量", "GJ", at, at, "0.00000000", nil, nil, "有效", "9000", nil, nil, "截至采样有效")
			batch.AddRow(station, station+"站", "Value59", "二网累计热量", "GJ", at, at, "12345678901234567890.12345678", nil, nil, "有效", nil, nil, nil, "不完整")
			batch.AddRow(station, station+"站", "Value58", "供温", "℃", at, at, nil, "0.00000000", "56.25000000", "有效", nil, nil, nil, "不完整")
			batch.AddRow(station, station+"站", "Value57", "回温", "℃", at, nil, nil, nil, nil, "缺边界", nil, nil, nil, "不完整")
			batch.AddRow(station, station+"站", "Value56", "供压", "MPa", at, at, nil, "0.20", "0.35", "有效", nil, nil, nil, "不完整")
			batch.AddRow(station, station+"站", "Value01", "非重点测点", "A", at, at, nil, "10", "20", "有效", nil, nil, nil, "不完整")
		}
		m.ExpectQuery(regexp.QuoteMeta(statisticsProcedure)).WithArgs("A,B", nil, false, fmt.Sprintf("2026-11-%02d", day), true, sqlmock.AnyArg()).WillReturnRows(batch)
	}
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Mode: "key_trends", Stations: []string{"A", "B"}, From: "2026-11-04", To: "2026-11-05"})
	if e != nil {
		t.Fatal(e)
	}
	v := r.KeyTrends
	if v == nil || len(v.Series) != 12 || len(v.Missing) != 0 {
		t.Fatal(v)
	}
	if value(v.Series[0].Samples[0].Value) != "0.00000000" || value(v.Series[1].Samples[0].Value) != "12345678901234567890.12345678" || value(v.Series[2].Samples[0].Low) != "0.00000000" || v.Series[3].Samples[0].Low != nil || v.Series[0].Samples[0].Time != "2026-11-04T09:00:00+08:00" {
		t.Fatalf("%+v", v.Series)
	}
	if e = m.ExpectationsWereMet(); e != nil {
		t.Fatal(e)
	}
}

func TestKeyTrendsAllSelectIsBatchedAndNotTruncated(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	codes := []string{}
	mapping := sqlmock.NewRows([]string{"station", "name", "point", "unit", "column"})
	for i := 0; i < 17; i++ {
		code := fmt.Sprintf("S%02d", i)
		codes = append(codes, code)
		mapping.AddRow(code, code, "ER_TotalHeat", "GJ", "Value06")
	}
	m.ExpectQuery(regexp.QuoteMeta(keyTrendMappingSQL)).WithArgs(strings.Join(codes, ",")).WillReturnRows(mapping)
	at := time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC)
	for i := 0; i < len(codes); i += 8 {
		chunk := codes[i:min(i+8, len(codes))]
		rows := statisticRows(false)
		for _, code := range chunk {
			rows.AddRow(code, code, "Value06", "热量", "GJ", at, at, "1", nil, nil, "有效", nil, nil, nil, "不完整")
		}
		m.ExpectQuery(regexp.QuoteMeta(statisticsProcedure)).WithArgs(strings.Join(chunk, ","), nil, false, "2026-11-04", true, sqlmock.AnyArg()).WillReturnRows(rows)
	}
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Mode: "key_trends", Stations: codes, From: "2026-11-04", To: "2026-11-04"})
	if e != nil || len(r.KeyTrends.Series) != 17 || len(r.KeyTrends.Missing) != 85 {
		t.Fatal(r, e)
	}
	if e = m.ExpectationsWereMet(); e != nil {
		t.Fatal(e)
	}
}

func TestKeyTrendsPreserveScreenAuthorization(t *testing.T) {
	s, _, view := fixture(t)
	ctx := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{"another"}})
	if _, e := s.Query(ctx, view.ID, Request{Mode: "key_trends", Stations: []string{"A"}}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
}

func TestKeyTrendsRejectChangedMappingUnitsAndUnexpectedStations(t *testing.T) {
	for _, scenario := range []string{"duplicate", "wrong-unit", "unexpected", "reversed-range"} {
		t.Run(scenario, func(t *testing.T) {
			s, _, view := fixture(t)
			m := mockDB(t, s)
			rows := sqlmock.NewRows([]string{"station", "name", "point", "unit", "column"}).AddRow("A", "A站", "ER_SupplyTemp", "℃", "Value01")
			if scenario == "duplicate" {
				rows.AddRow("A", "A站", "ER_SupplyTemp", "℃", "Value02")
			}
			m.ExpectQuery(regexp.QuoteMeta(keyTrendMappingSQL)).WithArgs("A").WillReturnRows(rows)
			if scenario != "duplicate" {
				station, unit, lo, hi := "A", "℃", "10", "20"
				if scenario == "wrong-unit" {
					unit = "MPa"
				}
				if scenario == "unexpected" {
					station = "B"
				}
				if scenario == "reversed-range" {
					lo = "30"
				}
				at := time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC)
				m.ExpectQuery(regexp.QuoteMeta(statisticsProcedure)).WithArgs("A", nil, false, "2026-11-04", true, sqlmock.AnyArg()).WillReturnRows(statisticRows(false).AddRow(station, "站", "Value01", "温度", unit, at, at, nil, lo, hi, "有效", nil, nil, nil, "不完整"))
			}
			m.ExpectClose()
			if _, e := s.Query(context.Background(), view.ID, Request{Mode: "key_trends", Stations: []string{"A"}, From: "2026-11-04", To: "2026-11-04"}); e == nil {
				t.Fatal("accepted invalid result")
			}
			if e := m.ExpectationsWereMet(); e != nil {
				t.Fatal(e)
			}
		})
	}
}

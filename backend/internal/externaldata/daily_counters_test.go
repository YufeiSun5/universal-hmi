package externaldata

import (
	"context"
	"github.com/DATA-DOG/go-sqlmock"
	"testing"
	"time"
)

func TestDailyCountersUseUTCNearestWindowAndPreserveMissing(t *testing.T) {
	s, source, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "总表取数", SourceID: source.ID, Kind: "standard"})
	if e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	m.ExpectQuery(`SELECT TOP \(61\)`).WithArgs("01-001-01").WillReturnRows(sqlmock.NewRows([]string{"code", "name", "unit", "column", "type"}).AddRow("ER_TotalHeat", "累计热量", "GJ", "Value06", "N"))
	start := time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC)
	m.ExpectQuery(`WITH days\(t\).*OUTER APPLY.*DATEADD\(minute,-30,d.t\).*DATEADD\(minute,30,d.t\).*DATEDIFF_BIG.*MAXRECURSION 185`).WithArgs(start, start.AddDate(0, 0, 3), "01-001-01").WillReturnRows(sqlmock.NewRows([]string{"target", "sample", "quality", "value"}).
		AddRow(start, start.Add(-time.Minute), 1, "0.00000000").
		AddRow(start.AddDate(0, 0, 1), start.AddDate(0, 0, 1).Add(2*time.Minute), 2, "123456789.12345678").
		AddRow(start.AddDate(0, 0, 2), start.AddDate(0, 0, 2), 0, "55").
		AddRow(start.AddDate(0, 0, 3), start.AddDate(0, 0, 3), 1, nil))
	m.ExpectClose()
	v, e := s.DailyCounters(context.Background(), view.ID, "2026-11-04", "2026-11-07", []CounterBinding{{"01-001-01", "ER_TotalHeat", "GJ"}})
	if e != nil || len(v) != 4 {
		t.Fatal(v, e)
	}
	if *v[0].Value != "0.00000000" || *v[1].Value != "123456789.12345678" || v[2].Value != nil || v[3].Value != nil {
		t.Fatal(v)
	}
	if v[0].TargetTime != "2026-11-04T08:00:00+08:00" || *v[0].SampleTime != "2026-11-04T07:59:00+08:00" {
		t.Fatal(v[0])
	}
}

func TestDailyCountersRejectChangedMetadataBeforeReading(t *testing.T) {
	s, source, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "总表取数", SourceID: source.ID, Kind: "standard"})
	if e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	m.ExpectQuery(`SELECT TOP \(61\)`).WithArgs("zone").WillReturnRows(sqlmock.NewRows([]string{"code", "name", "unit", "column", "type"}).AddRow("ER_TotalHeat", "累计热量", "kWh", "Value06", "N"))
	m.ExpectClose()
	if _, e = s.DailyCounters(context.Background(), view.ID, "2026-11-04", "2026-11-04", []CounterBinding{{"zone", "ER_TotalHeat", "GJ"}}); e == nil {
		t.Fatal("changed unit silently accepted")
	}
}

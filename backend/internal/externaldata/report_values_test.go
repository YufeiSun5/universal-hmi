package externaldata

import (
	"context"
	"github.com/DATA-DOG/go-sqlmock"
	"testing"
	"time"
)

func TestReportHistoryUsesConfiguredTimeWindowAndRawQuality(t *testing.T) {
	s, source, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "历史绑定", SourceID: source.ID, Kind: "standard"})
	if e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	m.ExpectQuery(`SELECT TOP \(61\)`).WithArgs("zone").WillReturnRows(sqlmock.NewRows([]string{"code", "name", "unit", "column", "type"}).AddRow("counter", "表底", "GJ", "Value06", "N"))
	stamp := time.Date(2026, 11, 5, 0, 15, 0, 0, time.UTC)
	m.ExpectQuery(`WITH targets.*DATEADD\(minute,-@window.*DATEDIFF_BIG`).WithArgs("zone", 12, stamp, stamp, stamp.AddDate(0, 0, 1), stamp.AddDate(0, 0, 1)).WillReturnRows(sqlmock.NewRows([]string{"i", "sample", "quality", "value"}).AddRow(0, stamp, 1, "0.00000000").AddRow(1, stamp.AddDate(0, 0, 1), 0, "123"))
	m.ExpectClose()
	r, e := s.ReportValues(context.Background(), ReportValueRequest{Screen: view.ID, Station: "zone", Point: "counter", Unit: "GJ", Mode: "nearest", WindowMinutes: 12, Targets: []ReportTarget{{"2026-11-05T08:15:00+08:00", "2026-11-05T08:15:00+08:00"}, {"2026-11-06T08:15:00+08:00", "2026-11-06T08:15:00+08:00"}}})
	if e != nil || len(r) != 2 || r[0].Value == nil || *r[0].Value != "0.00000000" || r[1].Value != nil {
		t.Fatal(r, e)
	}
}
func TestReportHistoryRejectsWrongSourceForSettlementAndBounds(t *testing.T) {
	s, source, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "原始", SourceID: source.ID, Kind: "standard"})
	if e != nil {
		t.Fatal(e)
	}
	in := ReportValueRequest{Screen: view.ID, Station: "zone", Point: "counter", Unit: "GJ", Mode: "daily_usage", Targets: []ReportTarget{{"2026-11-05T00:00:00+08:00", "2026-11-06T00:00:00+08:00"}}}
	if _, e = s.ReportValues(context.Background(), in); e == nil {
		t.Fatal("raw values used as stored settlement")
	}
	in.Mode = "nearest"
	in.WindowMinutes = 181
	if _, e = s.ReportValues(context.Background(), in); e == nil {
		t.Fatal("unbounded window")
	}
}

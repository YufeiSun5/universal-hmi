package externaldata

import (
	"context"
	"database/sql/driver"
	"errors"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestSettlementRetainsSubtotalNullAndPerPointAnomalies(t *testing.T) {
	s, src, _ := fixture(t)
	v, e := s.SaveScreen(context.Background(), Screen{Name: "日结算", Kind: "daily", SourceID: src.ID})
	if e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	rows := sqlmock.NewRows(settlementFields).
		AddRow("2026-11-04", "A", "A站", "Heat", "热", "GJ", "Value60", true, "12345678901234567890.12345678", nil, 7, 12, "不完整", nil, `{"Value60":{"hours":7},"Value01":{"wrong":true}}`).
		AddRow("2026-11-04", "A", "A站", "Water", "水", "t", "Value01", false, nil, nil, nil, nil, "未生成日统计", nil, nil)
	m.ExpectQuery("EXEC dbo.usp_查询站区日结算").WithArgs("2026-11-04", "2026-11-04", "A").WillReturnRows(rows)
	m.ExpectClose()
	got, e := s.Query(context.Background(), v.ID, Request{Station: "A", From: "2026-11-04", To: "2026-11-04"})
	if e != nil || len(got.Statistics) != 2 {
		t.Fatal(got, e)
	}
	r := got.Statistics[0]
	if r.DayUsage != nil || value(r.DaySubtotal) != "12345678901234567890.12345678" || value(r.ValidHours) != "7" || value(r.DayAnomaly) != `{"hours":7}` || value(got.Statistics[1].DayRecord) != "false" {
		t.Fatal(got)
	}
}

func TestComparisonWindows(t *testing.T) {
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	in := Request{From: "2026-11-10", To: "2026-11-04", HistoryFrom: "2025-11-26", HistoryTo: "2025-11-20", ComparisonType: "明细", HistoryFactor: "1.0000000000"}
	got, e := comparisonBounds(in, now)
	if e != nil || got.From != "2026-11-04" || got.HistoryFrom != "2025-11-20" {
		t.Fatal(got, e)
	}
	for _, change := range []func(*Request){func(v *Request) { v.To = "2026-11-03" }, func(v *Request) { v.From = "2026-11-11" }, func(v *Request) { v.HistoryTo = "2025-11-19" }, func(v *Request) { v.HistoryFactor = "0" }, func(v *Request) { v.HistoryFactor = "1e2" }, func(v *Request) { v.HistoryFactor = "1;DROP" }, func(v *Request) { v.ComparisonType = "全部" }, func(v *Request) { v.Station = "01-001,02-001" }, func(v *Request) { v.HistoryFrom = "2026-11-10" }} {
		bad := in
		change(&bad)
		if _, e := comparisonBounds(bad, now); e == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func TestComparisonIndependentAccessPreservesZerosAndNewStations(t *testing.T) {
	s, src, old := fixture(t)
	v, e := s.SaveScreen(context.Background(), Screen{Name: "同期对比", Kind: "comparison", SourceID: src.ID})
	if e != nil {
		t.Fatal(e)
	}
	in := Request{From: "2026-11-04", To: "2026-11-04", HistoryFrom: "2025-11-20", HistoryTo: "2025-11-20", ComparisonType: "明细"}
	if _, e = s.Query(actor(authorization.Grants{ExternalScreenIDs: []string{old.ID}}), v.ID, in); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	rows := sqlmock.NewRows(comparisonDetailFields)
	for _, station := range []string{"01-001", "04-003"} {
		vals := make([]driver.Value, len(comparisonDetailFields))
		data := map[string]driver.Value{"序号": int64(1), "整站编码": station, "指标": "水", "本期日期": "2026-11-04", "历史日期": "2025-11-20", "本期单位": "t", "本期日用量": "0.00000000", "本期状态": "截至采样有效", "可比": false, "双方完整日有效": false, "对比状态": "新站无历史数据"}
		if station == "01-001" {
			data["历史日用量"] = "12345678901234567890.12345678"
			data["对比状态"] = "本期未结束"
		}
		for i, k := range comparisonDetailFields {
			vals[i] = data[k]
		}
		rows.AddRow(vals...)
	}
	m.ExpectQuery("EXEC dbo.usp_整站水电热自选日期对比").WithArgs(nil, in.From, in.To, in.HistoryFrom, in.HistoryTo, nil, "明细", nil).WillReturnRows(rows)
	m.ExpectClose()
	got, e := s.Query(context.Background(), v.ID, in)
	if e != nil || len(got.Comparisons) != 2 {
		t.Fatal(got, e)
	}
	if value(got.Comparisons[0]["本期日用量"]) != "0.00000000" || value(got.Comparisons[0]["历史日用量"]) != "12345678901234567890.12345678" || got.Comparisons[1]["变化百分比"] != nil || value(got.Comparisons[1]["对比状态"]) != "新站无历史数据" {
		t.Fatal(got)
	}
}

func TestStatisticsPeriodStartsNovemberFourth(t *testing.T) {
	now := time.Date(2026, 11, 5, 9, 0, 0, 0, time.UTC)
	if _, _, _, err := statisticsBounds("daily", Request{Station: "A", From: "2026-11-03", To: "2026-11-04"}, now); err == nil {
		t.Fatal("Nov3 accepted")
	}
	if a, b, _, err := statisticsBounds("daily", Request{Station: "A", From: "2026-11-04", To: "2026-11-05"}, now); err != nil || b.Sub(a) != 24*time.Hour {
		t.Fatal(a, b, err)
	}
}

package externaldata

import (
	"context"
	"database/sql/driver"
	"github.com/DATA-DOG/go-sqlmock"
	"testing"
	"time"
)

func TestSlidingBoundsBeijingAndPartialHours(t *testing.T) {
	now := time.Date(2026, 11, 4, 13, 10, 20, 471000000, time.UTC)
	in := Request{Mode: "sliding", Station: "01-001", From: "2026-11-04T08:15:00+08:00", To: "2026-11-04T12:30:00+08:00", HistoryFrom: "2025-11-27T09:15:00+08:00", ComparisonType: "汇总"}
	got, e := slidingBounds(in, now)
	if e != nil || got.HistoryTo != "2025-11-27T13:30:00+08:00" {
		t.Fatal(got, e)
	}
	current := in
	current.From = "2026-11-03T16:00:00Z"
	current.To = ""
	current.HistoryFrom = "2025-11-27T00:00:00+08:00"
	got, e = slidingBounds(current, now)
	if e != nil || got.From != "2026-11-04T00:00:00+08:00" || got.To != "2026-11-04T21:10:20.471+08:00" || got.HistoryTo != "2025-11-27T21:10:20.471+08:00" {
		t.Fatal(got, e)
	}
	for _, change := range []func(*Request){func(r *Request) { r.To = r.From }, func(r *Request) { r.From = "2026-11-03T08:15:00+08:00" }, func(r *Request) { r.To = "2026-11-05T00:00:00+08:00" }, func(r *Request) { r.HistoryFrom = "2025-11-27T09:00:00+08:00" }, func(r *Request) { r.HistoryTo = "2025-11-27T14:30:00+08:00" }, func(r *Request) { r.HeatFactor = "0" }, func(r *Request) { r.WaterFactor = "1;DROP" }, func(r *Request) { r.Station = "01-001-01" }, func(r *Request) { r.ComparisonType = "全部" }, func(r *Request) { r.Station = ""; r.ComparisonType = "明细" }, func(r *Request) { r.From = "2026-11-04T08:15:00" }} {
		bad := in
		change(&bad)
		if _, e := slidingBounds(bad, now); e == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}
func TestSlidingSummaryPreservesFixtureZeroNullAndPairedTemperature(t *testing.T) {
	s, src, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "同期", Kind: "comparison", SourceID: src.ID})
	if e != nil {
		t.Fatal(e)
	}
	in := Request{Mode: "sliding", Station: "01-001", From: "2026-11-04T00:00:00+08:00", To: "2026-11-04T21:10:20.471+08:00", HistoryFrom: "2025-11-27T00:00:00+08:00", ComparisonType: "汇总"}
	m := mockDB(t, s)
	rows := sqlmock.NewRows(slidingSummaryFields)
	for _, metric := range []string{"水", "电", "热"} {
		data := map[string]driver.Value{"整站编码": "01-001", "指标": metric, "选择秒数": "76220.47100000", "本期有效用量小计": "0.00000000", "本期配对平均气温": 13.23679692983539, "历史配对平均气温": 0.9736826617387264, "气温可比秒数": "72620.47100000", "气温状态": "气温不完整", "用量状态": "无可比用量"}
		for k, v := range map[string]string{"本期开始时间": in.From, "本期结束时间": in.To, "历史开始时间": in.HistoryFrom, "历史结束时间": "2025-11-27T21:10:20.471+08:00"} {
			stamp, _ := slidingTime(v)
			data[k] = stamp
		}
		if metric == "热" {
			data["本期配对用量"] = "393.00000000"
			data["历史配对用量"] = "933.06000000"
			data["用量差值"] = "-540.06000000"
			data["用量变化百分比"] = -57.88052215291621
		}
		vals := make([]driver.Value, len(slidingSummaryFields))
		for i, k := range slidingSummaryFields {
			vals[i] = data[k]
		}
		rows.AddRow(vals...)
	}
	m.ExpectQuery("EXEC dbo.usp_气温水电热滑动对比").WithArgs("2026-11-04T00:00:00.000", "2025-11-27T00:00:00.000", "2026-11-04T21:10:20.471", "2025-11-27T21:10:20.471", "01-001", "汇总", "1", "1", "1").WillReturnRows(rows)
	m.ExpectClose()
	got, e := s.Query(context.Background(), view.ID, in)
	if e != nil {
		t.Fatal(e)
	}
	if got.UTCOffsetMinutes != 480 || len(got.Comparisons) != 3 || got.Comparisons[1]["历史配对用量"] != nil || value(got.Comparisons[1]["本期有效用量小计"]) != "0.00000000" || value(got.Comparisons[2]["本期配对用量"]) != "393.00000000" || value(got.Comparisons[2]["用量变化百分比"]) != "-57.88052215291621" {
		t.Fatal(got)
	}
	if e = m.ExpectationsWereMet(); e != nil {
		t.Fatal(e)
	}
}
func TestComparisonDailyProjectionExactWeightedAndMissing(t *testing.T) {
	ptr := func(s string) *string { return &s }
	rows := []map[string]*string{}
	for i, seconds := range []string{"2700", "1800"} {
		start, end := "2026-11-04T08:15:00+08:00", "2026-11-04T09:00:00+08:00"
		temp := "10"
		if i == 1 {
			start, end = "2026-11-04T09:00:00+08:00", "2026-11-04T09:30:00+08:00"
			temp = "20"
		}
		rows = append(rows, map[string]*string{"整站编码": ptr("01-001"), "指标": ptr("热"), "单位": ptr("GJ"), "本期开始": ptr(start), "本期结束": ptr(end), "片段秒数": ptr(seconds), "本期用量": ptr("12345678901234567890.12345678"), "历史折算用量": ptr("0"), "本期平均气温": ptr(temp), "历史整点气温": ptr("0")})
	}
	result := comparisonDays(rows)
	if value(result[0]["本期用量"]) != "24691357802469135780.24691356" || value(result[0]["本期平均气温"]) != "14.00000000" || value(result[0]["历史折算用量"]) != "0.00000000" {
		t.Fatal(result)
	}
	rows[1]["本期用量"] = nil
	rows[1]["本期平均气温"] = nil
	result = comparisonDays(rows)
	if result[0]["本期用量"] != nil || result[0]["本期平均气温"] != nil || value(result[0]["历史折算用量"]) != "0.00000000" {
		t.Fatal(result)
	}
}

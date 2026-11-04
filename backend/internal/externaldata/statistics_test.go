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

func statisticRows(whole bool) *sqlmock.Rows {
	if whole {
		return sqlmock.NewRows([]string{"整站编码", "指标", "单位", "当前小时起点", "成员最早最新采样时间", "成员最晚最新采样时间", "当前小时用量", "当前小时状态", "今日用量", "今日状态"})
	}
	return sqlmock.NewRows([]string{"站区编码", "站区名称", "输出列", "测点", "单位", "当前小时起点", "最新参与采样时间", "当前小时差额", "当前小时最小值", "当前小时最大值", "当前小时状态", "今日有效差额小计", "今日最小值", "今日最大值", "今日状态"})
}
func TestHourlyStatisticsPrecisionRangesMissingAndSubtotal(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	at := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	rows := statisticRows(false).
		AddRow("A", "A站", "Electricity", "电", "kWh", at, at, "12345678901234567890.12345678", nil, nil, "有效", "12345678901234567890.12345678", nil, nil, "截至采样有效").
		AddRow("A", "A站", "Temp", "温度", "℃", at, at, nil, "0.00000000", "56.25000000", "有效", nil, "0.00000000", "60.00000000", "截至采样有效").
		AddRow("A", "A站", "Water", "水", "t", at, nil, nil, nil, nil, "缺边界", "12.50000000", nil, nil, "不完整")
	m.ExpectQuery("EXEC dbo.usp_").WithArgs("A", nil, false, "2026-10-27", true, sqlmock.AnyArg()).WillReturnRows(rows)
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"})
	if e != nil {
		t.Fatal(e)
	}
	if len(r.Statistics) != 3 {
		t.Fatal(r)
	}
	a, b, c := r.Statistics[0], r.Statistics[1], r.Statistics[2]
	if value(a.HourUsage) != "12345678901234567890.12345678" || value(a.Hour) != "2026-10-27T00:00:00+08:00" || value(b.HourMin) != "0.00000000" || value(b.HourMax) != "56.25000000" || b.HourUsage != nil || c.DayUsage != nil || value(c.DaySubtotal) != "12.50000000" || value(c.DayStatus) != "不完整" || c.CurrentDay {
		t.Fatalf("%+v %+v %+v", a, b, c)
	}
}
func TestEnergyIndependentScopeAndDailyParameters(t *testing.T) {
	s, src, history := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "能耗", SourceID: src.ID, Kind: "energy"})
	if e != nil {
		t.Fatal(e)
	}
	denied := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{history.ID}})
	if _, e = s.Query(denied, view.ID, Request{Mode: "daily", Date: "2026-10-27"}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	for i := 27; i <= 28; i++ {
		date := time.Date(2026, 10, i, 23, 0, 0, 0, time.UTC)
		rows := statisticRows(true).
			AddRow("01-001", "耗电量", "kWh", date, date, date, "0.00000000", "截至采样有效", "0.00000000", "截至采样有效").
			AddRow("01-001", "补水量", "t", date, nil, nil, nil, "口径待确认", nil, "口径待确认").
			AddRow("01-001", "一次网耗热量", "GJ", date, nil, nil, nil, "成员不完整", nil, "成员不完整").
			AddRow("01-001", "一次网流量", "t", date, date, date, "9", "截至采样有效", "9", "截至采样有效")
		m.ExpectQuery("EXEC dbo.usp_").WithArgs(nil, "01-001", true, date.Format("2006-01-02"), false, sqlmock.AnyArg()).WillReturnRows(rows)
	}
	m.ExpectClose()
	ctx := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}})
	r, e := s.Query(ctx, view.ID, Request{Station: "01-001", Mode: "daily", From: "2026-10-27", To: "2026-10-28"})
	if e != nil || len(r.Statistics) != 6 {
		t.Fatal(r, e)
	}
	if r.Statistics[0].Metric != "electricity" || value(r.Statistics[0].DayUsage) != "0.00000000" || r.Statistics[1].DayUsage != nil || r.Statistics[3].Date != "2026-10-28" {
		t.Fatal(r)
	}
}
func TestStatisticsRejectInvalidBeforeNetwork(t *testing.T) {
	now := time.Date(2026, 11, 4, 5, 0, 0, 0, time.UTC)
	for _, in := range []Request{{Mode: "daily", From: "2026-10-01", To: "2026-11-01"}, {Mode: "daily", From: "2026-11-04", To: "2026-11-03"}, {Mode: "daily", Date: "2026-11-05"}, {Mode: "hourly", Date: "2026-11-03"}, {Mode: "zones", Station: "01-001,02-001", Date: "2026-11-03"}, {Mode: "invalid", Station: "01-001", Date: "2026-11-03"}} {
		if _, _, _, e := statisticsBounds("energy", in, now); e == nil {
			t.Fatalf("accepted %+v", in)
		}
	}
}
func TestEnergyZonesUsesStablePointCodes(t *testing.T) {
	s, src, _ := fixture(t)
	view, _ := s.SaveScreen(context.Background(), Screen{Name: "能耗", Kind: "energy", SourceID: src.ID})
	m := mockDB(t, s)
	m.ExpectQuery("SELECT s.StationCode,p.PointCode").WithArgs("01-001").WillReturnRows(sqlmock.NewRows([]string{"code", "point", "column"}).AddRow("01-001-01", "ER_ActiveEnergyTotal", "RenamedColumn").AddRow("01-001-02", "ER_TotalHeat", "Heat"))
	at := time.Date(2026, 10, 27, 23, 0, 0, 0, time.UTC)
	m.ExpectQuery("EXEC dbo.usp_").WithArgs("01-001-01,01-001-02", nil, false, "2026-10-27", false, sqlmock.AnyArg()).WillReturnRows(statisticRows(false).AddRow("01-001-01", "东南区", "RenamedColumn", "随意改名", "kWh", at, at, "1", nil, nil, "有效", "5", nil, nil, "不完整").AddRow("01-001-01", "东南区", "Other", "其他", "℃", at, at, nil, "3", "8", "有效", nil, "3", "8", "截至采样有效"))
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Station: "01-001", Mode: "zones", Date: "2026-10-27"})
	if e != nil || len(r.Statistics) != 1 || r.Statistics[0].Metric != "electricity" || r.Statistics[0].DayUsage != nil {
		t.Fatal(r, e)
	}
}
func TestStatisticsBadSchemaAndCrossStationFail(t *testing.T) {
	for _, bad := range []string{"schema", "station", "duplicate"} {
		t.Run(bad, func(t *testing.T) {
			s, _, view := fixture(t)
			m := mockDB(t, s)
			rows := statisticRows(false)
			values := []driver.Value{"B", "B", "X", "X", "t", time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC), nil, nil, nil, nil, "无采样", nil, nil, nil, "不完整"}
			switch bad {
			case "schema":
				rows = sqlmock.NewRows([]string{"x"})
			case "station":
				rows.AddRow(values...)
			case "duplicate":
				values[0] = "A"
				rows.AddRow(values...).AddRow(values...)
			}
			m.ExpectQuery("EXEC dbo.usp_").WillReturnRows(rows)
			m.ExpectClose()
			if _, e := s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"}); e == nil {
				t.Fatal("accepted bad database result")
			}
		})
	}
}

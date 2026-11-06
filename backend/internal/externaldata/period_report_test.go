package externaldata

import (
	"context"
	"errors"
	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

func TestPeriodReportKeepsStoredValuesZeroNullAndOnlyEnergy(t *testing.T) {
	p := func(s string) *string { return &s }
	data := []Statistic{
		{Station: "A", Metric: "ER_TotalHeat", Date: "2026-11-05", Unit: "GJ", DayUsage: p("0")},
		{Station: "A", Metric: "ER_TotalHeat", Date: "2026-11-06", Unit: "GJ", DaySubtotal: p("12345678901234567890.123456789012")},
		{Station: "A", Metric: "ER_MakeupFlowTotal", Date: "2026-11-05", Unit: "t"},
		{Station: "A", Metric: "ER_ActiveEnergyTotal", Date: "2026-11-05", Unit: "kWh", DayUsage: p("0")},
		{Station: "A", Metric: "Temperature", Date: "2026-11-05", Unit: "℃", DayUsage: p("35")},
	}
	r, err := buildPeriodReport("2026-11", data)
	if err != nil || len(r) != 3 {
		t.Fatal(r, err)
	}
	if value(r[0].DayUsage) != "12345678901234567890.123456789012" || value(r[1].DayUsage) != "0.000000000000" || r[2].DayUsage != nil {
		t.Fatal(r)
	}
	if _, err = buildPeriodReport("2026-11", append(data, data[0])); err == nil {
		t.Fatal("duplicate accepted")
	}
	data[1].Unit = "kWh"
	if _, err = buildPeriodReport("2026-11", data); err == nil {
		t.Fatal("mixed units accepted")
	}
}

func TestPeriodReportUsesDailyScreenPermissionAndStoredInterface(t *testing.T) {
	s, src, _ := fixture(t)
	v, err := s.SaveScreen(context.Background(), Screen{Name: "日报", Kind: "daily", SourceID: src.ID})
	if err != nil {
		t.Fatal(err)
	}
	denied := authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return true }, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if _, err = s.Query(denied, v.ID, Request{Station: "A", Mode: "monthly", Date: "2026-11-05"}); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("permission", err)
	}
	for _, mode := range []string{"monthly", "season"} {
		m := mockDB(t, s)
		m.ExpectQuery("EXEC dbo.usp_查询站区日结算").WillReturnRows(sqlmock.NewRows(settlementFields).
			AddRow("2026-11-05", "A", "A站", "ER_TotalHeat", "热", "GJ", "Value60", true, "12.5", nil, 7, 12, "不完整", nil, nil).
			AddRow("2026-11-05", "A", "A站", "Temperature", "温度", "℃", "Value01", true, "35", nil, 7, 12, "不完整", nil, nil))
		m.ExpectClose()
		result, e := s.Query(context.Background(), v.ID, Request{Station: "A", Mode: mode, Date: "2026-11-05"})
		if e != nil || len(result.Statistics) != 1 || value(result.Statistics[0].DayUsage) != "12.500000000000" {
			t.Fatal(result, e)
		}
	}
}

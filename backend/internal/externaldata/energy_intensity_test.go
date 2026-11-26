package externaldata

import (
	"context"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestEnergyIntensityUsesMeterScopesAndAvailableBusinessValues(t *testing.T) {
	s, source, _ := fixture(t)
	ctx := context.Background()
	view, err := s.SaveScreen(ctx, Screen{Name: "能耗", Kind: "energy", SourceID: source.ID})
	if err != nil {
		t.Fatal(err)
	}
	stored, _, err := s.source(ctx, view.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	s.SetEnergyAreas(func() (CockpitAreas, error) {
		return CockpitAreas{
			Heat: map[string]float64{"02-003": 200}, Electricity: map[string]float64{"02-001": 100},
			Water: map[string]float64{"02-002": 9999}, WaterZone: map[string]float64{"02-002-01": 40, "02-002-02": 50},
		}, nil
	})
	mock := mockDB(t, s)
	// Whole-site dates can be read concurrently.
	mock.MatchExpectationsInOrder(false)
	mock.ExpectQuery("SELECT TOP \\(257\\)").WillReturnRows(sqlmock.NewRows([]string{"StationCode", "StationName"}).
		AddRow("02-001-01", "新北一区").AddRow("02-002-01", "北三南线").AddRow("02-002-02", "北三光明区"))
	at := time.Date(2026, 11, 21, 4, 0, 0, 0, time.UTC)
	missing := statisticRows(true)
	mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, "2026-11-20", false, at).WillReturnRows(missing)
	mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, "2026-11-21", false, at).
		WillReturnRows(statisticRows(true).
			AddRow("02-001", "一次网耗热量", "GJ", at.In(beijing), nil, nil, nil, nil, "900", "").
			AddRow("02-003", "一次网耗热量", "GJ", at.In(beijing), nil, nil, nil, nil, "100", "").
			AddRow("02-001", "耗电量", "kWh", at.In(beijing), nil, nil, nil, nil, "30", "").
			AddRow("02-002", "补水量", "t", at.In(beijing), nil, nil, nil, nil, "999", ""))
	mock.ExpectQuery("EXEC dbo.usp_查询站区日结算").WithArgs("2026-11-20", "2026-11-21", "02-001-01,02-002-01,02-002-02").
		WillReturnRows(sqlmock.NewRows([]string{"统计日期", "站区编码", "测点编码", "单位", "完整日用量", "已结算小计"}).
			AddRow("2026-11-20", "02-002-01", "ER_MakeupFlowTotal", "t", "4", "999").
			AddRow("2026-11-21", "02-002-02", "ER_MakeupFlowTotal", "t", "0", nil).
			AddRow("2026-11-21", "02-001-01", "ER_ActiveEnergyTotal", "kWh", "990", nil))
	mock.ExpectClose()
	result, err := s.queryEnergyIntensity(ctx, stored, view, Request{Mode: "intensity", From: "2026-11-20", To: "2026-11-21"}, at)
	if err != nil || len(result.Statistics) != 13 {
		t.Fatalf("unexpected result: %d rows, %v", len(result.Statistics), err)
	}
	got := map[string]Statistic{}
	for _, row := range result.Statistics {
		got[row.Metric+"/"+row.Station] = row
	}
	for key, want := range map[string]string{
		"heat/02-003": "0.500000000000", "electricity/02-001": "0.300000000000",
		"water/02-002-01": "0.100000000000", "water/02-002-02": "0.000000000000",
	} {
		if value(got[key].Intensity) != want {
			t.Errorf("%s intensity = %s, want %s", key, value(got[key].Intensity), want)
		}
	}
	if got["heat/02-003"].Name != "国奥一二期站" || got["water/02-001-01"].Intensity != nil ||
		got["heat/02-001"].Station != "" || got["water/02-002"].Station != "" {
		t.Fatalf("unexpected meter name or scope: %+v", got)
	}
}

func TestWholeSeasonUsesAllSitesIncludingMissingSites(t *testing.T) {
	s, source, _ := fixture(t)
	ctx := context.Background()
	view, err := s.SaveScreen(ctx, Screen{Name: "日报", Kind: "daily", SourceID: source.ID})
	if err != nil {
		t.Fatal(err)
	}
	stored, _, err := s.source(ctx, view.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	mock := mockDB(t, s)
	mock.MatchExpectationsInOrder(false)
	mock.ExpectQuery("SELECT TOP \\(257\\)").WillReturnRows(sqlmock.NewRows([]string{"StationCode", "StationName"}).
		AddRow("02-002-01", "北三南线").AddRow("02-002-02", "北三光明区").AddRow("03-004-01", "桃源高区"))
	at := time.Date(2026, 11, 6, 4, 0, 0, 0, time.UTC)
	for _, day := range []time.Time{at.AddDate(0, 0, -1), at} {
		mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, day.Format("2006-01-02"), false, at).
			WillReturnRows(statisticRows(true).AddRow("02-002", "补水量", "t", day.In(beijing), nil, nil, nil, nil, "2.5", ""))
	}
	mock.ExpectClose()
	result, err := s.queryWholeSeason(ctx, stored, view, Request{Mode: "season", Date: "2026-11-06"}, at)
	if err != nil || len(result.Statistics) != 6 || result.Statistics[2].Station != "02-002" || value(result.Statistics[2].DayUsage) != "5.000000000000" ||
		result.Statistics[5].Station != "03-004" || result.Statistics[5].DayUsage != nil {
		t.Fatalf("all-site season: %+v, %v", result.Statistics, err)
	}
}

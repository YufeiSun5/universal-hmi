package externaldata

import (
	"context"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestCockpitRankingRetainsStationsWithoutUsage(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	stamp := day.Format(time.RFC3339)
	zero, positive := "0", "10"
	totals := cockpitTotals([]Statistic{
		{Station: "01-001", Name: "中心站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp},
		{Station: "01-005", Name: "怡景华府站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &zero},
		{Station: "01-003", Name: "香港广场站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &positive},
	}, day, day.Add(time.Hour), 1)
	rank := totals["ranking"].([]cockpitRank)
	if len(rank) != 8 || rank[0].ID != "01-003" ||
		rank[1].Value == nil || *rank[1].Value != 0 || rank[2].ID != "01-001" || rank[2].Value != nil {
		t.Fatalf("unexpected station ranking: %+v", rank)
	}
}

func TestCockpitIncludesValidClosedHoursAndPreservesGaps(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	var rows []Statistic
	for hour, state := range []string{"有效", "有效含异常", "截至采样有效", "成员不完整", "有效"} {
		stamp := day.Add(time.Duration(hour) * time.Hour).Format(time.RFC3339)
		for _, site := range heatSettlementSites {
			amount, status := "5", state
			if hour == 3 && site.Code == "01-001" {
				status = "有效"
			}
			rows = append(rows, Statistic{
				Station: site.Code, Name: site.Name, Label: "一次网耗热量", Unit: "GJ",
				Hour: &stamp, HourUsage: &amount, HourStatus: &status,
			})
		}
	}
	totals := cockpitTotals(rows, day, day.Add(4*time.Hour+50*time.Minute), 4)
	hours := totals["hours"].([]*float64)
	for i, amount := range hours {
		if i < 3 {
			if amount == nil || *amount != 40 {
				t.Fatalf("hour %d: expected 40 GJ, received %v", i, amount)
			}
		} else if amount != nil {
			t.Fatalf("hour %d: unexpectedly included %v", i, *amount)
		}
	}
	partial := totals["partial_hours"].([]*float64)
	coverage := totals["hour_coverage"].([]int)
	if partial[3] == nil || *partial[3] != 5 || partial[4] != nil ||
		coverage[3] != 1 || coverage[4] != 0 || totals["heat_station_count"] != 8 {
		t.Fatalf("partial data mismatched: %+v, %+v", partial, coverage)
	}
}

func TestCockpitDailyUsageKeepsValidSubtotalsSeparate(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	stamp := day.Format(time.RFC3339)
	amount, zero, valid, missing := "10", "0", "截至采样有效", "成员不完整"
	totals := cockpitTotals([]Statistic{
		{Station: "01-001", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &amount, DayStatus: &valid},
		{Station: "01-003", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &amount, DayStatus: &missing},
		{Station: "01-001", Label: "补水量", Unit: "t", Hour: &stamp, DayUsage: &zero, DayStatus: &valid},
	}, day, day.Add(time.Hour), 1)
	full := totals["metrics"].(map[string]*float64)
	partial := totals["partial_metrics"].(map[string]*float64)
	coverage := totals["metric_coverage"].(map[string]int)
	if full["heat"] != nil || partial["heat"] == nil || *partial["heat"] != 10 || coverage["heat"] != 1 ||
		full["water"] != nil || partial["water"] == nil || *partial["water"] != 0 || coverage["water"] != 1 ||
		full["electricity"] != nil || partial["electricity"] != nil || coverage["electricity"] != 0 {
		t.Fatalf("inconsistent daily summary: %+v", totals)
	}
}

func TestCockpitHeatUsesSettlementSitesWhileWaterAndPowerUseAllSites(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	stamp := day.Format(time.RFC3339)
	hourStatus, dayStatus := "有效", "截至采样有效"
	var rows []Statistic
	add := func(site, label, unit, amount string) {
		rows = append(rows, Statistic{
			Station: site, Label: label, Unit: unit, Hour: &stamp,
			HourUsage: &amount, HourStatus: &hourStatus, DayUsage: &amount, DayStatus: &dayStatus,
		})
	}
	for _, site := range []string{"01-001", "01-003", "01-005", "02-002", "02-003", "03-001", "04-001", "04-003"} {
		add(site, "一次网耗热量", "GJ", "10")
		add(site, "补水量", "t", "2")
		add(site, "耗电量", "kWh", "3")
	}
	// 新北站和红光美苑首站的热量分别与北站和西站共用计量。
	for _, site := range []string{"02-001", "03-003"} {
		add(site, "一次网耗热量", "GJ", "10")
		add(site, "补水量", "t", "9")
		add(site, "耗电量", "kWh", "8")
	}
	result := cockpitTotals(rows, day, day.Add(time.Hour), 1)
	metrics := result["metrics"].(map[string]*float64)
	for metric, want := range map[string]float64{"heat": 80, "water": 34, "electricity": 40} {
		if got := metrics[metric]; got == nil || *got != want {
			t.Errorf("%s: expected %g, got %v", metric, want, got)
		}
	}
	hours := result["hours"].([]*float64)
	stationHours := result["station_hours"].(map[string][]*float64)
	if result["station_count"] != 10 || result["heat_station_count"] != 8 ||
		hours[0] == nil || *hours[0] != 80 || len(stationHours) != 8 ||
		stationHours["02-001"] != nil || stationHours["03-003"] != nil {
		t.Fatalf("unexpected station scope: %+v", result)
	}
	for _, row := range result["ranking"].([]cockpitRank) {
		if stationHours[row.ID] == nil {
			t.Errorf("rank contains a station outside the heat scope: %s", row.ID)
		}
	}
}

func TestCockpitRankingUsesAreaAndRetainsUnconfiguredSites(t *testing.T) {
	north, west, zero := 100.0, 80.0, 0.0
	raw := []cockpitRank{
		{ID: "02-002", Name: "北站", Value: &north},
		{ID: "03-001", Name: "西站", Value: &west},
		{ID: "04-001", Name: "南站", Value: &zero},
		{ID: "04-003", Name: "张屯站", Value: &north},
	}
	got := CockpitRankPerArea(map[string]any{"ranking": raw}, map[string]float64{
		"02-002": 10000, "03-001": 2000, "04-001": 4000,
	})
	if len(got) != len(raw) || got[0].ID != "03-001" || *got[0].Value != .04 ||
		got[1].ID != "02-002" || *got[1].Value != .01 ||
		got[2].ID != "04-001" || *got[2].Value != 0 || got[3].ID != "04-003" || got[3].Value != nil {
		t.Fatalf("unexpected area ranking: %+v", got)
	}
	if raw[0].ID != "02-002" || *raw[0].Value != 100 || *raw[1].Value != 80 {
		t.Fatalf("cached heat totals were changed: %+v", raw)
	}
}

func TestCockpitPowerTrendsReadStationsSharingASampleColumn(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Date(2026, 11, 19, 5, 30, 30, 0, time.UTC)
	at := now.Truncate(time.Minute)
	mock.ExpectQuery("(?s)SELECT s.StationCode,p.SampleColumn,p.Unit.*p.PointCode='ER_SecondaryHeatRate'").
		WithArgs("01-001-01,01-002-01").
		WillReturnRows(sqlmock.NewRows([]string{"StationCode", "SampleColumn", "Unit"}).
			AddRow("01-001-01", "Value13", "GJ/h").
			AddRow("01-002-01", "Value13", "kW"))
	mock.ExpectQuery("SELECT s.StationCode,sample.SampleTime").
		WithArgs("01-001-01,01-002-01", at.Add(-119*time.Minute), now).
		WillReturnRows(sqlmock.NewRows([]string{"StationCode", "SampleTime", "Value"}).
			AddRow("01-001-01", at, "36").
			AddRow("01-002-01", at, "10000"))
	values, err := cockpitPowerTrends(context.Background(), db, []string{"01-001-01", "01-002-01"}, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"01-001-01", "01-002-01"} {
		series := values[id]
		if len(series) != 120 || series[118] != nil || series[119] == nil || *series[119] != 10 {
			t.Fatalf("unexpected trend for %s", id)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

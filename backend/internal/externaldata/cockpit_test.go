package externaldata

import (
	"context"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestCockpitDailyUsageComesFromEnergyManagement(t *testing.T) {
	s, source, _ := fixture(t)
	s.pools = make(map[string]*databaseLease)
	t.Cleanup(s.Close)
	ctx := context.Background()
	view, err := s.SaveScreen(ctx, Screen{Name: "能耗", SourceID: source.ID, Kind: "energy"})
	if err != nil {
		t.Fatal(err)
	}
	stored, _, err := s.source(ctx, view.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 20, 2, 21, 13, 0, time.UTC)
	currentHour := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	previousHour := currentHour.Add(-time.Hour)
	valid, partial := "截至采样有效", "部分有效；成员缺数"
	energyRows := func() *sqlmock.Rows {
		return statisticRows(true).
			AddRow("04-003", "一次网耗热量", "GJ", currentHour, nil, nil, "10", valid, "100", valid).
			AddRow("02-001", "一次网耗热量", "GJ", currentHour, nil, nil, "10", valid, "2000", valid).
			AddRow("04-003", "耗电量", "kWh", currentHour, nil, nil, "0", valid, "0", valid).
			AddRow("04-003", "补水量", "t", currentHour, nil, nil, "1", valid, "10.5", valid).
			AddRow("01-001", "补水量", "t", currentHour, nil, nil, "1", partial, "1000", partial)
	}
	mock := mockDB(t, s)
	mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, "2026-11-20", false, at).WillReturnRows(energyRows())
	mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, "2026-11-20", false, at).WillReturnRows(energyRows())
	mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, "2026-11-20", true, at).
		WillReturnRows(statisticRows(true).
			AddRow("04-003", "一次网耗热量", "GJ", previousHour, nil, nil, "10", valid, "900", valid).
			AddRow("04-003", "一次网耗热量", "GJ", currentHour, nil, nil, "10", valid, "1000", valid).
			AddRow("04-003", "耗电量", "kWh", currentHour, nil, nil, "7", valid, "70", valid).
			AddRow("04-003", "补水量", "t", currentHour, nil, nil, "8", valid, "80", valid))
	mock.ExpectClose()
	defer s.Close()

	overview, err := s.queryStatistics(ctx, stored, view, Request{Mode: "current"}, at)
	if err != nil {
		t.Fatal(err)
	}
	if len(overview.Statistics) != 5 || value(overview.Statistics[0].DayUsage) != "1000" ||
		value(overview.Statistics[1].DayUsage) != "2000" {
		t.Fatalf("energy management lost existing rows: %+v", overview.Statistics)
	}

	today, err := s.CockpitHistory(ctx, view.ID, "today", nil, at)
	if err != nil {
		t.Fatal(err)
	}
	cached, err := s.CockpitHistory(ctx, view.ID, "today", nil, at.Add(10*time.Second))
	if err != nil || !cached["at"].(time.Time).Equal(at) {
		t.Fatalf("cockpit did not reuse the loaded minute: %v", err)
	}
	wantByMetric := map[string]float64{"heat": 100, "electricity": 0, "water": 10.5}
	subtotals := today["partial_metrics"].(map[string]*float64)
	rankings := today["metric_rankings"].(map[string][]cockpitRank)
	for metric, want := range wantByMetric {
		got := subtotals[metric]
		if got == nil || *got != want {
			t.Errorf("%s: got %v, want %f from the existing energy query", metric, got, want)
		}
		rank := rankings[metric][0]
		if rank.ID != "04-003" || rank.Value == nil || *rank.Value != want {
			t.Errorf("%s: expected 张屯 with %f, got %+v", metric, want, rank)
		}
	}
	heatHours := today["station_hours"].(map[string][]*float64)["04-003"]
	if heatHours[9] == nil || *heatHours[9] != 10 || heatHours[10] != nil {
		t.Fatalf("expected completed hourly value from the hourly query: %v", heatHours)
	}
}

func TestCockpitRankingRetainsStationsWithoutUsage(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	stamp := day.Format(time.RFC3339)
	zero, positive, valid := "0", "10", "截至采样有效"
	totals := cockpitTotals([]Statistic{
		{Station: "01-001", Name: "中心站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp},
		{Station: "01-005", Name: "怡景华府站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &zero, DayStatus: &valid},
		{Station: "01-003", Name: "香港广场站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &positive, DayStatus: &valid},
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
	amount, zero, valid, partialDay, missing := "10", "0", "截至采样有效", "部分有效；时段缺失", "成员不完整"
	totals := cockpitTotals([]Statistic{
		{Station: "01-001", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &amount, DayStatus: &valid},
		{Station: "01-003", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &amount, DayStatus: &partialDay},
		{Station: "01-001", Label: "补水量", Unit: "t", Hour: &stamp, DayUsage: &zero, DayStatus: &valid},
		{Station: "01-003", Label: "耗电量", Unit: "kWh", Hour: &stamp, DayUsage: &amount, DayStatus: &missing},
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
	partial := result["partial_metrics"].(map[string]*float64)
	if got := metrics["heat"]; got == nil || *got != 80 {
		t.Errorf("heat: expected 80, got %v", got)
	}
	for metric, want := range map[string]float64{"water": 34, "electricity": 40} {
		if got := partial[metric]; metrics[metric] != nil || got == nil || *got != want {
			t.Errorf("%s: expected subtotal %g, got %v", metric, want, got)
		}
	}
	hours := result["hours"].([]*float64)
	stationHours := result["station_hours"].(map[string][]*float64)
	if result["station_count"] != 17 || result["heat_station_count"] != 8 ||
		hours[0] == nil || *hours[0] != 80 || len(stationHours) != 8 ||
		stationHours["02-001"] != nil || stationHours["03-003"] != nil {
		t.Fatalf("unexpected station scope: %+v", result)
	}
	for _, row := range result["ranking"].([]cockpitRank) {
		if stationHours[row.ID] == nil {
			t.Errorf("rank contains a station outside the heat scope: %s", row.ID)
		}
		if row.ID == "02-003" && row.Name != "国奥一二期站" {
			t.Errorf("expected exact heat meter name, got %s", row.Name)
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
	got := CockpitUnitRankings(map[string]any{"metric_rankings": map[string][]cockpitRank{"heat": raw}}, nil, CockpitAreas{Heat: map[string]float64{
		"02-002": 10000, "03-001": 2000, "04-001": 4000,
	}})["heat"]
	if len(got) != len(raw) || got[0].ID != "03-001" || *got[0].Value != .04 ||
		got[1].ID != "02-002" || *got[1].Value != .01 ||
		got[2].ID != "04-001" || *got[2].Value != 0 || got[3].ID != "04-003" || got[3].Value != nil {
		t.Fatalf("unexpected area ranking: %+v", got)
	}
	if raw[0].ID != "02-002" || *raw[0].Value != 100 || *raw[1].Value != 80 {
		t.Fatalf("cached heat totals were changed: %+v", raw)
	}
}

func TestCockpitUnitRankingsApplyCorrectRosterAndCompareSameHours(t *testing.T) {
	day := time.Date(2026, 11, 20, 0, 0, 0, 0, beijing)
	makeDay := func(date time.Time, amount, first, second string) map[string]any {
		var rows []Statistic
		good, complete := "有效", "截至采样有效"
		for _, code := range []string{"01-001", "02-001"} {
			for _, metric := range [][2]string{{"ER_TotalHeat", "GJ"}, {"ER_ActiveEnergyTotal", "kWh"}, {"ER_MakeupFlowTotal", "t"}} {
				for i, v := range []string{first, second} {
					hour := date.Add(time.Duration(i) * time.Hour).Format(time.RFC3339)
					rows = append(rows, Statistic{Station: code, Name: siteName(code), Label: metric[0], Unit: metric[1], Hour: &hour, HourUsage: &v, HourStatus: &good, DayUsage: &amount, DayStatus: &complete})
				}
			}
		}
		return cockpitTotals(rows, date, day.Add(2*time.Hour), 2)
	}
	today := makeDay(day, "100", "30", "20")
	yesterday := makeDay(day.AddDate(0, 0, -1), "600", "10", "30")
	areas := CockpitAreas{
		Heat:        map[string]float64{"01-001": 10000},
		Electricity: map[string]float64{"02-001": 2500},
		Water:       map[string]float64{"02-001": 5000},
	}
	got := CockpitUnitRankings(today, yesterday, areas)
	if len(got["heat"]) != 8 || got["heat"][0].ID != "01-001" || *got["heat"][0].Value != .01 || *got["heat"][0].Delta != 25 {
		t.Fatalf("unexpected heat coverage: %+v", got["heat"])
	}
	for metric, want := range map[string]float64{"electricity": .04, "water": .02} {
		if len(got[metric]) != 17 || got[metric][0].ID != "02-001" || *got[metric][0].Value != want || *got[metric][0].Delta != 25 {
			t.Fatalf("unexpected %s coverage: %+v", metric, got[metric])
		}
		foundNew := false
		for _, site := range got[metric] {
			if site.ID == "03-004" && site.Name == "壹品桃源三期" && site.Value == nil {
				foundNew = true
			}
		}
		if !foundNew {
			t.Errorf("%s did not retain the new site with a missing value", metric)
		}
	}
	got = CockpitUnitRankings(today, nil, areas)
	if got["water"][0].Delta != nil || *got["water"][0].Value != .02 {
		t.Fatalf("missing yesterday should leave comparison blank: %+v", got["water"])
	}
}

func TestCockpitPartialUsageIsExcludedFromUnitRankings(t *testing.T) {
	day := time.Date(2026, 11, 20, 0, 0, 0, 0, beijing)
	hour := day.Format(time.RFC3339)
	partial, complete, amount, zero := "部分有效；成员缺数", "截至采样有效", "10", "0"
	result := cockpitTotals([]Statistic{
		{Station: "01-001", Label: "补水量", Unit: "t", Hour: &hour, DayUsage: &amount, DayStatus: &partial},
		{Station: "01-001", Label: "耗电量", Unit: "kWh", Hour: &hour, DayUsage: &amount, DayStatus: &partial},
		{Station: "01-001", Label: "一次网耗热量", Unit: "GJ", Hour: &hour, DayUsage: &amount, DayStatus: &partial},
		{Station: "01-003", Label: "补水量", Unit: "t", Hour: &hour, DayUsage: &zero, DayStatus: &complete},
		{Station: "01-003", Label: "耗电量", Unit: "kWh", Hour: &hour, DayUsage: &zero, DayStatus: &complete},
		{Station: "01-003", Label: "一次网耗热量", Unit: "GJ", Hour: &hour, DayUsage: &zero, DayStatus: &complete},
	}, day, day.Add(time.Hour), 1)
	area := map[string]float64{"01-001": 100, "01-003": 100}
	for metric, rank := range CockpitUnitRankings(result, nil, CockpitAreas{Heat: area, Electricity: area, Water: area}) {
		if rank[0].ID != "01-003" || rank[0].Value == nil || *rank[0].Value != 0 {
			t.Fatalf("%s valid zero must rank ahead of missing values: %+v", metric, rank)
		}
		for _, row := range rank[1:] {
			if row.Value != nil {
				t.Errorf("%s unexpected intensity: %+v", metric, row)
			}
		}
		if got := result["partial_metrics"].(map[string]*float64)[metric]; got == nil || *got != 0 {
			t.Fatalf("%s subtotal must contain only the confirmed zero: %v", metric, got)
		}
	}
}

func TestCockpitYesterdayWholeDayUsageCannotFillASameHourGap(t *testing.T) {
	day := time.Date(2026, 11, 20, 0, 0, 0, 0, beijing)
	valid, noData, hourlyUsage, dailyUsage := "截至采样有效", "无可用数据", "10", "240"
	makeDay := func(d time.Time, gap, closed int) map[string]any {
		rows := make([]Statistic, 24)
		for h := range rows {
			stamp := d.Add(time.Duration(h) * time.Hour).Format(time.RFC3339)
			rows[h] = Statistic{Station: "04-003", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp,
				HourStatus: &valid, HourUsage: &hourlyUsage, DayStatus: &valid, DayUsage: &dailyUsage}
			if h == gap {
				rows[h].HourUsage, rows[h].HourStatus = nil, &noData
			}
		}
		return cockpitTotals(rows, d, day.Add(10*time.Hour), closed)
	}
	today := makeDay(day, -1, 10)
	yesterday := day.AddDate(0, 0, -1)
	areas := CockpitAreas{Heat: map[string]float64{"04-003": 100}}
	for _, gap := range []int{-1, 9, 10} {
		rank := CockpitUnitRankings(today, makeDay(yesterday, gap, 24), areas)["heat"][0]
		if rank.ID != "04-003" || rank.Value == nil || (rank.Delta == nil) != (gap == 9) {
			t.Fatalf("gap %d: unexpected result %+v", gap, rank)
		}
	}
}

func TestCockpitUsageDaysSharesPriorDatesAcrossMonthAndWeek(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	today := time.Date(2026, 11, 3, 0, 0, 0, 0, beijing)
	now := today.Add(8 * time.Hour)
	for day := today.AddDate(0, 0, -6); day.Before(today); day = day.AddDate(0, 0, 1) {
		at := day.Add(23 * time.Hour)
		rows := statisticRows(true)
		switch day.Format("01-02") {
		case "11-01":
			rows.AddRow("01-001", "一次网耗热量", "GJ", at, nil, nil, "10", "有效", "100", "截至采样有效").
				AddRow("01-003", "一次网耗热量", "GJ", at, nil, nil, nil, "无可用数据", "40", "部分有效；时段缺失；含异常").
				AddRow("02-001", "一次网耗热量", "GJ", at, nil, nil, nil, "无可用数据", "100", "部分有效").
				AddRow("01-001", "耗电量", "kWh", at, nil, nil, nil, "无可用数据", "200", "部分有效").
				AddRow("01-003", "耗电量", "kWh", at, nil, nil, nil, "无可用数据", "50", "部分有效").
				AddRow("02-001", "耗电量", "kWh", at, nil, nil, nil, "无可用数据", "20", "部分有效").
				AddRow("01-001", "补水量", "t", at, nil, nil, nil, "无可用数据", nil, "部分有效")
		case "11-02":
			rows.AddRow("01-001", "补水量", "t", at, nil, nil, nil, "无可用数据", "0", "截至采样有效").
				AddRow("01-003", "补水量", "m³", at, nil, nil, nil, "无可用数据", "70", "部分有效").
				AddRow("01-001", "耗电量", "kWh", at, nil, nil, nil, "无可用数据", "30", "口径待确认")
		default:
			rows.AddRow("01-001", "一次网耗热量", "GJ", at, nil, nil, "10", "有效", "100", "截至采样有效")
		}
		mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").WithArgs(nil, nil, true, day.Format("2006-01-02"), false, now.UTC()).WillReturnRows(rows)
	}
	result, err := cockpitUsageDays(context.Background(), db, today, now)
	if err != nil {
		t.Fatal(err)
	}
	month := result["month"].(map[string]any)
	week := result["week"].(map[string]any)
	if len(month["labels"].([]string)) != 2 || len(week["labels"].([]string)) != 6 {
		t.Fatalf("unexpected month/week: %+v", result)
	}
	for period, start := range map[string]int{"month": 0, "week": 4} {
		series := result[period].(map[string]any)
		partial := series["partial"].(map[string][]bool)
		for _, check := range []struct {
			metric string
			day    int
			want   float64
		}{{"heat", 0, 100}, {"water", 1, 0}} {
			values := series[check.metric].([]*float64)
			got := values[start+check.day]
			if got == nil || *got != check.want || !partial[check.metric][start+check.day] {
				t.Errorf("%s %s: expected partial value %g, got %+v", period, check.metric, check.want, got)
			}
			if other := start + 1 - check.day; values[other] != nil || partial[check.metric][other] {
				t.Errorf("%s %s: unavailable day should remain empty", period, check.metric)
			}
		}
		if values := series["electricity"].([]*float64); values[start] != nil || values[start+1] != nil {
			t.Errorf("%s partial-only electricity must stay blank: %+v", period, values)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
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

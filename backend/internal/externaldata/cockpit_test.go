package externaldata

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
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
		{Station: "01-002", Name: "景泰站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &zero},
		{Station: "01-003", Name: "香港广场站", Label: "一次网耗热量", Unit: "GJ", Hour: &stamp, DayUsage: &positive},
	}, day, day.Add(time.Hour), 1)
	rank := totals["ranking"].([]cockpitRank)
	if len(rank) != 3 || rank[0].ID != "01-003" ||
		rank[1].Value == nil || *rank[1].Value != 0 || rank[2].ID != "01-001" || rank[2].Value != nil {
		t.Fatalf("unexpected station ranking: %+v", rank)
	}
}

func TestCockpitIncludesValidClosedHoursAndPreservesGaps(t *testing.T) {
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	var rows []Statistic
	for hour, state := range []string{"有效", "有效含异常", "截至采样有效", "成员不完整", "有效"} {
		stamp := day.Add(time.Duration(hour) * time.Hour).Format(time.RFC3339)
		for _, site := range []string{"01-001", "01-002"} {
			amount, status := "5", state
			rows = append(rows, Statistic{
				Station: site, Name: site, Label: "一次网耗热量", Unit: "GJ",
				Hour: &stamp, HourUsage: &amount, HourStatus: &status,
			})
		}
	}
	totals := cockpitTotals(rows, day, day.Add(4*time.Hour+50*time.Minute), 4)
	hours := totals["hours"].([]*float64)
	for i, amount := range hours {
		if i < 3 {
			if amount == nil || *amount != 10 {
				t.Fatalf("hour %d: expected 10 GJ, received %v", i, amount)
			}
		} else if amount != nil {
			t.Fatalf("hour %d: unexpectedly included %v", i, *amount)
		}
	}
}

func TestCockpitZoneHeatIncludesEveryEnabledZoneAndBatchesStatistics(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	day := time.Date(2026, 11, 19, 0, 0, 0, 0, beijing)
	now := day.Add(2 * time.Hour)
	index := sqlmock.NewRows([]string{"StationCode", "StationName", "输出列"})
	var mapped []string
	for i := 1; i <= 9; i++ {
		id := fmt.Sprintf("01-001-%02d", i)
		mapped = append(mapped, id)
		index.AddRow(id, id, "Value06")
	}
	index.AddRow("01-001-10", "未配置站区", nil)
	mock.ExpectQuery("SELECT s.StationCode,s.StationName,w.输出列").WillReturnRows(index)
	for from := 0; from < len(mapped); from += 8 {
		batch := mapped[from:min(from+8, len(mapped))]
		statistics := statisticRows(false)
		for _, id := range batch {
			statistics.AddRow(id, id, "Value06", "热", "GJ", day, nil,
				"8.2", nil, nil, "有效", nil, nil, nil, nil)
		}
		mock.ExpectQuery("EXEC dbo.usp_查询站区当前统计").
			WithArgs(strings.Join(batch, ","), nil, false, "2026-11-19", true, now.UTC()).
			WillReturnRows(statistics)
	}
	result, err := cockpitZoneHeat(context.Background(), db, day, now)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(result["rows"])
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Name   string
		Values []*float64
	}
	if err = json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 10 || rows[8].Values[0] == nil || *rows[8].Values[0] != 8.2 ||
		rows[9].Name != "未配置站区" || rows[9].Values[0] != nil {
		t.Fatalf("missing a mapped or unconfigured zone: %s", data)
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
	mock.ExpectQuery("SELECT s.StationCode,p.SampleColumn,p.Unit").
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

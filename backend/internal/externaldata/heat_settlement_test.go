package externaldata

import (
	"context"
	"errors"
	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
	"time"
)

func heatValue(v string) *string { return &v }
func settlementSamples(date, amount string) []Statistic {
	out := []Statistic{}
	for _, s := range heatSettlementSites {
		out = append(out, Statistic{Station: s.Code, Date: date, Label: "一次网耗热量", Unit: "GJ", DayUsage: heatValue(amount), DayStatus: heatValue("截至采样有效")})
	}
	return out
}
func TestHeatSettlementBoundsAndSeasonIncludesApril5(t *testing.T) {
	now := time.Date(2028, 4, 6, 0, 0, 0, 0, beijing)
	a, b, e := heatSettlementBounds(Request{Mode: "settlement_season", Date: "2028-04-05", UnitPrice: "2.123456"}, now)
	if e != nil || a.Format("2006-01-02") != "2027-11-05" || b.Format("2006-01-02") != "2028-04-05" || int(b.Sub(a).Hours()/24)+1 != 153 {
		t.Fatal(a, b, e)
	}
	a, b, e = heatSettlementBounds(Request{Mode: "settlement_monthly", Date: "2028-02-14", UnitPrice: "0"}, now)
	if e != nil || b.Day() != 29 || a.Day() != 1 {
		t.Fatal(a, b, e)
	}
	for _, in := range []Request{
		{Mode: "settlement_daily", Date: "2027-11-05", From: "2027-11-05", To: "2027-12-06", UnitPrice: "1"},
		{Mode: "settlement_hourly", Date: "2029-11-05", UnitPrice: "1"},
		{Mode: "settlement_daily", Date: "2027-11-05", Station: "02-001", UnitPrice: "1"},
	} {
		if _, _, e = heatSettlementBounds(in, now); e == nil {
			t.Fatal(in)
		}
	}
}
func TestHeatSettlementFixedEightDecimalRoundingZeroAndMissing(t *testing.T) {
	day := time.Date(2027, 11, 5, 0, 0, 0, 0, beijing)
	in := Request{Mode: "settlement_daily", UnitPrice: "0.05"}
	data := settlementSamples("2027-11-05", "0.1")
	// A non-settlement site never enters this report, even with extreme readings.
	data = append(data, Statistic{Station: "02-001", Date: "2027-11-05", Label: "一次网耗热量", Unit: "GJ", DayUsage: heatValue("999999"), DayStatus: heatValue("有效")})
	r, e := buildAtPrice(in, day, day, day.AddDate(0, 0, 1), data)
	if e != nil || len(r.Rows) != 8 || value(r.TotalHeat) != "0.800000000000" || value(r.TotalAmount) != "0.08" || r.Rows[3].Station != "02-002" || r.Rows[2].Name != "怡景华府站" {
		t.Fatal(r, e)
	}
	data[0].DayUsage = heatValue("0")
	data[1].DayUsage = nil
	data[2].DayStatus = heatValue("成员不完整")
	r, e = buildAtPrice(in, day, day, day.AddDate(0, 0, 1), data)
	if e != nil || value(r.Rows[0].Amount) != "0.00" || r.Rows[1].Amount != nil || value(r.Rows[2].Heat) != "0.100000000000" || r.Incomplete != 2 || value(r.TotalAmount) != "0.06" || value(r.TotalHeat) != "0.600000000000" {
		t.Fatal(r, e)
	}
	data = append(data, data[0])
	if _, e = buildAtPrice(in, day, day, day.AddDate(0, 0, 1), data); e == nil {
		t.Fatal("accepted duplicates")
	}
}
func TestHeatSettlementCurrentSeasonUsesElapsedDaysAndKeepsGaps(t *testing.T) {
	start := time.Date(2027, 11, 5, 0, 0, 0, 0, beijing)
	end := time.Date(2028, 4, 5, 0, 0, 0, 0, beijing)
	now := start.Add(36 * time.Hour)
	data := append(settlementSamples("2027-11-05", "12345678901234567890.12345678"), settlementSamples("2027-11-06", "0.00000001")...)
	in := Request{Mode: "settlement_season", UnitPrice: "2"}
	r, e := buildAtPrice(in, start, end, now, data)
	if e != nil || r.Incomplete != 0 || value(r.Rows[0].Heat) != "12345678901234567890.123456790000" || r.Rows[0].Status != "截至当前统计" {
		t.Fatal(r, e)
	}
	data = data[:len(data)-1]
	r, e = buildAtPrice(in, start, end, now, data)
	if e != nil || r.Incomplete != 1 || value(r.Rows[7].Heat) != "12345678901234567890.123456780000" || r.TotalAmount == nil {
		t.Fatal(r, e)
	}
}
func TestHeatSettlementHourSlotsDoNotFillMissingOrFuture(t *testing.T) {
	start := time.Date(2027, 11, 5, 0, 0, 0, 0, beijing)
	now := start.Add(90 * time.Minute)
	data := settlementSamples("2027-11-05", "0")
	for i := range data {
		data[i].Hour = heatValue("2027-11-05T00:00:00+08:00")
		data[i].HourUsage = heatValue("3")
		data[i].HourStatus = heatValue("截至采样有效")
	}
	r, e := buildAtPrice(Request{Mode: "settlement_hourly", UnitPrice: "2"}, start, start, now, data)
	if e != nil || len(r.Rows) != 16 || r.Incomplete != 8 || value(r.Rows[0].Amount) != "6.00" || r.Rows[8].Heat != nil {
		t.Fatal(r, e)
	}
}
func TestHeatSettlementUsesEnergyAuthorizationAndWholeStatistics(t *testing.T) {
	s, src, history := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "能耗", SourceID: src.ID, Kind: "energy"})
	if e != nil {
		t.Fatal(e)
	}
	in := Request{Mode: "settlement_daily", Date: "2026-11-05", UnitPrice: "99999"}
	denied := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{history.ID}})
	if _, e = s.Query(denied, view.ID, in); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	if _, e = s.SaveHeatPrice(context.Background(), view.ID, HeatPriceChange{Year: 2026, UnitPrice: "25.12"}); e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	at := time.Date(2026, 11, 5, 23, 0, 0, 0, time.UTC)
	m.ExpectQuery("EXEC dbo.usp_").WithArgs(nil, nil, true, "2026-11-05", false, sqlmock.AnyArg()).WillReturnRows(statisticRows(true).AddRow("02-002", "一次网耗热量", "GJ", at, at, at, "0", "部分有效；时段缺失", "0", "部分有效；时段缺失"))
	m.ExpectClose()
	r, e := s.Query(actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}}), view.ID, in)
	if e != nil || r.HeatSettlement == nil || r.HeatSettlement.Incomplete != 8 || r.HeatSettlement.UnitPrice != "25.12" || value(r.HeatSettlement.Rows[3].Amount) != "0.00" {
		t.Fatal(r, e)
	}
	if e = m.ExpectationsWereMet(); e != nil {
		t.Fatal(e)
	}
}

func buildAtPrice(in Request, start, end, now time.Time, data []Statistic) (*HeatSettlement, error) {
	return buildHeatSettlement(in, start, end, now, data, HeatPrices{Revision: 1, Items: []HeatPrice{{Year: start.Year(), UnitPrice: in.UnitPrice}, {Year: start.Year() - 1, UnitPrice: in.UnitPrice}}})
}

func TestHeatSettlementKeepsNumbersIndependentOfDiagnosticStatus(t *testing.T) {
	day := time.Date(2026, 11, 5, 0, 0, 0, 0, beijing)
	for _, hourly := range []bool{false, true} {
		for _, status := range []string{"成员不完整", "部分小时有效", "口径待确认", "", "新增诊断状态"} {
			data := settlementSamples("2026-11-05", "12.34567890")
			mode := "settlement_daily"
			for i := range data {
				data[i].DayStatus = heatValue(status)
				if hourly {
					mode = "settlement_hourly"
					data[i].Hour = heatValue("2026-11-05T00:00:00+08:00")
					data[i].HourUsage = data[i].DayUsage
					data[i].HourStatus = heatValue(status)
				}
			}
			r, e := buildAtPrice(Request{Mode: mode, UnitPrice: "2"}, day, day, day.Add(30*time.Minute), data)
			if e != nil || value(r.Rows[0].Heat) != "12.345678900000" || value(r.Rows[0].Amount) != "24.69" || value(r.TotalAmount) != "197.52" {
				t.Fatalf("%s %q: %#v %v", mode, status, r, e)
			}
		}
	}
}

func TestHeatSettlementAggregatesAvailableDaysAndDoesNotInventZero(t *testing.T) {
	start := time.Date(2026, 11, 5, 0, 0, 0, 0, beijing)
	data := append(settlementSamples("2026-11-05", "10.25"), settlementSamples("2026-11-07", "2.5")...)
	data[0].DayUsage = heatValue("0")
	data[8].DayUsage = nil
	data[1].DayUsage = nil
	data[9].DayUsage = nil
	for _, mode := range []string{"settlement_monthly", "settlement_season"} {
		r, e := buildAtPrice(Request{Mode: mode, UnitPrice: "2"}, start, start.AddDate(0, 0, 2), start.AddDate(0, 0, 3), data)
		if e != nil || value(r.Rows[0].Heat) != "0.000000000000" || value(r.Rows[0].Amount) != "0.00" || r.Rows[1].Heat != nil || r.Rows[1].Amount != nil || value(r.Rows[2].Heat) != "12.750000000000" || value(r.Rows[2].Amount) != "25.50" || value(r.TotalHeat) != "76.500000000000" || value(r.TotalAmount) != "153.00" {
			t.Fatalf("%s: %#v %v", mode, r, e)
		}
	}
	r, e := buildAtPrice(Request{Mode: "settlement_daily", UnitPrice: "2"}, start, start, start.AddDate(0, 0, 1), nil)
	if e != nil || r.TotalHeat != nil || r.TotalAmount != nil {
		t.Fatal("all absent must stay absent", r, e)
	}
}

func TestHeatSettlementMissingPriceDoesNotEraseOtherAmounts(t *testing.T) {
	start := time.Date(2026, 11, 4, 0, 0, 0, 0, beijing)
	data := append(settlementSamples("2026-11-04", "10"), settlementSamples("2026-11-05", "5")...)
	r, e := buildHeatSettlement(Request{Mode: "settlement_daily"}, start, start.AddDate(0, 0, 1), start.AddDate(0, 0, 2), data, HeatPrices{Revision: 2, Items: []HeatPrice{{Year: 2026, UnitPrice: "2"}}})
	if e != nil || r.Rows[0].Amount != nil || value(r.Rows[0].Heat) != "10.000000000000" || value(r.Rows[8].Amount) != "10.00" || value(r.TotalHeat) != "120.000000000000" || value(r.TotalAmount) != "80.00" {
		t.Fatal(r, e)
	}
}

func TestHeatSettlementRejectsInvalidNumbersAndUnitsWithoutClearingOtherRows(t *testing.T) {
	day := time.Date(2026, 11, 5, 0, 0, 0, 0, beijing)
	data := settlementSamples("2026-11-05", "2")
	for i, v := range []string{"NaN", "-1", "1e9", "bad"} {
		data[i].DayUsage = heatValue(v)
	}
	data[4].Unit = "kWh"
	r, e := buildAtPrice(Request{Mode: "settlement_daily", UnitPrice: "3"}, day, day, day.AddDate(0, 0, 1), data)
	if e != nil || value(r.TotalHeat) != "6.000000000000" || value(r.TotalAmount) != "18.00" {
		t.Fatal(r, e)
	}
	for _, row := range r.Rows[:5] {
		if row.Heat != nil || row.Amount != nil {
			t.Fatal("invalid input became business value", row)
		}
	}
}

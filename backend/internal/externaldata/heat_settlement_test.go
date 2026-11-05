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
	for _, price := range []string{"-1", "NaN", "1e2", "1/2", "1.1234567", "100000000"} {
		if _, _, e = heatSettlementBounds(Request{Mode: "settlement_daily", Date: "2027-11-05", UnitPrice: price}, now); e == nil {
			t.Fatal(price)
		}
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
	r, e := buildHeatSettlement(in, day, day, day.AddDate(0, 0, 1), data)
	if e != nil || len(r.Rows) != 8 || value(r.TotalHeat) != "0.800000000000" || value(r.TotalAmount) != "0.08" || r.Rows[3].Station != "02-002" || r.Rows[2].Name != "怡景华府站" {
		t.Fatal(r, e)
	}
	data[0].DayUsage = heatValue("0")
	data[1].DayUsage = nil
	data[2].DayStatus = heatValue("成员不完整")
	r, e = buildHeatSettlement(in, day, day, day.AddDate(0, 0, 1), data)
	if e != nil || value(r.Rows[0].Amount) != "0.00" || r.Rows[1].Amount != nil || r.Rows[2].Heat != nil || r.Incomplete != 2 || r.TotalAmount != nil || r.TotalHeat != nil {
		t.Fatal(r, e)
	}
	data = append(data, data[0])
	if _, e = buildHeatSettlement(in, day, day, day.AddDate(0, 0, 1), data); e == nil {
		t.Fatal("accepted duplicates")
	}
}
func TestHeatSettlementCurrentSeasonUsesElapsedDaysAndKeepsGaps(t *testing.T) {
	start := time.Date(2027, 11, 5, 0, 0, 0, 0, beijing)
	end := time.Date(2028, 4, 5, 0, 0, 0, 0, beijing)
	now := start.Add(36 * time.Hour)
	data := append(settlementSamples("2027-11-05", "12345678901234567890.12345678"), settlementSamples("2027-11-06", "0.00000001")...)
	in := Request{Mode: "settlement_season", UnitPrice: "2"}
	r, e := buildHeatSettlement(in, start, end, now, data)
	if e != nil || r.Incomplete != 0 || value(r.Rows[0].Heat) != "12345678901234567890.123456790000" || r.Rows[0].Status != "截至当前统计" {
		t.Fatal(r, e)
	}
	data = data[:len(data)-1]
	r, e = buildHeatSettlement(in, start, end, now, data)
	if e != nil || r.Incomplete != 1 || r.Rows[7].Heat != nil || r.TotalAmount != nil {
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
	r, e := buildHeatSettlement(Request{Mode: "settlement_hourly", UnitPrice: "2"}, start, start, now, data)
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
	in := Request{Mode: "settlement_daily", Date: "2026-11-04", UnitPrice: "25.12"}
	denied := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{history.ID}})
	if _, e = s.Query(denied, view.ID, in); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	at := time.Date(2026, 11, 4, 23, 0, 0, 0, time.UTC)
	m.ExpectQuery("EXEC dbo.usp_").WithArgs(nil, nil, true, "2026-11-04", false, sqlmock.AnyArg()).WillReturnRows(statisticRows(true).AddRow("02-002", "一次网耗热量", "GJ", at, at, at, "0", "截至采样有效", "0", "截至采样有效"))
	m.ExpectClose()
	r, e := s.Query(actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}}), view.ID, in)
	if e != nil || r.HeatSettlement == nil || r.HeatSettlement.Incomplete != 7 || value(r.HeatSettlement.Rows[3].Amount) != "0.00" {
		t.Fatal(r, e)
	}
	if e = m.ExpectationsWereMet(); e != nil {
		t.Fatal(e)
	}
}

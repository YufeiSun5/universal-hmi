package externaldata

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestCustomReportNamedMappingDecimalsNullAndPermissions(t *testing.T) {
	s, source, _ := fixture(t)
	p := &ProcedureReport{Schema: "dbo", Name: "客户报表", Parameters: []ProcedureParameter{{Name: "开始日期", Label: "开始日期", Type: "date", Required: true}, {Name: "站点", Label: "站点", Type: "text"}}}
	view, err := s.SaveScreen(context.Background(), Screen{Name: "自定义", Kind: "custom", SourceID: source.ID, Procedure: p})
	if err != nil {
		t.Fatal(err)
	}
	date := "2026-11-05"
	malicious := "'; DROP TABLE x;--"
	m := mockDB(t, s)
	m.ExpectQuery(`EXEC \[dbo\].\[客户报表\] @开始日期=@p0,@站点=@p1`).WithArgs(date, malicious).WillReturnRows(sqlmock.NewRows([]string{"用量", "站点", "空值"}).AddRow("12345678901234567890.12345678", "八站", nil))
	m.ExpectClose()
	in := Request{Parameters: map[string]*string{"开始日期": &date, "站点": &malicious}}
	allowed := actor(authorization.Grants{ExternalScreenIDs: []string{view.ID}})
	result, err := s.Query(allowed, view.ID, in)
	if err != nil || len(result.ReportColumns) != 3 || value(result.ReportRows[0]["用量"]) != "12345678901234567890.12345678" || result.ReportRows[0]["空值"] != nil {
		t.Fatal(result, err)
	}
	if _, err = s.Query(actor(authorization.Grants{}), view.ID, in); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	if _, err = s.SaveScreen(allowed, view); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	view.Procedure = nil
	view.Name = "仅重命名"
	saved, err := s.SaveScreen(context.Background(), view)
	if err != nil || saved.Procedure == nil || saved.Procedure.Name != "客户报表" {
		t.Fatal(saved, err)
	}
}

func TestCustomReportRejectsUnsafeDefinitionsAndStaleFields(t *testing.T) {
	s, source, _ := fixture(t)
	for _, name := range []string{"dbo.report", "x];DROP TABLE a--", "report;WAITFOR", ""} {
		if _, err := s.SaveScreen(context.Background(), Screen{Name: "bad", Kind: "custom", SourceID: source.ID, Procedure: &ProcedureReport{Schema: "dbo", Name: name}}); err == nil {
			t.Fatal(name)
		}
	}
	if _, _, err := procedureQuery(&ProcedureReport{Schema: "dbo", Name: "good", Parameters: []ProcedureParameter{{Name: "date", Label: "日期", Type: "date", Required: true}}}, map[string]*string{}); err == nil {
		t.Fatal("missing required argument accepted")
	}
	bad := "1 OR 1=1"
	if _, err := procedureValue(ProcedureParameter{Type: "integer", Label: "数量"}, bad); err == nil {
		t.Fatal("integer injection accepted")
	}
	view, err := s.SaveScreen(context.Background(), Screen{Name: "mapped", Kind: "custom", SourceID: source.ID, Procedure: &ProcedureReport{Schema: "dbo", Name: "good"}, ReportLayouts: map[string]ReportLayout{"custom": {Columns: []ReportColumn{{Key: "热量", Label: "热量 GJ", Visible: true}}}}})
	if err != nil {
		t.Fatal(err)
	}
	m := mockDB(t, s)
	m.ExpectQuery("EXEC").WillReturnRows(sqlmock.NewRows([]string{"其它字段"}).AddRow("12"))
	m.ExpectClose()
	if _, err = s.Query(context.Background(), view.ID, Request{}); err == nil || !strings.Contains(err.Error(), "热量") {
		t.Fatal(err)
	}
}

func TestReportLayoutValidationPreservationAndConflict(t *testing.T) {
	s, _, view := fixture(t)
	d := 2
	view.ReportLayouts = map[string]ReportLayout{"table_123": {Columns: []ReportColumn{{Key: "热量", Label: "用量", Visible: true, Decimals: &d, Align: "right", Width: 180, Group: "本期"}}, GroupLabels: map[string]string{"source:heat": "本期供热"}, RowHeight: 40, HeaderColor: "#eaf2fa"}}
	saved, err := s.SaveScreen(context.Background(), view)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.SaveScreen(context.Background(), view); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	saved.ReportLayouts = nil
	saved.Name = "名称调整"
	saved, err = s.SaveScreen(context.Background(), saved)
	if err != nil || len(saved.ReportLayouts) != 1 || saved.ReportLayouts["table_123"].GroupLabels["source:heat"] != "本期供热" {
		t.Fatal(saved, err)
	}
	for _, layout := range []ReportLayout{{GroupLabels: map[string]string{"": "非法"}}, {GroupLabels: map[string]string{"source:x": ""}}, {RowHeight: 1}, {HeaderColor: "javascript:alert(1)"}, {Columns: []ReportColumn{{Key: "A", Label: "A"}}}, {Columns: []ReportColumn{{Key: "A", Label: "A", Visible: true}, {Key: "A", Label: "B", Visible: true}}}} {
		if err := validateReportLayouts(map[string]ReportLayout{"x": layout}); err == nil {
			t.Fatal(layout)
		}
	}
}

func slidingFixtureRows(fields []string, in Request, detail bool) *sqlmock.Rows {
	rows := sqlmock.NewRows(fields)
	a, _ := slidingTime(in.From)
	b, _ := slidingTime(in.To)
	h, _ := slidingTime(in.HistoryFrom)
	j := h.Add(b.Sub(a))
	for _, metric := range []string{"水", "电", "热"} {
		data := map[string]driver.Value{"整站编码": "01-001", "指标": metric, "单位": "GJ", "本期开始时间": a, "本期结束时间": b, "历史开始时间": h, "历史结束时间": j, "本期开始": a, "本期结束": b, "历史开始": h, "历史结束": j, "片段秒数": "3600.000", "本期用量": "0.00000000", "历史折算用量": nil}
		values := make([]driver.Value, len(fields))
		for i, key := range fields {
			values[i] = data[key]
		}
		rows.AddRow(values...)
	}
	return rows
}

func TestSlidingUntilNowUsesDatabaseClockAndCombinedResults(t *testing.T) {
	s, source, _ := fixture(t)
	view, _ := s.SaveScreen(context.Background(), Screen{Name: "对比", Kind: "comparison", SourceID: source.ID})
	// SQL is behind the application host; passing the application's "now" would
	// be rejected by the deployed procedure's future-endpoint guard.
	now := time.Now().UTC().Add(-2 * time.Minute).Truncate(time.Millisecond)
	a := now.In(beijing).Add(-time.Hour)
	h := a.AddDate(-1, 0, 0)
	in := Request{Mode: "sliding", Station: "01-001", From: a.Format(time.RFC3339Nano), HistoryFrom: h.Format(time.RFC3339Nano), ComparisonType: "汇总", IncludeDetails: true}
	frozen, _ := slidingBounds(in, now)
	m := mockDB(t, s)
	m.ExpectQuery("SELECT SYSUTCDATETIME").WillReturnRows(sqlmock.NewRows([]string{"now"}).AddRow(now))
	wall := func(v string) string { stamp, _ := slidingTime(v); return stamp.Format(beijingClock) }
	m.ExpectQuery("EXEC dbo.usp_气温水电热滑动对比").WithArgs(wall(frozen.From), wall(frozen.HistoryFrom), wall(frozen.To), wall(frozen.HistoryTo), "01-001", "全部", "1", "1", "1").WillReturnRows(slidingFixtureRows(slidingDetailFields, frozen, true), slidingFixtureRows(slidingSummaryFields, frozen, false))
	m.ExpectClose()
	got, err := s.Query(context.Background(), view.ID, in)
	if err != nil || len(got.Comparisons) != 3 || len(got.ComparisonDetails) != 3 || value(got.ComparisonDetails[0]["本期用量"]) != "0.00000000" {
		t.Fatal(got, err)
	}
}

func TestDatabasePoolReuseAndRetirement(t *testing.T) {
	s, _, _ := fixture(t)
	s.pools = map[string]*databaseLease{}
	config, _ := s.load()
	source := config.Sources[0]
	db, m, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	opens := 0
	s.open = func(context.Context, Source, string) (*sql.DB, error) { opens++; return db, nil }
	_, release1, err := s.database(context.Background(), source)
	if err != nil {
		t.Fatal(err)
	}
	_, release2, err := s.database(context.Background(), source)
	if err != nil {
		t.Fatal(err)
	}
	if opens != 1 {
		t.Fatal(opens)
	}
	s.retireDatabase(source.ID)
	if len(s.pools) != 0 {
		t.Fatal("retired pool still offered")
	}
	release1()
	m.ExpectClose()
	release2()
	if err = m.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
	if len(s.slots) != 0 {
		t.Fatal("leaked request slot")
	}
}

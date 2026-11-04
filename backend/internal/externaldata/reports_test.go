package externaldata

import (
	"context"
	"database/sql/driver"
	"fmt"
	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"strings"
	"testing"
	"time"
)

func TestStandardSlotsAndBounds(t *testing.T) {
	s, src, _ := fixture(t)
	screen, e := s.SaveScreen(context.Background(), Screen{Kind: "standard", Name: "标准历史", SourceID: src.ID})
	if e != nil {
		t.Fatal(e)
	}
	req := Request{Station: "A", From: "2026-11-01T08:00:30", To: "2026-11-02T08:00:31", Interval: 1, PageSize: 700, Offset: 700}
	m := mockDB(t, s)
	mapping(m, "A", "Value60")
	start := time.Date(2026, 11, 1, 0, 0, 30, 0, time.UTC)
	target := start.Add(700 * time.Minute)
	cols := []string{"StationCode", "SlotIndex", "TotalSlots", "HasMore", "TargetTimeUTC", "ActualSampleTimeUTC", "QualityCode"}
	for i := 1; i <= 60; i++ {
		cols = append(cols, fmt.Sprintf("Value%02d", i))
	}
	page := sqlmock.NewRows(cols)
	for i := 0; i < 700; i++ {
		values := make([]driver.Value, 67)
		values[0], values[1], values[2], values[3], values[4] = "A", int64(700+i), int64(1441), true, target.Add(time.Duration(i)*time.Minute)
		if i == 0 {
			values[5], values[6], values[66] = target.Add(-time.Second), int64(2), "0.0000"
		}
		page.AddRow(values...)
	}
	m.ExpectQuery("EXEC dbo.usp_查询站区间隔历史").WithArgs("A", start, start.Add(24*time.Hour+time.Second), 1, 700, 700).WillReturnRows(page)
	m.ExpectClose()
	r, e := s.Query(context.Background(), screen.ID, req)
	if e != nil || r.Total != 1441 || !r.HasMore || r.Rows[0].Match != "nearest" || *r.Rows[0].Values[0] != "0.0000" || r.Rows[1].Values[0] != nil {
		t.Fatal(r, e)
	}
	for _, change := range []func(*Request){func(r *Request) { r.Interval = 0 }, func(r *Request) { r.Interval = 21601 }, func(r *Request) { r.PageSize = 20000 }, func(r *Request) { r.To = "2026-11-20T00:00" }, func(r *Request) { r.Offset = 500 }} {
		bad := req
		change(&bad)
		if _, _, e := bounds("standard", bad, 480); e == nil {
			t.Fatal("accepted", bad)
		}
	}
}

func TestAlarmRangeUsesEventClockAndNullableText(t *testing.T) {
	s, src, hourly := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Kind: "alarm", Name: "报警", SourceID: src.ID})
	if e != nil {
		t.Fatal(e)
	}
	req := Request{From: "2026-11-02T00:00", To: "2026-11-03T00:00", EventType: "报警恢复", Tag: "泵"}
	viewer := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{hourly.ID}})
	if _, e := s.Query(viewer, view.ID, req); e == nil {
		t.Fatal("hourly permission allowed alarm access")
	}
	m := mockDB(t, s)
	start := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	m.ExpectQuery("FROM dbo.Alarm WHERE EventTime>=@from AND EventTime<@to").WithArgs(start, start.Add(24*time.Hour), "报警恢复", "泵", 0).WillReturnRows(sqlmock.NewRows(strings.Fields("evt alarm group tag comment desc type event priority value limit resume operator")).AddRow("2026-11-02 07:49:17.000", "2026-11-02 07:49:08.000", nil, "张屯站一区#2循环泵变频故障", nil, nil, "离散开", "报警恢复", 3, "1", nil, "0", nil))
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, req)
	if e != nil {
		t.Fatal(e)
	}
	ev := r.Events[0]
	if *ev["resume_value"] != "0" || ev["operator"] != nil || *ev["event_time"] != "2026-11-02 07:49:17.000" || *ev["alarm_time"] != "2026-11-02 07:49:08.000" {
		t.Fatal(ev)
	}
}

func TestAlarmConfirmationLooksUpCurrentPageByBeijingEventTime(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows := sqlmock.NewRows(strings.Fields("evt alarm group tag comment desc type event priority value limit resume operator"))
	for i := 0; i < 501; i++ {
		event := "报警恢复"
		if i == 0 || i == 500 {
			event = "报警确认"
		}
		rows.AddRow("2026-07-02 07:49:17.000", "2026-07-01 06:00:00.000", nil, nil, nil, nil, nil, event, nil, nil, nil, nil, "一号站")
	}
	mock.ExpectQuery("FROM dbo.Alarm").WillReturnRows(rows).RowsWillBeClosed()
	mock.ExpectQuery("WITH Confirmations").WithArgs(`[{"Row":0,"Organization":"一号站","UTC":"2026-07-01T23:49:17.000"}]`).
		WillReturnRows(sqlmock.NewRows([]string{"rowNo", "display"}).AddRow(0, "张三"))
	got, more, err := queryAlarms(context.Background(), db, Request{}, time.Time{}, time.Time{})
	if err != nil || !more || len(got) != 500 {
		t.Fatal(len(got), more, err)
	}
	if *got[0]["operator"] != "张三" || *got[1]["operator"] != "一号站" || *got[0]["event_time"] != "2026-07-02 07:49:17.000" {
		t.Fatal(got[:2])
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestAlarmColumnsPersistAndRejectStaleOrInvalidLayout(t *testing.T) {
	s, src, _ := fixture(t)
	ctx := context.Background()
	view, err := s.SaveScreen(ctx, Screen{Name: "报警", Kind: "alarm", SourceID: src.ID})
	if err != nil || view.AlarmColumns != nil {
		t.Fatal(view, err)
	}
	for i, key := range alarmFieldKeys {
		view.AlarmColumns = append(view.AlarmColumns, AlarmColumn{key, " 列头 ", i == 1})
	}
	view.AlarmColumns[0], view.AlarmColumns[1] = view.AlarmColumns[1], view.AlarmColumns[0]
	saved, err := s.SaveScreen(ctx, view)
	if err != nil || saved.AlarmColumns[0].Label != "列头" {
		t.Fatal(saved, err)
	}
	if _, err = s.SaveScreen(ctx, view); err != ErrConflict {
		t.Fatal("stale edit", err)
	}
	saved.AlarmColumns = nil
	renamed, err := s.SaveScreen(ctx, saved)
	if err != nil || len(renamed.AlarmColumns) != len(alarmFieldKeys) || renamed.AlarmColumns[0].Key != alarmFieldKeys[1] {
		t.Fatal(renamed, err)
	}
	renamed.AlarmColumns[1] = renamed.AlarmColumns[0]
	if _, err = s.SaveScreen(ctx, renamed); err == nil {
		t.Fatal("duplicate field accepted")
	}
}

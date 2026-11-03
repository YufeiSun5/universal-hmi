package externaldata

import (
	"context"
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
	page := sqlmock.NewRows([]string{"target", "sample", "quality", "value"}).AddRow(target, target.Add(-time.Second), 2, "0.0000")
	for i := 1; i < 700; i++ {
		page.AddRow(target.Add(time.Duration(i)*time.Minute), nil, nil, nil)
	}
	m.ExpectQuery("WITH D").WithArgs("A", start, start.Add(24*time.Hour+time.Second), 700, 700, 1441, 1).WillReturnRows(page)
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
	q := standardSQL([]Point{{Column: "Value60"}})
	for _, fragment := range []string{"h.SampleTime>=@from AND h.SampleTime<@to", "DATEADD(second,-30*@interval", "DATEADD(second,30*@interval", "ABS(DATEDIFF_BIG(millisecond,t.target,h.SampleTime)),h.SampleTime", "OUTER APPLY", "sample.[Value60]"} {
		if !strings.Contains(q, fragment) {
			t.Fatal(fragment)
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

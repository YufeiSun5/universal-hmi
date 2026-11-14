package externaldata

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestFilteredPaginationTotalIncludesRowsOutsideEmptyPage(t *testing.T) {
	for _, kind := range []string{"alarm", "detail"} {
		for _, fail := range []bool{false, true} {
			t.Run(kind+map[bool]string{false: "/success", true: "/count_failure"}[fail], func(t *testing.T) {
				s, src, _ := fixture(t)
				view, err := s.SaveScreen(context.Background(), Screen{Name: "分页", Kind: kind, SourceID: src.ID})
				if err != nil {
					t.Fatal(err)
				}
				m := mockDB(t, s)
				req := Request{Station: "A", From: "2026-11-02T00:00", To: "2026-11-03T00:00", Tag: "泵'", EventType: "报警恢复", Offset: 1000, IncludeTotal: true}
				start := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
				var count *sqlmock.ExpectedQuery
				if kind == "alarm" {
					m.ExpectQuery("SELECT CONVERT").WithArgs(start, start.Add(24*time.Hour), req.EventType, req.Tag, 1000).WillReturnRows(sqlmock.NewRows(strings.Fields("evt alarm group tag comment desc type event priority value limit resume operator")))
					count = m.ExpectQuery(regexp.QuoteMeta("SELECT COUNT_BIG(*)"+alarmRangeSQL)).WithArgs(start, start.Add(24*time.Hour), req.EventType, req.Tag)
				} else {
					start = start.Add(-8 * time.Hour)
					mapping(m, "A", "Value01")
					m.ExpectQuery("SELECT sample.SampleTime").WithArgs("A", start, start.Add(24*time.Hour), 1000).WillReturnRows(sqlmock.NewRows([]string{"target", "sample", "quality", "value"})).RowsWillBeClosed()
					count = m.ExpectQuery(regexp.QuoteMeta("SELECT COUNT_BIG(*)"+sampleRangeSQL)).WithArgs("A", start, start.Add(24*time.Hour))
				}
				if fail {
					count.WillReturnError(errors.New("private db detail"))
				} else {
					count.WillReturnRows(sqlmock.NewRows([]string{"count"}).AddRow(650))
				}
				m.ExpectClose()
				got, err := s.Query(context.Background(), view.ID, req)
				if fail {
					if err == nil || strings.Contains(err.Error(), "private db detail") {
						t.Fatal(err)
					}
					return
				}
				if err != nil || got.Total != 650 || got.Offset != 1000 || len(got.Rows) != 0 || len(got.Events) != 0 {
					t.Fatal(got, err)
				}
			})
		}
	}
}

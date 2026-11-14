package externaldata

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestColumnTimeZonePersistsGenericallyWithRevisionAndPermissions(t *testing.T) {
	s, source, _ := fixture(t)
	for _, kind := range []string{"alarm", "standard", "detail", "daily"} {
		t.Run(kind, func(t *testing.T) {
			zero, target := 0, 480
			view, err := s.SaveScreen(context.Background(), Screen{Name: "时间列", SourceID: source.ID, Kind: kind,
				ReportLayouts: map[string]ReportLayout{"result": {Columns: []ReportColumn{{Key: "event_time", Label: "时间", Visible: true, TimeZone: &ReportTimeZone{&zero, &target}}}}}})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = s.SaveScreen(actor(authorization.Grants{ExternalScreenIDs: []string{view.ID}}), view); !errors.Is(err, authorization.ErrDenied) {
				t.Fatal(err)
			}
			old := view
			view.ReportLayouts = nil // unrelated rename / older client preserves settings
			view.Name = "新名称"
			view, err = s.SaveScreen(context.Background(), view)
			if err != nil || *view.ReportLayouts["result"].Columns[0].TimeZone.TargetOffsetMinutes != 480 {
				t.Fatal(view, err)
			}
			if _, err = s.SaveScreen(context.Background(), old); !errors.Is(err, ErrConflict) {
				t.Fatal(err)
			}
			view.ReportLayouts["result"].Columns[0].TimeZone = nil
			view, err = s.SaveScreen(context.Background(), view)
			if err != nil || view.ReportLayouts["result"].Columns[0].TimeZone != nil {
				t.Fatal(view, err)
			}
		})
	}
}

func TestColumnTimeZoneRejectsIncompleteOrOutOfRangeSettings(t *testing.T) {
	for _, input := range []string{`{}`, `{"source_offset_minutes":0}`, `{"source_offset_minutes":0,"target_offset_minutes":841}`, `{"source_offset_minutes":-841,"target_offset_minutes":0}`} {
		var zone ReportTimeZone
		if err := json.Unmarshal([]byte(input), &zone); err != nil {
			t.Fatal(err)
		}
		if err := validateReportLayouts(map[string]ReportLayout{"x": {Columns: []ReportColumn{{Key: "time", Label: "时间", Visible: true, TimeZone: &zone}}}}); err == nil {
			t.Fatal("accepted", input)
		}
	}
}

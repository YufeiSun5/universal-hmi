package externaldata

import (
	"context"
	"database/sql"
	_ "embed"
	"encoding/json"
	"time"
	_ "time/tzdata"
)

//go:embed alarm_people.sql
var alarmPeopleSQL string

type confirmation struct {
	Row          int
	Organization string
	UTC          string
}

const alarmClock = "2006-01-02 15:04:05.000"

// The source records Pacific wall time without an offset. A skipped or
// repeated local hour cannot identify a unique session instant.
func confirmationUTC(raw string, zone *time.Location) (time.Time, bool) {
	t, err := time.ParseInLocation(alarmClock, raw, zone)
	if err != nil || t.Format(alarmClock) != raw ||
		t.Add(time.Hour).Format(alarmClock) == raw || t.Add(-time.Hour).Format(alarmClock) == raw {
		return time.Time{}, false
	}
	return t.UTC(), true
}

func matchAlarmPeople(ctx context.Context, db *sql.DB, events []map[string]*string) error {
	zone, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		return err
	}
	var batch []confirmation
	for i, ev := range events {
		if ev["event_type"] == nil || *ev["event_type"] != "报警确认" {
			continue
		}
		organization := ev["operator"]
		status := "未记录"
		ev["operator"] = &status
		if organization == nil || *organization == "" || ev["event_time"] == nil {
			continue
		}
		utc, ok := confirmationUTC(*ev["event_time"], zone)
		if !ok {
			status = "时刻无法确定"
			continue
		}
		batch = append(batch, confirmation{i, *organization, utc.Format("2006-01-02T15:04:05.000")})
	}
	if len(batch) == 0 {
		return nil
	}
	payload, err := json.Marshal(batch)
	if err != nil {
		return err
	}
	rows, err := db.QueryContext(ctx, alarmPeopleSQL, sql.Named("events", string(payload)))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var i int
		var display string
		if err := rows.Scan(&i, &display); err != nil {
			return err
		}
		events[i]["operator"] = &display
	}
	return rows.Err()
}

package totalreports

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
)

func midnightTemplate() Template {
	t := testTemplate()
	t.Kind = "heat"
	for i := range t.Daily {
		t.Daily[i].Editable = false
	}
	t.Bindings = []HeatBinding{{Column: 3, Station: "zone", Point: "ER_TotalHeat", Unit: "GJ"}}
	return t
}

func TestHeatMidnightBoundariesBelongToCompletedDay(t *testing.T) {
	for _, year := range []int{2026, 2027} {
		t.Run(fmt.Sprint(year), func(t *testing.T) {
			s, ctx := fixture(t)
			tpl := midnightTemplate()
			if e := s.SaveTemplate(ctx, tpl); e != nil {
				t.Fatal(e)
			}
			s.now = func() time.Time { return time.Date(year+1, 4, 6, 1, 0, 0, 0, time.FixedZone("Beijing", 8*3600)) }
			first := time.Date(year, 11, 5, 0, 0, 0, 0, time.UTC)
			days := []time.Time{first, first.AddDate(0, 0, 1), time.Date(year, 12, 1, 0, 0, 0, 0, time.UTC), time.Date(year+1, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(year+1, 3, 1, 0, 0, 0, 0, time.UTC), time.Date(year+1, 4, 6, 0, 0, 0, 0, time.UTC)}
			reader := &counterFixture{}
			s.SetCounterReader(reader)
			for _, boundary := range days {
				value := fmt.Sprint(boundary.Unix())
				date := boundary.Format("2006-01-02")
				reader.values = []externaldata.CounterReading{{Station: "zone", Point: "ER_TotalHeat", Date: date, Value: &value}}
				if _, e := s.SyncHeat(ctx, year, HeatSync{From: date, To: date}); e != nil {
					t.Fatal(date, e)
				}
				d, e := s.Document(ctx, "heat", year)
				if e != nil {
					t.Fatal(e)
				}
				row := tpl.HeaderRows + int(boundary.Sub(first)/(24*time.Hour))
				values := map[string]string{}
				for _, c := range d.Cells {
					values[c.Address] = c.Value
				}
				label := boundary.AddDate(0, 0, -1)
				clock := "00:00"
				if boundary.Equal(first) {
					label = first
					clock = "00:00"
				}
				if values[address(row, 0)] != fmt.Sprint(int(label.Month())) || values[address(row, 1)] != fmt.Sprint(label.Day()) || values[address(row, 2)] != clock || values[address(row, 3)] != value {
					t.Fatalf("boundary %s assigned wrong row: %v", date, values)
				}
				if row > tpl.HeaderRows && values[address(row, 4)] == "" {
					t.Fatal("daily formula missing", date)
				}
			}
			if _, e := s.SyncHeat(ctx, year, HeatSync{From: fmt.Sprintf("%d-11-04", year), To: fmt.Sprintf("%d-11-04", year)}); e == nil {
				t.Fatal("legacy baseline accepted")
			}
			s.now = func() time.Time { return time.Date(year, 11, 5, 12, 0, 0, 0, time.UTC) }
			if _, e := s.SyncHeat(ctx, year, HeatSync{From: fmt.Sprintf("%d-11-06", year), To: fmt.Sprintf("%d-11-06", year)}); e == nil {
				t.Fatal("future end-of-day reading accepted")
			}
		})
	}
}

func TestHeatMidnightUpgradeKeepsEditsAndCheckpointsOldCounters(t *testing.T) {
	s, ctx := fixture(t)
	tpl := midnightTemplate()
	if e := s.SaveTemplate(ctx, tpl); e != nil {
		t.Fatal(e)
	}
	d, e := s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	key, _ := documentKey("heat", 2026)
	// Emulate a persisted pre-upgrade annual document, including source readings
	// and an operator's modified calculation. It must never mix 08:00 with 00:00.
	if _, e = s.db.Exec(`DELETE FROM total_report_settings WHERE key=?`, "heat_midnight_v1/"+key); e != nil {
		t.Fatal(e)
	}
	for a, v := range map[string]string{"A3": "11", "B3": "4", "C3": "08:00", "C4": "08:00", "D3": "100", "D4": "110", "E4": "=SUM(D4)-SUM(D3)+7", "A1": "人工标题"} {
		if _, e = s.db.Exec(`INSERT INTO total_report_cells(doc,address,value,revision,actor) VALUES(?,?,?,0,'legacy') ON CONFLICT(doc,address) DO UPDATE SET value=excluded.value`, key, a, v); e != nil {
			t.Fatal(e)
		}
	}
	if _, e = s.db.Exec(`INSERT INTO total_report_readings(doc,address,data) VALUES(?,?,'{"target_time":"2026-11-04T08:00:00+08:00"}')`, key, "D3"); e != nil {
		t.Fatal(e)
	}
	d, e = s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	values := map[string]string{}
	for _, c := range d.Cells {
		values[c.Address] = c.Value
	}
	if values["D3"] != "" || values["D4"] != "" || values["C3"] != "00:00" || values["B3"] != "5" || values["C4"] != "00:00" || values["E4"] != "=SUM(D4)-SUM(D3)+7" || values["A1"] != "人工标题" {
		t.Fatal(values)
	}
	if items, e := s.HeatReadings(ctx, 2026); e != nil || len(items) != 0 {
		t.Fatal(items, e)
	}
	cps, e := s.Checkpoints(ctx, "heat", 2026, 0)
	if e != nil || len(cps) != 1 {
		t.Fatal(cps, e)
	}
	var compressed []byte
	if e = s.db.QueryRow(`SELECT data FROM total_report_checkpoints WHERE doc=? AND id=?`, key, cps[0].ID).Scan(&compressed); e != nil {
		t.Fatal(e)
	}
	snapshot, e := decodeCheckpoint(compressed)
	if e != nil {
		t.Fatal(e)
	}
	old := map[string]string{}
	for _, c := range snapshot {
		old[c.Address] = c.Value
	}
	if old["D3"] != "100" || old["C3"] != "08:00" {
		t.Fatal("old values not retained")
	}
	before, _ := json.Marshal(d.Cells)
	again, e := s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	after, _ := json.Marshal(again.Cells)
	if string(before) != string(after) || again.Revision != d.Revision {
		t.Fatal("migration not idempotent")
	}
	if _, e = s.Rollback(ctx, "heat", 2026, Rollback{ID: "midnight-old-snapshot", Checkpoint: cps[0].ID, Expected: d.Revision}); e != nil {
		t.Fatal(e)
	}
	again, e = s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	for _, c := range again.Cells {
		if c.Address == "D3" && c.Value != "" || c.Address == "C3" && c.Value != "00:00" {
			t.Fatal("rollback restored old time basis", c)
		}
	}
}

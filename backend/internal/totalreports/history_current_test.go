package totalreports

import (
	"context"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/xuri/excelize/v2"
	"testing"
	"time"
)

type currentReader struct {
	genericReader
	requests []externaldata.ReportValueRequest
	fail     bool
}

func TestExportDropsExpiredGeneratedNoteAndKeepsOriginalComment(t *testing.T) {
	s, ctx := fixture(t)
	f := excelize.NewFile()
	defer f.Close()
	e := f.AddComment("Sheet1", excelize.Comment{Cell: "D4", Author: "原作者", Paragraph: []excelize.RichTextRun{{Text: "保留原批注"}, {Text: "\n【报表临时值】旧采样"}}})
	if e != nil {
		t.Fatal(e)
	}
	if e = s.annotateCurrentHistory(ctx, f, "Sheet1", "electricity", 2026, nil); e != nil {
		t.Fatal(e)
	}
	comments, e := f.GetComments("Sheet1")
	if e != nil || len(comments) != 1 || len(comments[0].Paragraph) != 1 || comments[0].Paragraph[0].Text != "保留原批注" {
		t.Fatal(comments, e)
	}
}

func (r *currentReader) ReportValues(ctx context.Context, in externaldata.ReportValueRequest) ([]externaldata.ReportValue, error) {
	r.requests = append(r.requests, in)
	out := make([]externaldata.ReportValue, len(in.Targets))
	for i, v := range in.Targets {
		value := "100"
		stamp := v.From
		if in.Mode == "latest" {
			value = "125"
			stamp = v.To
		}
		out[i] = externaldata.ReportValue{Target: v.From, Value: &value, SampleTime: &stamp}
	}
	return out, nil
}

func TestCurrentHistoryBecomesFinalAtMidnight(t *testing.T) {
	s, ctx := fixture(t)
	kind := genericPage(t, s, ctx)
	reader := &currentReader{}
	s.SetCounterReader(reader)
	zone := time.FixedZone("Beijing", 8*3600)
	now := time.Date(2026, 11, 5, 13, 30, 0, 0, zone)
	s.now = func() time.Time { return now }
	b := testBinding()
	b.Range = "D2:D4"
	b.Time = "00:00"
	b.Start = "2026-11-05"
	yes := true
	b.LiveCurrent = &yes
	d, _ := s.Document(ctx, kind, 2026)
	if _, e := s.SaveHistoryBinding(ctx, kind, 2026, HistoryBindingChange{Expected: d.Revision, Binding: b, Confirm: true}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.RefreshHistory(ctx, kind, 2026); e != nil {
		t.Fatal(e)
	}
	state, e := s.HistoryState(ctx, kind, 2026)
	if e != nil {
		t.Fatal(e)
	}
	if len(state) != 3 || state[0].Provisional || !state[1].Provisional || *state[1].Value != "125" || state[2].Eligible || state[2].Value != nil {
		t.Fatal(state)
	}
	last := reader.requests[len(reader.requests)-1]
	if last.Mode != "latest" || len(last.Targets) != 1 || last.Targets[0].From != "2026-11-05T00:00:00+08:00" || last.Targets[0].To != "2026-11-05T13:30:00+08:00" {
		t.Fatal(last)
	}
	reader.requests = nil
	if _, e = s.RefreshCurrentHistory(ctx, kind, 2026); e != nil {
		t.Fatal(e)
	}
	if len(reader.requests) != 1 || reader.requests[0].Mode != "latest" {
		t.Fatal("minute refresh reread closed periods", reader.requests)
	}
	now = time.Date(2026, 11, 6, 0, 0, 0, 0, zone)
	stale, e := s.HistoryState(ctx, kind, 2026)
	if e != nil || !stale[1].Provisional {
		t.Fatal("cached provisional mislabeled final", stale, e)
	}
	if _, e = s.RefreshCurrentHistory(ctx, kind, 2026); e != nil {
		t.Fatal(e)
	}
	state, e = s.HistoryState(ctx, kind, 2026)
	if e != nil || state[1].Provisional || *state[1].Value != "100" || !state[2].Provisional {
		t.Fatal(state, e)
	}
	b.LiveCurrent = new(bool)
	preview, e := s.PreviewHistory(ctx, kind, 2026, b)
	if e != nil || preview[2].Value != nil || preview[2].Eligible {
		t.Fatal("disabled provisional read", preview, e)
	}
}

func TestClockDisplayUpgradePreservesReadingsAndCustomTimes(t *testing.T) {
	s, ctx := fixture(t)
	if e := s.SaveTemplate(ctx, midnightTemplate()); e != nil {
		t.Fatal(e)
	}
	d, _ := s.Document(ctx, "heat", 2026)
	key := "heat/2026"
	for a, v := range map[string]string{"C4": "24:00", "C5": "08:00", "D4": "123", "E4": "=D4-D3"} {
		if _, e := s.db.Exec(`UPDATE total_report_cells SET value=? WHERE doc=? AND address=?`, v, key, a); e != nil {
			t.Fatal(e)
		}
	}
	raw, _ := json.Marshal(HistoryPreview{Address: "D4", From: "2026-11-06T00:00:00+08:00"})
	s.db.Exec(`INSERT INTO total_report_readings(doc,address,data) VALUES(?,?,?)`, key, "D4", string(raw))
	after, e := s.Document(ctx, "heat", 2026)
	if e != nil {
		t.Fatal(e)
	}
	values := map[string]string{}
	for _, c := range after.Cells {
		values[c.Address] = c.Value
	}
	if values["C4"] != "00:00" || values["C5"] != "08:00" || values["D4"] != "123" || values["E4"] != "=D4-D3" || after.Revision != d.Revision+1 {
		t.Fatal(values, after.Revision, d.Revision)
	}
	again, e := s.Document(ctx, "heat", 2026)
	if e != nil || again.Revision != after.Revision {
		t.Fatal("repeat upgrade", e)
	}
	var count int
	s.db.QueryRow(`SELECT COUNT(*) FROM total_report_readings WHERE doc=?`, key).Scan(&count)
	if count != 1 {
		t.Fatal("source records changed")
	}
}

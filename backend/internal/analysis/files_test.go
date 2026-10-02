package analysis

import (
	"bytes"
	"context"
	"encoding/csv"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"github.com/xuri/excelize/v2"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestExcelImportFilteredReportRoundtrip(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	service, err := New(db, ps, filepath.Join(dir, "exports"))
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	book := excelize.NewFile()
	for cell, value := range map[string]any{"A1": "UTC time", "B1": "value", "A2": "2026-10-01T00:00:00Z", "B2": 12.5, "A3": "2026-10-01T00:01:00Z", "B3": 25.0} {
		if err := book.SetCellValue("Sheet1", cell, value); err != nil {
			t.Fatal(err)
		}
	}
	buffer, err := book.WriteToBuffer()
	book.Close()
	if err != nil {
		t.Fatal(err)
	}
	upload, err := service.Upload(bytes.NewReader(buffer.Bytes()), "sample.xlsx")
	if err != nil {
		t.Fatal(err)
	}
	mapping := Mapping{SessionID: upload["session_id"].(string), Sheet: "Sheet1", TimeColumn: 0, ValueColumn: 1, Header: true, Station: "Imported", Name: "=unsafe()", Unit: "bar"}
	preview, err := service.Preview(mapping, false)
	if err != nil || preview.Count != 2 || len(preview.Errors) != 0 {
		t.Fatalf("%+v %v", preview, err)
	}
	result, err := service.Import(context.Background(), mapping)
	if err != nil {
		t.Fatal(err)
	}
	repeat, err := service.Import(context.Background(), mapping)
	if err != nil || repeat["point_id"] != result["point_id"] {
		t.Fatalf("import not idempotent: %+v %v", repeat, err)
	}
	all, err := db.Stats(context.Background(), storage.Filter{PointID: result["point_id"].(string)})
	if err != nil || all.Count != 2 {
		t.Fatalf("duplicate import rows: %+v %v", all, err)
	}
	min := 20.0
	filter := storage.Filter{PointID: result["point_id"].(string), Min: &min}
	job, err := service.Export(filter, "xlsx")
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		jobs := service.Jobs()
		for _, j := range jobs {
			if j.ID == job.ID && j.State == "failed" {
				t.Fatal(j.Message)
			}
			if j.ID == job.ID && j.State == "completed" {
				path, _, err := service.File(j.ID)
				if err != nil {
					t.Fatal(err)
				}
				output, err := excelize.OpenFile(path)
				if err != nil {
					t.Fatal(err)
				}
				defer output.Close()
				rows, err := output.GetRows("Sheet1")
				if err != nil || len(rows) != 2 || rows[1][4] != "25" {
					t.Fatalf("export filter mismatch: %+v %v", rows, err)
				}
				formula, _ := output.GetCellFormula("Sheet1", "C2")
				if formula != "" {
					t.Fatal("external name became formula")
				}
				if _, err := os.Stat(path); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("export did not finish")
}
func TestInvalidRowsBlockImport(t *testing.T) {
	dir := t.TempDir()
	db, _ := storage.Open(dir)
	defer db.Close()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	s, _ := New(db, ps, filepath.Join(dir, "exports"))
	defer s.Close()
	upload, err := s.Upload(bytes.NewBufferString("time,value\nwrong,12\n2026-10-01T00:00:00Z,nan\n"), "sample.csv")
	if err != nil {
		t.Fatal(err)
	}
	m := Mapping{SessionID: upload["session_id"].(string), Sheet: "CSV", TimeColumn: 0, ValueColumn: 1, Header: true, Station: "s", Name: "p"}
	preview, err := s.Preview(m, false)
	if err != nil || len(preview.Errors) != 2 {
		t.Fatalf("%+v %v", preview, err)
	}
	if _, err := s.Import(context.Background(), m); err == nil {
		t.Fatal("invalid rows imported")
	}
}

func TestCancelledExportCannotBecomeCompleted(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	s, err := New(db, ps, filepath.Join(dir, "exports"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC()
	rows := make([]storage.Sample, 5000)
	for i := range rows {
		rows[i] = storage.Sample{PointID: "p", Station: "s", Name: "n", Value: float64(i), Raw: float64(i), Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v"}
	}
	if err := db.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	job, err := s.Export(storage.Filter{}, "xlsx")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Cancel(job.ID); err != nil {
		t.Skip("export completed before cancellation")
	}
	time.Sleep(100 * time.Millisecond)
	for _, j := range s.Jobs() {
		if j.ID == job.ID && j.State != "cancelled" {
			t.Fatalf("cancellation overwritten: %+v", j)
		}
	}
	if _, _, err := s.File(job.ID); err == nil {
		t.Fatal("cancelled export downloadable")
	}
}

func TestExportFreezesStationAndNumericFilterAndRestoresJobScope(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	exportDir := filepath.Join(dir, "exports")
	if err = os.MkdirAll(exportDir, 0700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	rows := []storage.Sample{{PointID: "moved", Station: "A", Name: "old name", Value: 10.0, Raw: 10.0, Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v1"}, {PointID: "moved", Station: "B", Name: "new name", Value: 20.0, Raw: 20.0, Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v2"}}
	if err = db.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	// Hold the task until the caller changes its filter to make freeze semantics deterministic.
	service := &Service{store: db, points: ps, dir: exportDir, jobs: map[string]Job{}, queue: make(chan exportTask, 8), stop: make(chan struct{})}
	min := 5.0
	filter := storage.Filter{Station: "A", Min: &min}
	job, err := service.Export(filter, "csv")
	if err != nil {
		t.Fatal(err)
	}
	if job.Station != "A" {
		t.Fatalf("job scope %+v", job)
	}
	min = 999
	filter.Station = "B"
	task := <-service.queue
	if task.Filter.Station != "A" || *task.Filter.Min != 5 {
		t.Fatal("queued filter aliased caller")
	}
	service.run(task)
	path, _, err := service.File(job.ID)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	records, err := csv.NewReader(file).ReadAll()
	if err != nil || len(records) != 2 || records[1][1] != "A" || records[1][4] != "10" {
		t.Fatalf("export escaped frozen station: %+v %v", records, err)
	}
	restored, err := New(db, ps, exportDir)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	jobs := restored.Jobs()
	if len(jobs) != 1 || jobs[0].Station != "A" || jobs[0].State != "completed" {
		t.Fatalf("job scope lost on restart %+v", jobs)
	}
}

package analysis

import (
	"context"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestExportFreezesMultiPointSelectionBeforeQueueing(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	now := time.Now().UTC()
	rows := []storage.Sample{}
	for _, id := range []string{"a", "b", "c"} {
		rows = append(rows, storage.Sample{PointID: id, Station: "A", Name: id, Value: 1.0, Raw: 1.0, Quality: "good", SourceTime: now, ReceivedTime: now})
	}
	if err := db.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	// Inspect the task before starting a worker, so mutating the caller's input
	// cannot race execution and the ownership assertion is deterministic.
	s := &Service{store: db, dir: dir, jobs: map[string]Job{}, queue: make(chan exportTask, 1)}
	ids := []string{"a", "b"}
	if _, err := s.Export(storage.Filter{PointIDs: ids, Station: "A"}, "csv"); err != nil {
		t.Fatal(err)
	}
	ids[0] = "c"
	task := <-s.queue
	got, err := db.Query(context.Background(), task.Filter)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].PointID != "a" || got[1].PointID != "b" {
		t.Fatalf("caller changed queued selection: %+v", got)
	}
}

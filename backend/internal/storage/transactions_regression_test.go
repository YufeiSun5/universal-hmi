package storage

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestAppendOnceRollsBackPartialBatchAndRetriesAtomically(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.DB.Exec(`CREATE TRIGGER reject_second BEFORE INSERT ON samples WHEN NEW.point_id='second' BEGIN SELECT RAISE(ABORT, 'partial batch failure'); END`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	rows := []Sample{
		{PointID: "first", Station: "A", Name: "first", Value: 1.0, Raw: 1.0, Unit: "bar", Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v1"},
		{PointID: "second", Station: "A", Name: "second", Value: 2.0, Raw: 2.0, Unit: "bar", Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v1"},
	}
	metadata := json.RawMessage(`{"count":2}`)
	if _, err := s.AppendOnce(context.Background(), "test-batch", metadata, rows); err == nil {
		t.Fatal("partial database failure accepted")
	}
	got, err := s.Query(context.Background(), Filter{})
	if err != nil || len(got) != 0 {
		t.Fatalf("failed transaction persisted partial rows: %+v %v", got, err)
	}
	var saved json.RawMessage
	if err := s.LoadConfig("test-batch", &saved); err != nil || len(saved) != 0 {
		t.Fatalf("failed transaction marked complete: %s %v", saved, err)
	}
	if _, err := s.DB.Exec("DROP TRIGGER reject_second"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendOnce(context.Background(), "test-batch", metadata, rows); err != nil {
		t.Fatal(err)
	}
	previous, err := s.AppendOnce(context.Background(), "test-batch", json.RawMessage(`{"count":99}`), rows)
	if err != nil || string(previous) != string(metadata) {
		t.Fatalf("idempotent batch did not preserve original result: %s %v", previous, err)
	}
	got, err = s.Query(context.Background(), Filter{})
	if err != nil || len(got) != 2 || got[0].PointID != "first" || got[1].PointID != "second" || !got[0].SourceTime.Equal(now) {
		t.Fatalf("retry or duplicate batch persisted wrong rows: %+v %v", got, err)
	}
}

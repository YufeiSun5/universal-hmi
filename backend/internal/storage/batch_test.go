package storage

import (
	"context"
	"math"
	"testing"
	"time"
)

func TestBatchFailureRollsBackEarlierChunksAndImportMarker(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	rows := make([]Sample, 170)
	for i := range rows {
		rows[i] = Sample{PointID: "p", Station: "A", Value: 1.0, Raw: 1.0, Quality: "good", SourceTime: now, ReceivedTime: now}
	}
	rows[len(rows)-1].Raw = math.NaN()
	if _, err = s.AppendOnce(context.Background(), "batch-marker", []byte(`{"count":170}`), rows); err == nil {
		t.Fatal("invalid last chunk accepted")
	}
	var count int
	if err = s.DB.QueryRow("SELECT count(*) FROM samples").Scan(&count); err != nil || count != 0 {
		t.Fatal("partial batch committed", count, err)
	}
	if err = s.DB.QueryRow("SELECT count(*) FROM config WHERE key='batch-marker'").Scan(&count); err != nil || count != 0 {
		t.Fatal("failed marker committed", count, err)
	}
	rows[len(rows)-1].Raw = 1.0
	for i := 0; i < 2; i++ {
		if _, err = s.AppendOnce(context.Background(), "batch-marker", []byte(`{"count":170}`), rows); err != nil {
			t.Fatal(err)
		}
	}
	if err = s.DB.QueryRow("SELECT count(*) FROM samples").Scan(&count); err != nil || count != 170 {
		t.Fatal("batch retry duplicated", count, err)
	}
}

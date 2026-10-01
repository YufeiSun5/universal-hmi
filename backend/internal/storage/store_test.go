package storage

import (
	"context"
	"testing"
	"time"
)

func TestHistoryExcludesBadQualityFromNumericStatisticsAndFreezesBoundary(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC()
	rows := []Sample{
		{PointID: "p", Station: "s", Name: "n", Value: 10.0, Raw: 10.0, Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v1"},
		{PointID: "p", Station: "s", Name: "n", Value: 1000.0, Raw: 1000.0, Quality: "bad", SourceTime: now, ReceivedTime: now, Version: "v1"},
	}
	if err := s.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	boundary, _ := s.Boundary()
	if err := s.Append(context.Background(), []Sample{{PointID: "p", Station: "s", Name: "n", Value: 20.0, Raw: 20.0, Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v2"}}); err != nil {
		t.Fatal(err)
	}
	stats, err := s.Stats(context.Background(), Filter{Before: boundary})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Count != 2 || stats.Mean == nil || *stats.Mean != 10 {
		t.Fatalf("bad quality included or boundary changed: %+v", stats)
	}
	empty, err := s.Query(context.Background(), Filter{Before: -1})
	if err != nil || len(empty) != 0 {
		t.Fatal("empty snapshot included later samples")
	}
}

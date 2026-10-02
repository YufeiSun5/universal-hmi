package storage

import (
	"context"
	"fmt"
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

func TestCatalogContainsTwentyThousandFrozenIdentitiesAndDeclaresTruncation(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	rows := make([]Sample, 20001)
	for i := range rows {
		rows[i] = Sample{PointID: fmt.Sprintf("point-%05d", i), Station: "A", Name: fmt.Sprintf("P%05d", i), Value: float64(i), Raw: float64(i), Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v1"}
	}
	if err := s.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	result, err := s.CatalogPage(context.Background(), "A", 0)
	if err != nil || len(result.Items) != 20000 || result.Limit != 20000 || !result.Truncated {
		t.Fatalf("catalog count=%d limit=%d truncated=%v err=%v", len(result.Items), result.Limit, result.Truncated, err)
	}
	if err := s.Append(context.Background(), []Sample{{PointID: rows[0].PointID, Station: "B", Name: "moved", Value: 2.0, Raw: 2.0, Quality: "good", SourceTime: now, ReceivedTime: now, Version: "v2"}}); err != nil {
		t.Fatal(err)
	}
	b, err := s.CatalogPage(context.Background(), "B", 100)
	if err != nil || len(b.Items) != 1 || b.Items[0]["station"] != "B" {
		t.Fatalf("moved B %+v %v", b, err)
	}
	a, err := s.CatalogPage(context.Background(), "A", 1)
	if err != nil || len(a.Items) != 1 || a.Items[0]["name"] != "P00000" || !a.Truncated {
		t.Fatalf("frozen A %+v %v", a, err)
	}
}

func TestStationRetentionDoesNotPruneAnotherPolicyScope(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	old := time.Now().AddDate(0, 0, -10)
	rows := []Sample{}
	for _, station := range []string{"A", "B"} {
		rows = append(rows, Sample{PointID: station, Station: station, Value: 1.0, Raw: 1.0, Quality: "good", SourceTime: old, ReceivedTime: old})
	}
	if err = s.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	if err = s.PruneExcept(context.Background(), 2, []string{"A"}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Query(context.Background(), Filter{})
	if err != nil || len(got) != 1 || got[0].Station != "A" {
		t.Fatalf("global prune escaped %+v %v", got, err)
	}
	if err = s.PruneStation(context.Background(), "A", 30); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Query(context.Background(), Filter{})
	if len(got) != 1 {
		t.Fatal("station retention ignored")
	}
	if err = s.PruneStation(context.Background(), "A", 1); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Query(context.Background(), Filter{})
	if len(got) != 0 {
		t.Fatal("station retention did not apply")
	}
}

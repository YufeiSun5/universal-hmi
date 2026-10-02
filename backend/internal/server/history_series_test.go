package server

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestHistorySeriesHTTPFullRangeAndFrozenBoundary(t *testing.T) {
	h, _, e := platform(t)
	rows := make([]storage.Sample, 2500)
	start := time.Now().UTC().Truncate(time.Second)
	for i := range rows {
		rows[i] = storage.Sample{PointID: "p", Station: "A", Name: "old name", Value: float64(i), Raw: float64(i), Unit: "bar", Quality: "good", SourceTime: start.Add(time.Duration(i) * time.Second), ReceivedTime: start.Add(time.Duration(i) * time.Second), Version: "v1"}
	}
	if err := e.Store.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	w := request(h, "GET", "/api/v1/history/series?point_ids=p&station=A&max_points=80", "")
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	var got storage.SeriesResult
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Count != 2500 || got.Returned > 80 || !got.Sampled || got.Before != 2500 || got.Boundary != got.Before || got.Items[0].Seq != 1 || got.Items[len(got.Items)-1].Seq != 2500 {
		t.Fatalf("incorrect series contract: count=%d returned=%d boundary=%d first=%d last=%d", got.Count, got.Returned, got.Boundary, got.Items[0].Seq, got.Items[len(got.Items)-1].Seq)
	}
	rows[0].Value = 99999.0
	if err := e.Store.Append(context.Background(), rows[:1]); err != nil {
		t.Fatal(err)
	}
	w = request(h, "GET", fmt.Sprintf("/api/v1/history/series?point_id=p&before=%d", got.Before), "")
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Count != 2500 || *got.Summaries[0].Max != 2499 {
		t.Fatal("series snapshot advanced")
	}
	w = request(h, "GET", fmt.Sprintf("/api/v1/history?point_ids=p&before=%d&limit=5000", got.Before), "")
	var raw struct {
		Items    []storage.Sample `json:"items"`
		Stats    storage.Stats    `json:"stats"`
		Boundary int64            `json:"boundary"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if len(raw.Items) != 2500 || raw.Stats.Count != 2500 || raw.Boundary != got.Before {
		t.Fatalf("raw query does not share series boundary: status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestHistorySeriesHTTPValidation(t *testing.T) {
	h, _, _ := platform(t)
	for _, query := range []string{"", "station=A", "point_ids=", "point_ids=a,a", "point_ids=a,,b", "point_ids=a,b,c,d,e,f,g", "point_id=a&point_ids=b", "point_ids=a&point_ids=b", "point_id=a&point_id=b", "point_id=a&max_points=19", "point_id=a&max_points=601", "point_id=a&max_points=", "point_id=a&max_points=600&max_points=20", "point_id=a&max_points=NaN", "point_id=a&min=NaN", "point_id=a&min=2&max=1", "point_id=a&from=2&to=1", "point_id=a&before=-2", "point_id=a&from=1&from=2", "point_id=a&offset=1", "point_id=a&limit=1000"} {
		t.Run(query, func(t *testing.T) {
			w := request(h, "GET", "/api/v1/history/series?"+query, "")
			if w.Code != 422 {
				t.Fatalf("accepted invalid query: %d %s", w.Code, w.Body.String())
			}
		})
	}
	for _, path := range []string{"/api/v1/history?point_ids=a,a", "/api/v1/export?format=csv&point_id=a&point_ids=b", "/api/v1/export?format=csv&point_ids=", "/api/v1/history?min=2&max=1"} {
		method := "GET"
		if strings.Contains(path, "/export") {
			method = "POST"
		}
		w := request(h, method, path, "")
		if w.Code != 422 {
			t.Fatalf("shared filter accepted %s: %d", path, w.Code)
		}
	}
	w := request(h, "GET", "/api/v1/history/series?point_ids=a,b&before=-1", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"items":[]`) || !strings.Contains(w.Body.String(), `"summaries":[]`) || !strings.Contains(w.Body.String(), `"before":-1`) {
		t.Fatalf("invalid empty response: %d %s", w.Code, w.Body.String())
	}
}

func TestHistorySeriesHTTPFilteredGapsAndMultiPointExport(t *testing.T) {
	h, _, e := platform(t)
	start := time.Now().UTC().Truncate(time.Second)
	rows := []storage.Sample{}
	for i := 0; i < 8; i++ {
		for _, point := range []string{"a", "b", "unselected"} {
			for _, station := range []string{"A", "B"} {
				r := storage.Sample{PointID: point, Station: station, Name: point, Value: float64(i), Raw: float64(i), Unit: "bar", Quality: "good", Version: "v1", SourceTime: start.Add(time.Duration(i) * time.Second), ReceivedTime: start.Add(time.Duration(i) * time.Second)}
				if i == 3 {
					r.Quality = "bad"
				}
				rows = append(rows, r)
			}
		}
	}
	if err := e.Store.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	filters := fmt.Sprintf("point_ids=a,b&station=A&quality=good&min=1&max=6&from=%d&to=%d", start.UnixMilli(), start.Add(7*time.Second).UnixMilli())
	w := request(h, "GET", "/api/v1/history/series?"+filters, "")
	var series storage.SeriesResult
	if err := json.Unmarshal(w.Body.Bytes(), &series); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || series.Count != 10 || len(series.Summaries) != 2 {
		t.Fatalf("series failed: %d %s", w.Code, w.Body.String())
	}
	for _, r := range series.Items {
		if r.Value == 4.0 && !r.BreakBefore {
			t.Fatal("quality filter hid a gap")
		}
	}
	filters += fmt.Sprintf("&before=%d", series.Before)
	w = request(h, "POST", "/api/v1/export?format=csv&"+filters, "")
	var job analysis.Job
	if w.Code != 200 {
		t.Fatalf("export not queued: %s", w.Body.String())
	}
	if err := json.Unmarshal(w.Body.Bytes(), &job); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		w = request(h, "GET", "/api/v1/jobs/"+job.ID+"/file", "")
		if w.Code == 200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("export did not complete: %s", w.Body.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	records, err := csv.NewReader(strings.NewReader(w.Body.String())).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	data := [][]string{}
	for _, record := range records {
		if len(record) == 8 && record[1] == "A" {
			data = append(data, record)
		}
	}
	if len(data) != int(series.Count) {
		t.Fatalf("export rows=%d series count=%d; CSV: %s", len(data), series.Count, w.Body.String())
	}
	for _, record := range data {
		if (record[3] != "a" && record[3] != "b") || record[6] != "good" || record[4] == "3" || record[4] == "0" || record[4] == "7" {
			t.Fatalf("export escaped shared filters: %+v", record)
		}
	}
}

func TestHistoryFutureBoundaryIsClampedToExistingSnapshot(t *testing.T) {
	h, _, e := platform(t)
	now := time.Now().UTC()
	r := storage.Sample{PointID: "p", Station: "A", Value: 1.0, Raw: 1.0, Quality: "good", SourceTime: now, ReceivedTime: now}
	if err := e.Store.Append(context.Background(), []storage.Sample{r}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/api/v1/history?point_id=p&before=999999", "/api/v1/history/series?point_id=p&before=999999"} {
		w := request(h, "GET", path, "")
		var result struct {
			Boundary int64 `json:"boundary"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if w.Code != 200 || result.Boundary != 1 {
			t.Fatalf("future boundary can include later rows: %d %s", w.Code, w.Body.String())
		}
	}
}

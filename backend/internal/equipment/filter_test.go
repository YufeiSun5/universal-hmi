package equipment

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestLocationFilterCombinesScopeCategorySearchAndPagination(t *testing.T) {
	devices := []Device{
		{ID: "1", Station: "A", Site: "北侧", Category: "水泵", Name: "循环泵", Location: "一层泵房 / Pump A", Updated: "2026-01-06"},
		{ID: "2", Station: "A", Site: "北侧", Category: "水泵", Name: "循环泵", Location: "一层泵房 / PUMP B", Updated: "2026-01-05"},
		{ID: "3", Station: "A", Site: "南侧", Category: "水泵", Name: "循环泵", Location: "一层泵房 / Pump A", Updated: "2026-01-04"},
		{ID: "4", Station: "A", Site: "北侧", Category: "阀门", Name: "循环阀", Location: "一层泵房 / Pump A", Updated: "2026-01-03"},
		{ID: "5", Station: "A", Site: "北侧", Category: "水泵", Name: "备用泵", Location: "", Updated: "2026-01-02"},
		{ID: "6", Station: "B", Site: "北侧", Category: "水泵", Name: "循环泵", Location: "一层泵房 / Pump A", Updated: "2026-01-01"},
	}
	data, _ := json.Marshal(devices)
	repo := &memory{data: data}
	before := bytes.Clone(data)
	s, err := Open(repo, t.TempDir(), func() ([]string, error) { return []string{"A", "B"}, nil })
	if err != nil {
		t.Fatal(err)
	}
	f := Filter{Station: "A", Site: "北侧", Category: "水泵", Search: "循环", Location: "泵房 / pump", Limit: 1}
	p, err := s.List(actor("A", false), f)
	if err != nil || p.Total != 2 || len(p.Items) != 1 || p.Items[0].ID != "1" {
		t.Fatalf("first %+v: %v", p, err)
	}
	f.Offset = 1
	p, err = s.List(actor("A", false), f)
	if err != nil || p.Total != 2 || len(p.Items) != 1 || p.Items[0].ID != "2" {
		t.Fatalf("second %+v: %v", p, err)
	}
	p, err = s.List(actor("A", false), Filter{Location: "Pump", Limit: 50})
	if err != nil || p.Total != 4 {
		t.Fatalf("scope/location %+v: %v", p, err)
	}
	for _, d := range p.Items {
		if d.Station != "A" {
			t.Fatal("unauthorized device", d)
		}
	}
	p, err = s.List(actor("A", false), Filter{Limit: 50})
	if err != nil || p.Total != 5 {
		t.Fatalf("empty filter must retain legacy empty locations %+v: %v", p, err)
	}
	p, err = s.List(actor("A", false), Filter{Location: "不存在", Limit: 50})
	if err != nil || p.Total != 0 {
		t.Fatalf("missing %+v: %v", p, err)
	}
	if _, err = s.List(actor("A", false), Filter{Location: strings.Repeat("x", 257), Limit: 50}); err == nil {
		t.Fatal("unbounded location filter")
	}
	if !bytes.Equal(before, repo.data) {
		t.Fatal("listing rewrote saved equipment")
	}
}

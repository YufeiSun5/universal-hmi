package transfer

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

// This optional release fixture uses the scanner's independent all-numeric-FLOAT
// expectation, keeps the old 385 paths plus fillers, and upgrades real old IDs.
func TestNavigationV14DeliveryUpgrades28ScreensPreserves5019(t *testing.T) {
	read := func(path string) Request {
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			t.Skip("optional delivered JSON absent")
		}
		if err != nil {
			t.Fatal(err)
		}
		var w struct {
			RetryRequest Request `json:"retry_request"`
		}
		if err = json.Unmarshal(data, &w); err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(w.RetryRequest.Bundle)
		decoded, err := Decode(b, "json", "")
		if err != nil {
			t.Fatal("production decoder", err)
		}
		w.RetryRequest.Bundle = decoded
		return w.RetryRequest
	}
	base := filepath.Join("..", "..", "..", "outputs")
	old := read(filepath.Join(base, "process-scanned-numeric-20261029", "扫描变量后导入工艺-数值类型适配.json"))
	r := read(filepath.Join(base, "process-navigation-v14-20261030", "创建画面与绑定-主图父子导航-v14.json"))
	if old.ImportIdentity != r.ImportIdentity || len(r.Bundle.Variables) != 313 || len(r.Bundle.Screens) != 28 || r.Bundle.Navigation == nil {
		t.Fatal("delivery identity or shape")
	}
	s := setup(t)
	store := &menuStore{config: navigation.Config{Nodes: []navigation.Node{}}}
	s.Navigation = navigation.New(store, func(id string) error { _, err := s.Screens.Get(id); return err })
	s.Sources = func() []map[string]string { return []map[string]string{{"id": "actual-scanned"}} }
	inputs := []points.CreateInput{}
	for _, row := range old.Bundle.Variables {
		var v Variable
		_ = json.Unmarshal(row, &v)
		in := v.Definition
		in.DataType = "FLOAT"
		in.SourceID = "actual-scanned"
		in.Topic = "scanner-live"
		in.Station = "IO-01"
		inputs = append(inputs, in)
	}
	for len(inputs) < 5019 {
		i := len(inputs)
		inputs = append(inputs, points.CreateInput{Name: fmt.Sprint("unrelated", i), Station: "IO-01", DataType: "FLOAT", SourceType: "mqtt", SourceID: "actual-scanned", SourcePath: fmt.Sprint("filler.", i), Topic: "scanner-live"})
	}
	if _, err := s.Points.CreateBatch(inputs); err != nil {
		t.Fatal(err)
	}
	before, _ := json.Marshal(s.Points.List())
	commit := func(q Request) Result {
		q.SourceMap = map[string]string{"kingio-original": "actual-scanned"}
		q.CreateStations = nil
		p, err := s.Preview(context.Background(), q)
		if err != nil || len(p.Remaining) > 0 {
			t.Fatalf("preview %v %+v", err, p.Remaining)
		}
		q.PreviewToken = p.PreviewToken
		c, err := s.Commit(context.Background(), q)
		if err != nil || len(c.Remaining) > 0 {
			t.Fatalf("commit %v %+v", err, c.Remaining)
		}
		return c
	}
	commit(old)
	oldScreens, _ := s.Screens.ListAll()
	ids := map[string]bool{}
	for _, d := range oldScreens {
		ids[d.ID] = true
	}
	for key := range r.ScreenTargets {
		r.ScreenTargets[key] = Target{Mode: "update_imported"}
	}
	r.NavigationTarget = &NavigationTarget{Mode: "create", Revision: 0}
	c := commit(r)
	if menuItem(c).Status != "saved" || len(store.config.Nodes) != 14 {
		t.Fatal("menu not published")
	}
	leaves := 0
	for _, group := range store.config.Nodes {
		for _, leaf := range group.Children {
			leaves++
			if !ids[leaf.ScreenID] {
				t.Fatal("navigation created another screen identity")
			}
			if _, err := s.Screens.Get(leaf.ScreenID); err != nil {
				t.Fatal(err)
			}
		}
	}
	if leaves != 28 {
		t.Fatalf("leaf count %d", leaves)
	}
	after, _ := json.Marshal(s.Points.List())
	if string(before) != string(after) {
		t.Fatal("5019 scanned definitions changed")
	}
	now, _ := s.Screens.ListAll()
	if len(now) != 28 {
		t.Fatalf("screen duplication %d", len(now))
	}
	for _, d := range now {
		if !ids[d.ID] {
			t.Fatal("old screen ID lost")
		}
	}
	t.Log("5019 definitions byte-equal; old 28 stable screen IDs reused; 14 parents/28 leaves resolve; production Decode/preview/commit passed")
}

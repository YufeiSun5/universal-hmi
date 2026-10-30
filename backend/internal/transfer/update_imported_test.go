package transfer

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func TestUpdateImportedUsesExactIdentityAndRejectsStaleEdits(t *testing.T) {
	s := setup(t)
	r := request()
	r.ImportIdentity = "stable-delivery"
	p, _ := s.Preview(context.Background(), r)
	r.PreviewToken = p.PreviewToken
	if _, err := s.Commit(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	list, _ := s.Screens.ListAll()
	old, _ := s.Screens.Get(list[0].ID)
	r.ScreenTargets["s"] = Target{Mode: "update_imported"}
	var incoming Screen
	_ = json.Unmarshal(r.Bundle.Screens[0], &incoming)
	incoming.Document.Name = "clean layout"
	r.Bundle.Screens[0] = raw(incoming)
	p, err := s.Preview(context.Background(), r)
	if err != nil || len(p.Remaining) > 0 {
		t.Fatalf("preview %v %+v", err, p)
	}
	for _, it := range p.Items {
		if it.Kind == "screen" {
			d := it.After.(process.Document)
			if d.ID != old.ID || d.Revision != old.Revision {
				t.Fatal("wrong imported target")
			}
		}
	}
	old.Name = "concurrent local edit"
	if _, err := s.Screens.Save(old); err != nil {
		t.Fatal(err)
	}
	r.PreviewToken = p.PreviewToken
	if _, err := s.Commit(context.Background(), r); err == nil {
		t.Fatal("stale preview overwrote local edit")
	}
	still, _ := s.Screens.Get(old.ID)
	if still.Name != "concurrent local edit" {
		t.Fatal("local edit overwritten")
	}
	p, err = s.Preview(context.Background(), r)
	if err != nil {
		t.Fatal(err)
	}
	r.PreviewToken = p.PreviewToken
	if _, err := s.Commit(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	now, _ := s.Screens.Get(old.ID)
	if now.Name != "clean layout" || now.Nodes[0].PointID != old.Nodes[0].PointID || len(s.Points.List()) != 1 {
		t.Fatal("update changed binding or duplicated variables")
	}
	for _, kind := range []string{"missing", "foreign-station", "wrong-kind", "override-id"} {
		t.Run(kind, func(t *testing.T) {
			service := s
			q := r
			q.ScreenTargets = map[string]Target{"s": {Mode: "update_imported"}}
			var v Screen
			_ = json.Unmarshal(r.Bundle.Screens[0], &v)
			switch kind {
			case "missing":
				q.ImportIdentity = "another-import"
			case "override-id":
				q.ScreenTargets["s"] = Target{Mode: "update_imported", ID: "arbitrary"}
			case "wrong-kind":
				v.Document.Kind = "gis"
			case "foreign-station":
				service = setup(t)
				d := screen()
				d.ID = old.ID
				d.Revision = 0
				d.Station = "B"
				stripBindings(&d)
				if _, err := service.Screens.Save(d); err != nil {
					t.Fatal(err)
				}
			}
			q.Bundle.Screens = []json.RawMessage{raw(v)}
			plan, err := service.Preview(context.Background(), q)
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, it := range plan.Items {
				if it.Kind == "screen" && it.Status == "error" {
					found = true
				}
			}
			if !found {
				t.Fatalf("unsafe target accepted %+v", plan)
			}
		})
	}
}

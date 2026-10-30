package transfer

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

type menuStore struct {
	config navigation.Config
	fail   bool
}

func TestNavigationDoesNotPublishAfterScreenPersistenceFailure(t *testing.T) {
	s, store, r := menuSetup(t)
	dir := t.TempDir()
	var err error
	s.Screens, err = process.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	s.Navigation = navigation.New(store, func(id string) error { _, err := s.Screens.Get(id); return err })
	p, err := s.Preview(context.Background(), r)
	if err != nil {
		t.Fatal(err)
	}
	id := menuItem(p).After.(navigation.Config).Nodes[0].Children[0].ScreenID
	// A directory at the final filename makes atomic rename fail on both OSes,
	// while Get still reports the absent document during the commit preflight.
	if err := os.Mkdir(filepath.Join(dir, id+".json"), 0700); err != nil {
		t.Fatal(err)
	}
	r.PreviewToken = p.PreviewToken
	c, err := s.Commit(context.Background(), r)
	if err != nil || menuItem(c).Status != "error" {
		t.Fatalf("expected partial result %v %+v", err, c)
	}
	if store.config.Revision != 0 || store.config.Enabled || len(s.Points.List()) != 1 {
		t.Fatalf("navigation published missing target or point result lost %+v", c)
	}
}

func (s *menuStore) LoadConfig(_ string, out any) error {
	b, _ := json.Marshal(s.config)
	return json.Unmarshal(b, out)
}
func (s *menuStore) SaveConfig(_ string, v any) error {
	if s.fail {
		return errors.New("menu storage unavailable")
	}
	b, _ := json.Marshal(v)
	return json.Unmarshal(b, &s.config)
}
func menuSetup(t *testing.T) (*Service, *menuStore, Request) {
	s := setup(t)
	store := &menuStore{config: navigation.Config{Nodes: []navigation.Node{}}}
	s.Navigation = navigation.New(store, func(id string) error { _, err := s.Screens.Get(id); return err })
	r := request()
	r.Bundle.Navigation = &Navigation{Enabled: true, Nodes: []NavigationNode{{ID: "parent", Label: "大站", Children: []NavigationNode{{ID: "child", Label: "一区", ScreenKey: "s"}}}}}
	r.NavigationTarget = &NavigationTarget{Mode: "create"}
	return s, store, r
}
func menuItem(r Result) Item {
	for _, it := range r.Items {
		if it.Kind == "navigation" {
			return it
		}
	}
	return Item{}
}

func TestNavigationImportResolvesPortableTreeAndReusesPoints(t *testing.T) {
	s, store, r := menuSetup(t)
	ctx := context.Background()
	p, err := s.Preview(ctx, r)
	if err != nil || menuItem(p).Status != "ready" {
		t.Fatalf("preview %v %+v", err, p)
	}
	if store.config.Revision != 0 || len(s.Points.List()) != 0 {
		t.Fatal("preview mutated")
	}
	r.PreviewToken = p.PreviewToken
	c, err := s.Commit(ctx, r)
	if err != nil || menuItem(c).Status != "saved" || len(c.Remaining) > 0 {
		t.Fatalf("commit %v %+v", err, c)
	}
	leaves := store.config.Nodes[0].Children
	if store.config.Revision != 1 || !store.config.Enabled || len(leaves) != 1 {
		t.Fatalf("config %+v", store.config)
	}
	d, err := s.Screens.Get(leaves[0].ScreenID)
	if err != nil || d.Station != "A" || d.Nodes[0].PointID != s.Points.List()[0].ID {
		t.Fatalf("resolved document %v %+v", err, d)
	}
	p, err = s.Preview(ctx, r)
	if err != nil || menuItem(p).Status != "unchanged" {
		t.Fatalf("repeat %v %+v", err, p)
	}
	if len(s.Points.List()) != 1 {
		t.Fatal("duplicated point")
	}
}

func TestNavigationInvalidOrExistingMenuBlocksBeforeAnyWrites(t *testing.T) {
	for _, kind := range []string{"missing-key", "duplicate-node", "leaf-group", "existing", "revision", "unselected"} {
		t.Run(kind, func(t *testing.T) {
			s, store, r := menuSetup(t)
			switch kind {
			case "missing-key":
				r.Bundle.Navigation.Nodes[0].Children[0].ScreenKey = "unknown"
			case "duplicate-node":
				r.Bundle.Navigation.Nodes[0].Children[0].ID = "parent"
			case "leaf-group":
				r.Bundle.Navigation.Nodes[0].ScreenKey = "s"
			case "existing":
				store.config = navigation.Config{Revision: 2, Enabled: true, Nodes: []navigation.Node{{ID: "custom", Label: "自定义"}}}
				r.NavigationTarget.Revision = 2
			case "revision":
				r.NavigationTarget.Revision = 99
			case "unselected":
				r.NavigationTarget = nil
			}
			before, _ := json.Marshal(store.config)
			p, err := s.Preview(context.Background(), r)
			if err != nil || len(p.Remaining) == 0 {
				t.Fatalf("expected blocked %v %+v", err, p)
			}
			r.PreviewToken = p.PreviewToken
			if _, err = s.Commit(context.Background(), r); err == nil {
				t.Fatal("blocked plan committed")
			}
			if len(s.Points.List()) != 0 {
				t.Fatal("point changed before invalid menu rejected")
			}
			list, _ := s.Screens.ListAll()
			if len(list) != 0 {
				t.Fatal("screen changed")
			}
			after, _ := json.Marshal(store.config)
			if string(before) != string(after) {
				t.Fatal("custom menu overwritten")
			}
		})
	}
}

func TestNavigationExplicitReplaceSkipConflictPermissionAndPartialFailure(t *testing.T) {
	s, store, r := menuSetup(t)
	ctx := context.Background()
	store.config = navigation.Config{Revision: 4, Enabled: true, Nodes: []navigation.Node{{ID: "custom", Label: "旧菜单"}}}
	r.NavigationTarget = &NavigationTarget{Mode: "replace", Revision: 4}
	p, _ := s.Preview(ctx, r)
	store.config.Revision++
	r.PreviewToken = p.PreviewToken
	if _, err := s.Commit(ctx, r); err == nil || len(s.Points.List()) != 0 {
		t.Fatal("stale menu revision committed")
	}
	r.NavigationTarget.Revision = 5
	p, _ = s.Preview(ctx, r)
	r.PreviewToken = p.PreviewToken
	store.fail = true
	c, err := s.Commit(ctx, r)
	if err != nil || menuItem(c).Status != "failed" {
		t.Fatalf("partial result %v %+v", err, c)
	}
	if len(s.Points.List()) != 1 || store.config.Nodes[0].ID != "custom" {
		t.Fatal("partial result lost saved points or overwrote menu")
	}
	store.fail = false
	p, _ = s.Preview(ctx, r)
	r.PreviewToken = p.PreviewToken
	c, err = s.Commit(ctx, r)
	if err != nil || menuItem(c).Status != "saved" {
		t.Fatalf("retry %v %+v", err, c)
	}
	r.NavigationTarget.Mode = "skip"
	p, _ = s.Preview(ctx, r)
	if menuItem(p).Status != "skipped" {
		t.Fatal("skip not explicit")
	}
	denied := authorization.WithActor(ctx, authorization.Actor{ID: "reader", Grants: authorization.Grants{}})
	if _, err = s.Preview(denied, r); !errors.Is(err, authorization.ErrDenied) {
		t.Fatalf("reader allowed %v", err)
	}
	data, err := Encode(r.Bundle, "json", "bundle")
	if err != nil {
		t.Fatal(err)
	}
	round, err := Decode(data, "json", "bundle")
	if err != nil || round.Navigation == nil {
		t.Fatalf("JSON lost navigation %v", err)
	}
	if _, err = Encode(r.Bundle, "xlsx", "bundle"); err == nil {
		t.Fatal("XLSX silently lost navigation")
	}
}

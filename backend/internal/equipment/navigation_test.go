package equipment

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"strings"
	"testing"
)

type keyedMemory map[string][]byte

func (m keyedMemory) LoadConfig(key string, v any) error {
	if m[key] == nil {
		return nil
	}
	return json.Unmarshal(m[key], v)
}
func (m keyedMemory) SaveConfig(key string, v any) error {
	b, e := json.Marshal(v)
	if e == nil {
		m[key] = b
	}
	return e
}

func TestNavigationPersistenceScopeValidationAndDeletedTargets(t *testing.T) {
	repo := keyedMemory{}
	stations := []string{"A", "B"}
	s, err := Open(repo, t.TempDir(), func() ([]string, error) { return stations, nil })
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.Save(actor("A", true), Device{Station: "A", Code: "1", Name: "pump", Category: "pump", PhotoFit: "cover"})
	if err != nil {
		t.Fatal(err)
	}
	initial, err := s.Navigation(actor("A", false))
	if err != nil || initial.Revision != 0 || len(initial.Nodes) != 0 {
		t.Fatal(initial, err)
	}
	c := Navigation{Nodes: []NavigationNode{{ID: "group", Label: "Group", Children: []NavigationNode{{ID: "a", Label: "A", Station: "A", Site: "zone"}, {ID: "b", Label: "B", Station: "B"}}}}}
	saved, err := s.SaveNavigation(actor("A", true), c)
	if err != nil || saved.Revision != 1 {
		t.Fatal(saved, err)
	}
	if _, err = s.SaveNavigation(actor("A", true), c); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	if _, err = s.SaveNavigation(actor("A", false), saved); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	scoped := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"engineer"}, StationIDs: []string{"A"}}, StationID: func(n string) string { return n }, Valid: func() bool { return true }})
	if _, err = s.SaveNavigation(scoped, saved); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	got, err := s.Navigation(actor("A", false))
	if err != nil || len(got.Nodes[0].Children) != 1 || got.Nodes[0].Children[0].Site != "zone" {
		t.Fatal(got, err)
	}
	got.Nodes[0].Children[0].Label = "mutated"
	got, _ = s.Navigation(actor("A", false))
	if got.Nodes[0].Children[0].Label != "A" {
		t.Fatal("read alias")
	}
	for _, nodes := range [][]NavigationNode{
		{{ID: "x", Label: "empty group"}},
		{{ID: "x", Label: "missing", Station: "missing"}},
		{{ID: "x", Label: "mixed", Station: "A", Children: []NavigationNode{{ID: "child", Label: "A", Station: "A"}}}},
		{{ID: "x", Label: "group site", Site: "bad", Children: []NavigationNode{{ID: "child", Label: "A", Station: "A"}}}},
		{{ID: "x", Label: "duplicate", Station: "A"}, {ID: "x", Label: "duplicate", Station: "B"}},
		{{ID: "x", Label: strings.Repeat("a", 257), Station: "A"}},
	} {
		if _, err = s.SaveNavigation(actor("A", true), Navigation{Revision: 1, Nodes: nodes}); err == nil {
			t.Fatal("accepted invalid", nodes)
		}
	}
	leaf := NavigationNode{ID: "leaf", Label: "A", Station: "A"}
	for i := 0; i < 4; i++ {
		leaf = NavigationNode{ID: strings.Repeat("g", i+1), Label: "group", Children: []NavigationNode{leaf}}
	}
	if _, err = s.SaveNavigation(actor("A", true), Navigation{Revision: 1, Nodes: []NavigationNode{leaf}}); err == nil {
		t.Fatal("depth accepted")
	}
	many := []NavigationNode{}
	for i := 0; i < 257; i++ {
		many = append(many, NavigationNode{ID: fmt.Sprintf("node-%d", i), Label: "A", Station: "A"})
	}
	if _, err = s.SaveNavigation(actor("A", true), Navigation{Revision: 1, Nodes: many}); err == nil {
		t.Fatal("count accepted")
	}
	stations = []string{"B"}
	got, err = s.Navigation(actor("A", false))
	if err != nil || len(got.Nodes) != 0 || got.Revision != 1 {
		t.Fatal(got, err)
	}
	all, err := s.Navigation(actor("B", true))
	if err != nil || len(all.Nodes[0].Children) != 1 || all.Nodes[0].Children[0].Station != "B" {
		t.Fatal(all, err)
	}
	if _, err = s.SaveNavigation(actor("B", true), saved); err == nil {
		t.Fatal("deleted station accepted")
	}
	reopened, _ := Open(repo, t.TempDir(), func() ([]string, error) { return []string{"A", "B"}, nil })
	got, err = reopened.Navigation(actor("A", true))
	if err != nil || len(got.Nodes[0].Children) != 2 {
		t.Fatal(got, err)
	}
	actual, err := reopened.Get(actor("A", true), d.ID)
	if err != nil || actual.PhotoFit != "cover" || actual.Revision != d.Revision {
		t.Fatal(actual, err)
	}
	for _, fit := range []string{"", "contain", "cover", "fill"} {
		actual.PhotoFit = fit
		actual, err = reopened.Save(actor("A", true), actual)
		if err != nil {
			t.Fatal(err)
		}
	}
	actual.PhotoFit = "invalid"
	if _, err = reopened.Save(actor("A", true), actual); err == nil {
		t.Fatal("bad photo fit accepted")
	}
}

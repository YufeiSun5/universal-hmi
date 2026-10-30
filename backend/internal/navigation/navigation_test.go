package navigation

import (
	"encoding/json"
	"errors"
	"sync"
	"testing"
)

type memoryStore struct{ data []byte }

func (s *memoryStore) LoadConfig(_ string, v any) error {
	if s.data == nil {
		return nil
	}
	return json.Unmarshal(s.data, v)
}
func (s *memoryStore) SaveConfig(_ string, v any) error {
	b, e := json.Marshal(v)
	s.data = b
	return e
}
func TestNavigationIndependentTargetsRevisionAndBounds(t *testing.T) {
	store := &memoryStore{}
	svc := New(store, func(id string) error {
		if id == "A" || id == "B" {
			return nil
		}
		return errors.New("missing")
	})
	c, err := svc.Get()
	if err != nil || c.Enabled || c.Revision != 0 || len(c.Nodes) != 0 {
		t.Fatal(c, err)
	}
	c.Enabled = true
	c.Nodes = []Node{{ID: "district", Label: "共享分组", Children: []Node{{ID: "a", Label: "A站", ScreenID: "A"}, {ID: "b", Label: "B站", ScreenID: "B"}}}}
	saved, err := svc.Save(c)
	if err != nil || saved.Revision != 1 {
		t.Fatal(saved, err)
	}
	if _, err = svc.Save(c); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	for _, nodes := range [][]Node{
		{{ID: "x", Label: "失效", ScreenID: "missing"}},
		{{ID: "x", Label: "重复"}, {ID: "x", Label: "重复"}},
		{{ID: "x", Label: "混合", ScreenID: "A", Children: []Node{{ID: "y", Label: "空组"}}}},
		{{ID: "1", Label: "1", Children: []Node{{ID: "2", Label: "2", Children: []Node{{ID: "3", Label: "3", Children: []Node{{ID: "4", Label: "4", Children: []Node{{ID: "5", Label: "5"}}}}}}}}}},
	} {
		if _, err := svc.Save(Config{Revision: 1, Nodes: nodes}); !errors.Is(err, ErrInvalid) {
			t.Fatalf("accepted invalid: %v", err)
		}
	}
	reloaded, err := New(store, svc.exists).Get()
	if err != nil || reloaded.Revision != 1 || reloaded.Nodes[0].Children[1].ScreenID != "B" {
		t.Fatal(reloaded, err)
	}
	var wg sync.WaitGroup
	success := make(chan bool, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := svc.Save(saved); success <- err == nil }()
	}
	wg.Wait()
	close(success)
	count := 0
	for ok := range success {
		if ok {
			count++
		}
	}
	if count != 1 {
		t.Fatal(count)
	}
}

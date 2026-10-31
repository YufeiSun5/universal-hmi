package stations

import (
	"encoding/json"
	"errors"
	"sync"
	"testing"
)

type memoryStore struct {
	data []byte
	fail bool
}

func (s *memoryStore) LoadConfig(_ string, v any) error {
	if s.data == nil {
		return nil
	}
	return json.Unmarshal(s.data, v)
}
func (s *memoryStore) SaveConfig(_ string, v any) error {
	if s.fail {
		return errors.New("disk full")
	}
	b, e := json.Marshal(v)
	s.data = b
	return e
}
func TestEmptyStationPersistenceDuplicatesAndFailure(t *testing.T) {
	store := &memoryStore{}
	legacy := []string{"existing", ""}
	s := New(store, func() ([]string, error) { return legacy, nil })
	if _, e := s.Create(" existing "); !errors.Is(e, ErrExists) {
		t.Fatal(e)
	}
	if _, e := s.Create(" new "); e != nil {
		t.Fatal(e)
	}
	legacy = nil
	rows, e := New(store, nil).List()
	if e != nil || len(rows) != 2 || rows[1].Name != "new" {
		t.Fatal(rows, e)
	}
	store.fail = true
	if _, e := s.Create("lost"); e == nil {
		t.Fatal("failure hidden")
	}
	store.fail = false
	for _, name := range []string{"", "\t", "bad\nname"} {
		if _, e := s.Create(name); !errors.Is(e, ErrInvalid) {
			t.Fatal(name, e)
		}
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, e := s.Create("parallel"); results <- e }()
	}
	wg.Wait()
	close(results)
	success := 0
	for e := range results {
		if e == nil {
			success++
		} else if !errors.Is(e, ErrExists) {
			t.Fatal(e)
		}
	}
	if success != 1 {
		t.Fatal(success)
	}
}

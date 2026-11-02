package overview

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

type memoryStore struct {
	raw  []byte
	fail bool
}

func (m *memoryStore) LoadConfig(_ string, v any) error {
	if len(m.raw) == 0 {
		return nil
	}
	return json.Unmarshal(m.raw, v)
}
func (m *memoryStore) SaveConfig(_ string, v any) error {
	if m.fail {
		return errors.New("disk full")
	}
	m.raw, _ = json.Marshal(v)
	return nil
}
func TestRevisionScopeRevocationAndStorageFailure(t *testing.T) {
	store := &memoryStore{}
	s := New(store)
	c := Config{Outdoor: Binding{PointID: "private-B"}, Columns: []Column{{ID: "temp", Group: "一次网", Name: "温度", Decimals: 2}}, Rows: []Row{
		{ID: "a", Site: "一所", Area: "一区", Name: "A", Station: "A", Bindings: map[string]string{"temp": "private-B"}},
		{ID: "b", Site: "二所", Area: "秘密区域", Name: "秘密站B", Station: "B", Bindings: map[string]string{"temp": "private-B"}},
	}}
	stations := func(v string) error {
		if v == "A" || v == "B" {
			return nil
		}
		return errors.New("station missing")
	}
	points := map[string]bool{"private-B": true}
	saved, err := s.Save(context.Background(), c, points, stations)
	if err != nil || saved.Revision != 1 {
		t.Fatal(saved, err)
	}
	if _, err = s.Save(context.Background(), c, points, stations); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	valid := true
	viewer := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}, StationID: func(v string) string { return v }, Valid: func() bool { return valid }})
	scoped, err := s.Get(viewer, map[string]bool{})
	if err != nil || scoped.Outdoor.PointID != "" || scoped.Rows[0].Site != "一所" || len(scoped.Rows) != 1 || scoped.Rows[0].Name != "A" || len(scoped.Rows[0].Bindings) != 0 {
		t.Fatal(scoped, err)
	}
	if _, err = s.Save(viewer, saved, points, stations); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	valid = false
	if _, err = s.Get(viewer, points); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal(err)
	}
	before := string(store.raw)
	store.fail = true
	if _, err = s.Save(context.Background(), saved, points, stations); err == nil || string(store.raw) != before {
		t.Fatal("failed write changed config")
	}
	store.fail = false
	saved.Rows[0].Bindings["temp"] = "missing"
	if _, err = s.Save(context.Background(), saved, points, stations); err == nil || string(store.raw) != before {
		t.Fatal("missing reference accepted")
	}
}

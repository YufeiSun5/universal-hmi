package identity

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"sync"
	"testing"
)

func TestPersonalHomeRevisionIsolationAndSessionSurvival(t *testing.T) {
	s, owner := fixture(t)
	admin := s.Actor(owner)
	u, e := s.Change(admin, "", Change{Username: "reader", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if e != nil {
		t.Fatal(e)
	}
	a := s.Actor(u)
	_, _, token, e := s.Login(u.Username, testPassword, "test", true)
	if e != nil {
		t.Fatal(e)
	}
	initial, e := s.Preferences(a)
	if e != nil || initial != (Preferences{}) {
		t.Fatalf("initial %+v %v", initial, e)
	}
	saved, e := s.SavePreferences(a, Preferences{Home: "materials/inbound"})
	if e != nil || saved.Revision != 1 {
		t.Fatalf("save %+v %v", saved, e)
	}
	retry, e := s.SavePreferences(a, Preferences{Home: "materials/inbound"})
	if e != nil || retry != saved {
		t.Fatalf("retry %+v %v", retry, e)
	}
	if _, e = s.SavePreferences(a, Preferences{Home: "gis"}); !errors.Is(e, ErrPreferenceConflict) {
		t.Fatalf("stale %v", e)
	}
	other, e := s.Preferences(admin)
	if e != nil || other.Home != "" {
		t.Fatal("preferences leaked to admin", e)
	}
	if _, _, e = s.Resolve(token, false); e != nil {
		t.Fatal("preference edit revoked session", e)
	}
	changed, e := s.User(u.ID)
	if e != nil || changed.Version != u.Version || changed.Grants.Develop() {
		t.Fatal("preference edit changed policy", e)
	}
	if _, e = s.SavePreferences(a, Preferences{Home: "https://evil.invalid", Revision: 1}); e == nil {
		t.Fatal("accepted URL")
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, home := range []string{"gis", "overview"} {
		wg.Add(1)
		go func(h string) {
			defer wg.Done()
			_, e := s.SavePreferences(a, Preferences{Home: h, Revision: 1})
			results <- e
		}(home)
	}
	wg.Wait()
	close(results)
	ok, conflict := 0, 0
	for e := range results {
		if e == nil {
			ok++
		} else if errors.Is(e, ErrPreferenceConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if ok != 1 || conflict != 1 {
		t.Fatalf("concurrent %d %d", ok, conflict)
	}
	if _, e = s.SavePreferences(authorization.Actor{ID: u.ID, Version: u.Version, Valid: func() bool { return false }}, Preferences{Home: "gis", Revision: 2}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
}

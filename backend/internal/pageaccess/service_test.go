package pageaccess

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"testing"
)

type screensFixture []process.Summary

func (f screensFixture) VisibleList(context.Context, string, bool) ([]process.Summary, error) {
	return f, nil
}

type externalFixture []externaldata.Screen

func (f externalFixture) Screens(context.Context) ([]externaldata.Screen, error) { return f, nil }

type accountsFixture struct{ pref identity.Preferences }

func (f *accountsFixture) Preferences(authorization.Actor) (identity.Preferences, error) {
	return f.pref, nil
}
func (f *accountsFixture) SavePreferences(_ authorization.Actor, p identity.Preferences) (identity.Preferences, error) {
	f.pref = p
	return p, nil
}
func TestPageAccessUsesReadScopesAndDoesNotRewriteHome(t *testing.T) {
	prefs := &accountsFixture{identity.Preferences{Home: "materials/inbound", Revision: 1}}
	s := Service{Accounts: prefs, External: externalFixture{{ID: "alarm", Kind: "alarm"}, {ID: "energy", Kind: "energy"}}}
	actor := authorization.Actor{ID: "reader", Valid: func() bool { return true }, Grants: authorization.Grants{Roles: []string{"viewer"}, MaterialsRequest: true}}
	read := func() Result {
		t.Helper()
		r, e := s.Catalog(authorization.WithActor(context.Background(), actor))
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	has := func(r Result, id string) bool {
		for _, p := range r.Pages {
			if p.ID == id {
				return true
			}
		}
		return false
	}
	r := read()
	if len(r.Pages) != 2 || !has(r, "materials/applications") || !has(r, "materials/chains") {
		t.Fatalf("requester %+v", r)
	}
	if r.Preferences.Home != "materials/inbound" {
		t.Fatal("catalog rewrote inaccessible preference")
	}
	if _, e := s.SaveHome(authorization.WithActor(context.Background(), actor), identity.Preferences{Home: "materials/inbound"}); e == nil {
		t.Fatal("saved unauthorized destination")
	}
	actor.Grants = authorization.Grants{Roles: []string{"admin"}, AllStations: true}
	r = read()
	if has(r, "history") || has(r, "energy") || has(r, "alarms") {
		t.Fatal("admin config access became data access")
	}
	if !has(r, "total-reports") || !has(r, "equipment") {
		t.Fatal("read access depended on edit permission")
	}
	actor.Grants = authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{"alarm"}}
	r = read()
	if !has(r, "alarms") || !has(r, "history") || has(r, "energy") {
		t.Fatalf("external scope %+v", r)
	}
	actor.Grants = authorization.Grants{Roles: []string{"viewer"}}
	r = read()
	if len(r.Pages) != 0 {
		t.Fatal("empty scope", r)
	}
	s.Screens = screensFixture{{ID: "only", Kind: "process"}}
	r = read()
	if !has(r, "process") || has(r, "overview") || has(r, "equipment") {
		t.Fatal("screen-only scope widened", r)
	}
	actor.Valid = func() bool { return false }
	if _, e := s.Catalog(authorization.WithActor(context.Background(), actor)); e == nil {
		t.Fatal("revoked actor")
	}
}

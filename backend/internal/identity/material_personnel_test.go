package identity

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

func TestMaterialPersonnelDirectoryUsesUsernameAndChecksAccess(t *testing.T) {
	s, owner := fixture(t)
	admin := s.Actor(owner)
	user, e := s.Change(admin, "", Change{Username: "采购用户", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, MaterialsInbound: true}})
	if e != nil {
		t.Fatal(e)
	}
	actor := s.Actor(user)
	directory, e := s.MaterialPersonnel(actor)
	if e != nil || directory[user.ID] != "采购用户" || actor.DisplayName != "采购用户" {
		t.Fatal(directory, actor.DisplayName, e)
	}
	if _, e = s.Users(actor); !errors.Is(e, ErrDenied) {
		t.Fatal("personnel permission became user administration", e)
	}
	for _, a := range []authorization.Actor{{ID: "catalog", Grants: authorization.Grants{MaterialsCatalog: true}, Valid: func() bool { return true }}, {ID: "off", Grants: authorization.Grants{MaterialsInbound: true}, Valid: func() bool { return false }}} {
		if _, e = s.MaterialPersonnel(a); !errors.Is(e, ErrDenied) {
			t.Fatal("unauthorized directory", e)
		}
	}
	changed, e := s.Change(admin, user.ID, Change{Username: "采购改名", Version: user.Version, Grants: user.Grants, Disabled: true})
	if e != nil {
		t.Fatal(e)
	}
	reader := authorization.Actor{ID: owner.ID, Grants: authorization.Grants{MaterialsOutbound: true}, Valid: func() bool { return true }}
	directory, e = s.MaterialPersonnel(reader)
	if e != nil {
		t.Fatal(e)
	}
	if _, ok := directory[changed.ID]; ok {
		t.Fatal("disabled account selectable")
	}
	if actor.DisplayName != "采购用户" {
		t.Fatal("old actor name mutated")
	}
}

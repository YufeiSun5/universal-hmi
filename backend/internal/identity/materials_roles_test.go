package identity

import (
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"testing"
)

func TestMaterialsRolesExplicitGrantAndRevocation(t *testing.T) {
	s, err := OpenDatabase(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner, err := s.Bootstrap("owner", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	g := owner.Grants
	if g.MaterialsRequest || g.MaterialsApprove || g.MaterialsInbound || g.MaterialsOutbound || g.MaterialsCatalog {
		t.Fatal("admin implicitly received materials rights")
	}
	a := s.Actor(owner)
	granted := authorization.Grants{Roles: []string{"viewer"}, MaterialsRequest: true, MaterialsApprove: true, MaterialsInbound: true, MaterialsOutbound: true, MaterialsCatalog: true}
	role, err := s.ChangeRole(a, "", Role{Name: "warehouse", Grants: granted}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	user, err := s.Change(a, "", Change{Username: "worker", Password: testPassword, CustomRoleIDs: []string{role.ID}, Grants: authorization.Grants{Roles: []string{"viewer"}}})
	if err != nil {
		t.Fatal(err)
	}
	g = user.Grants
	if !g.MaterialsRequest || !g.MaterialsApprove || !g.MaterialsInbound || !g.MaterialsOutbound || !g.MaterialsCatalog || g.Develop() {
		t.Fatal("material role aggregation failed")
	}
	old := s.Actor(user)
	role.Grants = authorization.Grants{Roles: []string{"viewer"}}
	if _, err = s.ChangeRole(a, role.ID, role, nil, false); err != nil {
		t.Fatal(err)
	}
	user, err = s.User(user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if old.Active() || user.Grants.MaterialsOutbound || user.Grants.MaterialsInbound || user.Grants.MaterialsCatalog || user.Grants.MaterialsApprove || user.Grants.MaterialsRequest {
		t.Fatal("revoked role retained permissions")
	}
	manager := authorization.Grants{Roles: []string{"viewer"}, UserManagement: true}
	if manager.MayGrant(granted) {
		t.Fatal("delegated manager escalated materials permissions")
	}
}

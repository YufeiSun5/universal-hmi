package identity

import (
	"errors"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestMaintenanceRolesScopeAndRevocation(t *testing.T) {
	s, owner := fixture(t)
	if err := s.RegisterStations([]string{"A", "B"}); err != nil {
		t.Fatal(err)
	}
	a := s.Actor(owner)
	scope := s.StationID("A")
	role, err := s.ChangeRole(a, "", Role{Name: "maintenance", Grants: authorization.Grants{
		Roles: []string{"viewer"}, UserManagement: true, DeviceApproval: true, CertificateManagement: true, EquipmentEdit: true,
	}}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := s.Change(a, "", Change{Username: "manager", Password: testPassword,
		Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{scope}}, CustomRoleIDs: []string{role.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if !manager.Grants.ManageUsers() || !manager.Grants.ApproveDevices() || !manager.Grants.ManageCertificates() || !manager.Grants.EditEquipment() || manager.Grants.Develop() {
		t.Fatal("role capabilities", manager.Grants)
	}
	m := s.Actor(manager)
	reader, err := s.Change(m, "", Change{Username: "reader", Password: testPassword,
		Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{scope}, EquipmentEdit: true}})
	if err != nil {
		t.Fatal(err)
	}
	outside, err := s.Change(a, "", Change{Username: "outside", Password: testPassword,
		Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{s.StationID("B")}}})
	if err != nil {
		t.Fatal(err)
	}
	for _, victim := range []User{outside, owner, manager} {
		_, err = s.Change(m, victim.ID, Change{Username: victim.Username, Password: testPassword + "new", Version: victim.Version, Grants: reader.Grants})
		if err == nil {
			t.Fatal("changed protected account", victim.Username)
		}
		if victim.ID != manager.ID && s.ResetMFA(m, victim.ID) == nil {
			t.Fatal("MFA reset escaped ceiling")
		}
		if victim.ID != manager.ID && s.Revoke(m, victim.ID, "") == nil {
			t.Fatal("session revoke escaped ceiling")
		}
	}
	users, err := s.Users(m)
	if err != nil || len(users) != 2 {
		t.Fatal("scoped users", users, err)
	}
	high, err := s.ChangeRole(a, "", Role{Name: "engineers", Grants: authorization.Grants{Roles: []string{"engineer"}}}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Change(m, reader.ID, Change{Username: reader.Username, Version: reader.Version, Grants: reader.Grants, CustomRoleIDs: []string{high.ID}}); !errors.Is(err, ErrDenied) {
		t.Fatal("custom role escalation", err)
	}
	// Updating a shared role also validates every existing member's scope.
	shared, err := s.ChangeRole(a, "", Role{Name: "shared workers", Grants: authorization.Grants{Roles: []string{"viewer"}, EquipmentEdit: true}}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	shared, err = s.ChangeRole(a, shared.ID, shared, []RoleMemberChange{{UserID: outside.ID, Version: outside.Version, Assigned: true}}, false)
	if err != nil {
		t.Fatal(err)
	}
	shared.Name = "renamed"
	if _, err = s.ChangeRole(m, shared.ID, shared, nil, false); !errors.Is(err, ErrDenied) {
		t.Fatal("out-of-scope role member mutation", err)
	}
	_, _, token, err := s.Login(manager.Username, testPassword, "fixture", true)
	if err != nil {
		t.Fatal(err)
	}
	// A role change revokes a delegated user's established sessions.
	role.Grants.EquipmentEdit = false
	role, err = s.ChangeRole(a, role.ID, role, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Resolve(token, false); err == nil {
		t.Fatal("role revocation retained session")
	}
	persisted, err := s.User(manager.ID)
	if err != nil || persisted.Grants.EquipmentEdit || !persisted.Grants.DeviceApproval {
		t.Fatal("stored permission union", persisted.Grants, err)
	}
}

func TestDeviceApprovalAndCertificateCapabilitiesAreIndependent(t *testing.T) {
	s, owner, registration, raw, _ := certificateFixture(t)
	a := s.Actor(owner)
	makeActor := func(name string, approvals, certificates bool) authorization.Actor {
		u, err := s.Change(a, "", Change{Username: name, Password: testPassword, Grants: authorization.Grants{
			Roles: []string{"viewer"}, DeviceApproval: approvals, CertificateManagement: certificates,
		}})
		if err != nil {
			t.Fatal(err)
		}
		return s.Actor(u)
	}
	approver := makeActor("approver", true, false)
	certifier := makeActor("certifier", false, true)
	if _, err := s.Users(approver); !errors.Is(err, ErrDenied) {
		t.Fatal("approver read user policies", err)
	}
	if users, err := s.DeviceOwners(approver); err != nil || len(users) != 3 {
		t.Fatal("owner labels", err)
	}
	if _, err := s.DeviceRegistrations(certifier); err != nil {
		t.Fatal("certificate reviewer needs registration read", err)
	}
	if _, err := s.ApproveLoginDevice(approver, registration.Revision, registration.Items[0].ID); !errors.Is(err, ErrDenied) {
		t.Fatal("combined approval bypassed certificate permission", err)
	}
	if _, err := s.DisableDeviceRegistration(certifier, registration.Revision, registration.Items[0].ID); !errors.Is(err, ErrDenied) {
		t.Fatal("certificate capability disabled registration", err)
	}
	if _, err := s.ApproveDeviceCertificate(approver, 0, registration.Items[0].ID, raw, time.Now().Add(time.Hour)); !errors.Is(err, ErrDenied) {
		t.Fatal("approver confirmed certificate", err)
	}
	doc, err := s.ApproveDeviceCertificate(certifier, 0, registration.Items[0].ID, raw, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.RevokeDeviceCertificate(certifier, doc.Revision, registration.Items[0].ID); err != nil {
		t.Fatal(err)
	}
}

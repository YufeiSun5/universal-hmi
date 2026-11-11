package authorization

import "testing"

func TestMaintenanceGrantCeiling(t *testing.T) {
	g := Grants{Roles: []string{"viewer"}, UserManagement: true, DeviceApproval: true, EquipmentEdit: true,
		StationIDs: []string{"A"}, ScreenIDs: []string{"screenA"}, ExternalScreenIDs: []string{"externalA"}}
	base := Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}
	if !g.MayGrant(base) {
		t.Fatal("within-scope delegation rejected")
	}
	for name, change := range map[string]func(*Grants){
		"all stations":   func(n *Grants) { n.AllStations = true },
		"other station":  func(n *Grants) { n.StationIDs = []string{"B"} },
		"other screen":   func(n *Grants) { n.ScreenIDs = []string{"screenB"} },
		"other external": func(n *Grants) { n.ExternalScreenIDs = []string{"externalB"} },
		"engineer":       func(n *Grants) { n.Roles = []string{"engineer"} },
		"admin":          func(n *Grants) { n.Roles = []string{"admin"} },
		"control":        func(n *Grants) { n.Control = true },
		"grant control":  func(n *Grants) { n.GrantControl = true },
		"export":         func(n *Grants) { n.Export = true },
		"certificate":    func(n *Grants) { n.CertificateManagement = true },
	} {
		t.Run(name, func(t *testing.T) {
			next := base
			change(&next)
			if g.MayGrant(next) {
				t.Fatal("ceiling exceeded")
			}
		})
	}
	base.DeviceApproval, base.EquipmentEdit, base.UserManagement = true, true, true
	if !g.MayGrant(base) {
		t.Fatal("held maintenance capabilities not grantable")
	}
	ceiling := Grants{Roles: []string{"admin", "engineer"}, AllStations: true, Export: true, GrantControl: true}
	remote := Actor{Grants: Grants{Roles: []string{"viewer"}, UserManagement: true}, GrantLimits: &ceiling}
	if !remote.MayGrant(Grants{Roles: []string{"engineer"}, AllStations: true}) || remote.Grants.Develop() {
		t.Fatal("delegation confused with request capability")
	}
	remote.Grants.UserManagement = false
	if remote.MayGrant(base) {
		t.Fatal("ceiling alone granted user management")
	}
}

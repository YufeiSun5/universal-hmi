package authorization

import "testing"

func TestTotalReportsDelegationIsSeparate(t *testing.T) {
	manager := Grants{Roles: []string{"viewer"}, UserManagement: true, AllStations: true, TotalReportsEdit: true}
	if !manager.MayGrant(Grants{Roles: []string{"viewer"}, AllStations: true, TotalReportsEdit: true}) {
		t.Fatal("editor could not delegate own grant")
	}
	if manager.MayGrant(Grants{Roles: []string{"viewer"}, TotalReportsRollback: true}) {
		t.Fatal("edit implicitly grants rollback")
	}
	manager.TotalReportsEdit = false
	manager.TotalReportsRollback = true
	if manager.MayGrant(Grants{Roles: []string{"viewer"}, TotalReportsEdit: true}) {
		t.Fatal("rollback implicitly grants edit")
	}
	if !manager.MayGrant(Grants{Roles: []string{"viewer"}, TotalReportsRollback: true}) {
		t.Fatal("rollback holder could not delegate own grant")
	}
}

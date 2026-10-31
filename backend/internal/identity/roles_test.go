package identity

import (
	"fmt"
	"net/url"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

func TestCustomRolesSQLiteAndPostgres(t *testing.T) {
	for _, mode := range []string{"sqlite", "postgres"} {
		t.Run(mode, func(t *testing.T) {
			dsn := ""
			if mode == "postgres" {
				path := os.Getenv("HMI_PG_TEST_CONFIG")
				if path == "" {
					t.Skip("real PostgreSQL configuration required")
				}
				var e error
				dsn, e = persistence.ConfigFile(path)
				if e != nil {
					t.Fatal(e)
				}
				admin, e := persistence.Open("", dsn)
				if e != nil {
					t.Fatal(e)
				}
				defer admin.Close()
				schema := fmt.Sprintf("hmi_roles_%d", time.Now().UnixNano())
				if _, e = admin.Exec("CREATE SCHEMA " + schema); e != nil {
					t.Fatal(e)
				}
				defer func() {
					if _, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE"); e != nil {
						t.Error(e)
					}
				}()
				u, e := url.Parse(dsn)
				if e != nil {
					t.Fatal(e)
				}
				q := u.Query()
				q.Set("search_path", schema)
				u.RawQuery = q.Encode()
				dsn = u.String()
			}
			dir := t.TempDir()
			s, e := OpenDatabase(dir, dsn)
			if e != nil {
				t.Fatal(e)
			}
			defer func() { s.Close() }()
			owner, e := s.Bootstrap("owner", testPassword)
			if e != nil {
				t.Fatal(e)
			}
			a := s.Actor(owner)
			if e = s.RegisterStations([]string{"A", "B"}); e != nil {
				t.Fatal(e)
			}
			r, e := s.ChangeRole(a, "", Role{Name: "值班长", Grants: authorization.Grants{Roles: []string{"viewer", "operator"}, Export: true}}, nil, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.ChangeRole(a, "", Role{Name: r.Name, Grants: r.Grants}, nil, false); e == nil {
				t.Fatal("duplicate name accepted")
			}
			create := func(name string) User {
				u, e := s.Change(a, "", Change{Username: name, Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{s.StationID("A")}}})
				if e != nil {
					t.Fatal(e)
				}
				return u
			}
			u, v := create("reader"), create("other")
			_, _, token, e := s.Login(u.Username, testPassword, "before", true)
			if e != nil {
				t.Fatal(e)
			}
			oldActor := s.Actor(u)
			// A bad second member must roll back the first member and the role version.
			if _, e = s.ChangeRole(a, r.ID, r, []RoleMemberChange{{UserID: u.ID, Version: u.Version, Assigned: true}, {UserID: v.ID, Version: 999, Assigned: true}}, false); e == nil {
				t.Fatal("stale batch accepted")
			}
			unchanged, _ := s.User(u.ID)
			if unchanged.Version != u.Version || unchanged.Grants.Export {
				t.Fatal("partial member commit")
			}
			r, e = s.ChangeRole(a, r.ID, r, []RoleMemberChange{{UserID: u.ID, Version: u.Version, Assigned: true}, {UserID: v.ID, Version: v.Version, Assigned: true}}, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, _, e = s.Resolve(token, false); e == nil || oldActor.Active() {
				t.Fatal("membership kept old session/actor")
			}
			u, _ = s.User(u.ID)
			v, _ = s.User(v.ID)
			if !u.Grants.Export || !u.Grants.Has("operator") || u.Grants.AllStations || s.Actor(u).Station("B") || !s.Actor(u).Station("A") {
				t.Fatal("role did not preserve scope")
			}
			roles, e := s.Roles(a)
			if e != nil || len(roles) != 1 || roles[0].Members != 2 {
				t.Fatalf("members: %v %v", roles, e)
			}
			if _, e = s.ChangeRole(a, r.ID, r, nil, true); e == nil {
				t.Fatal("assigned role deleted")
			}
			_, _, token, e = s.Login(u.Username, testPassword, "after", true)
			if e != nil {
				t.Fatal(e)
			}
			previous := r
			r.Grants.Export = false
			r.Name = "运行值班长"
			r, e = s.ChangeRole(a, r.ID, r, nil, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.ChangeRole(a, r.ID, previous, nil, false); e == nil {
				t.Fatal("stale role overwrote update")
			}
			if _, _, e = s.Resolve(token, false); e == nil {
				t.Fatal("role edit kept session")
			}
			u, _ = s.User(u.ID)
			if u.Grants.Export {
				t.Fatal("role removal left cached privilege")
			}
			listed, e := s.Users(a)
			if e != nil {
				t.Fatal(e)
			}
			for _, item := range listed {
				if item.ID == u.ID {
					if item.DirectGrants == nil || item.DirectGrants.Has("operator") || !slices.Contains(item.CustomRoleIDs, r.ID) {
						t.Fatal("direct and inherited permissions conflated")
					}
				}
			}
			// A non-engineer administrator cannot define, assign or edit engineering roles.
			admin, e := s.Change(a, "", Change{Username: "admin", Password: testPassword, Grants: authorization.Grants{Roles: []string{"admin"}, AllStations: true}})
			if e != nil {
				t.Fatal(e)
			}
			eng, e := s.ChangeRole(a, "", Role{Name: "维修工程师", Grants: authorization.Grants{Roles: []string{"engineer"}}}, nil, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.ChangeRole(s.Actor(admin), "", Role{Name: "escape", Grants: eng.Grants}, nil, false); e == nil {
				t.Fatal("admin created engineering capability")
			}
			if _, e = s.ChangeRole(s.Actor(admin), eng.ID, eng, []RoleMemberChange{{UserID: u.ID, Version: u.Version, Assigned: true}}, false); e == nil {
				t.Fatal("admin assigned engineering capability")
			}
			if _, e = s.ChangeRole(s.Actor(u), "", Role{Name: "escape", Grants: r.Grants}, nil, false); e == nil {
				t.Fatal("viewer managed roles")
			}
			if _, e = s.Change(a, u.ID, Change{Username: u.Username, Version: u.Version, CustomRoleIDs: []string{"unknown"}, Grants: authorization.Grants{Roles: []string{"viewer"}}}); e == nil {
				t.Fatal("unknown role accepted")
			}
			// Per-user editor also resolves custom role capabilities, never role scopes.
			u, e = s.Change(a, u.ID, Change{Username: u.Username, Version: u.Version, CustomRoleIDs: []string{eng.ID}, Grants: authorization.Grants{Roles: []string{}, StationIDs: []string{s.StationID("A")}}})
			if e != nil {
				t.Fatal(e)
			}
			if u.Grants.Develop() || !u.Grants.Has("engineer") {
				t.Fatal("restricted engineer scope bypass")
			}
			// Self membership mutation cannot be used to expand privileges.
			if _, e = s.ChangeRole(a, r.ID, r, []RoleMemberChange{{UserID: owner.ID, Version: owner.Version, Assigned: true}}, false); e == nil {
				t.Fatal("self role assignment accepted")
			}
			// Persisted effective grants and role policies must survive service restart.
			if e = s.Close(); e != nil {
				t.Fatal(e)
			}
			s, e = OpenDatabase(dir, dsn)
			if e != nil {
				t.Fatal(e)
			}
			u, e = s.User(u.ID)
			if e != nil || !u.Grants.Has("engineer") {
				t.Fatal("role persistence failed")
			}
			roles, e = s.Roles(s.Actor(owner))
			if e != nil || len(roles) != 2 {
				t.Fatal("role catalog persistence failed")
			}
			v, _ = s.User(v.ID)
			r, e = s.ChangeRole(s.Actor(owner), r.ID, r, []RoleMemberChange{{UserID: v.ID, Version: v.Version, Assigned: false}}, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.ChangeRole(s.Actor(owner), r.ID, r, nil, true); e != nil {
				t.Fatal(e)
			}
		})
	}
}

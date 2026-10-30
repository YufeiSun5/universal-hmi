package identity

import (
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestPasswordPoliciesAcrossAccountOperations(t *testing.T) {
	for _, local := range []bool{false, true} {
		name, valid, short, minimum := "remote", "admin12", "admin1", 7
		if local {
			name, valid, short, minimum = "local", "admin", "admi", 5
		}
		t.Run(name, func(t *testing.T) {
			s, err := OpenDatabase(t.TempDir(), "", Options{LocalPasswords: local})
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			if s.PasswordMinimum() != minimum {
				t.Fatal("wrong policy")
			}
			if _, err = s.Bootstrap("owner", short); err == nil || !s.NeedsSetup() {
				t.Fatal("short bootstrap password accepted")
			}
			owner, err := s.Bootstrap("owner", valid)
			if err != nil {
				t.Fatal(err)
			}
			a := s.Actor(owner)
			in := Change{Username: "leader", Password: short, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}}
			if _, err = s.Change(a, "", in); err == nil {
				t.Fatal("short account password accepted")
			}
			in.Password = valid
			u, err := s.Change(a, "", in)
			if err != nil {
				t.Fatal(err)
			}
			_, _, token, err := s.Login(u.Username, valid, "policy-test", true)
			if err != nil {
				t.Fatal(err)
			}
			if err = s.ChangePassword(s.Actor(u), valid, short); err == nil {
				t.Fatal("short password change accepted")
			}
			if err = s.ChangePassword(s.Actor(u), valid, valid+"x"); err != nil {
				t.Fatal(err)
			}
			if _, _, err := s.Resolve(token, false); err == nil {
				t.Fatal("password change retained old session")
			}
			var version int64
			if err = s.db.QueryRow("SELECT version FROM users WHERE id=?", u.ID).Scan(&version); err != nil {
				t.Fatal(err)
			}
			in.Version, in.Password = version, short
			if _, err = s.Change(a, u.ID, in); err == nil {
				t.Fatal("short reset password accepted")
			}
			in.Password = valid
			if _, err = s.Change(a, u.ID, in); err != nil {
				t.Fatal(err)
			}
			if _, _, _, err = s.Login(u.Username, valid, "after-reset", true); err != nil {
				t.Fatal(err)
			}
			if _, err = s.passwordHash(strings.Repeat("ab", 65)); err == nil {
				t.Fatal("oversized password accepted")
			}
		})
	}
}

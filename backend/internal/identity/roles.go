package identity

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

type Role struct {
	ID      string               `json:"id"`
	Name    string               `json:"name"`
	Version int64                `json:"version"`
	Grants  authorization.Grants `json:"grants"`
	Members int                  `json:"members"`
}
type RoleMemberChange struct {
	UserID   string `json:"user_id"`
	Version  int64  `json:"version"`
	Assigned bool   `json:"assigned"`
}
type rolePolicy struct {
	Direct authorization.Grants
	IDs    []string
}

func policyTx(tx *persistence.Tx, u User) (rolePolicy, error) {
	p := rolePolicy{Direct: u.Grants, IDs: []string{}}
	var direct, ids string
	e := tx.QueryRow("SELECT direct_grants,role_ids FROM user_role_policy WHERE user_id=?", u.ID).Scan(&direct, &ids)
	if e == sql.ErrNoRows {
		return p, nil
	}
	if e != nil {
		return p, e
	}
	if e = json.Unmarshal([]byte(direct), &p.Direct); e != nil {
		return p, e
	}
	e = json.Unmarshal([]byte(ids), &p.IDs)
	return p, e
}
func savePolicy(tx *persistence.Tx, id string, p rolePolicy) error {
	d, _ := json.Marshal(p.Direct)
	r, _ := json.Marshal(p.IDs)
	_, e := tx.Exec("INSERT INTO user_role_policy(user_id,direct_grants,role_ids) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET direct_grants=excluded.direct_grants,role_ids=excluded.role_ids", id, string(d), string(r))
	return e
}
func effectiveTx(tx *persistence.Tx, p rolePolicy) (authorization.Grants, error) {
	g := p.Direct
	g.Roles = append([]string{}, g.Roles...)
	// Direct grants may be empty when all capabilities come from custom roles.
	check := g
	if len(check.Roles) == 0 {
		check.Roles = []string{"viewer"}
	}
	if check.Validate() != nil || len(p.IDs) > 64 {
		return g, ErrDenied
	}
	seen := map[string]bool{}
	for _, id := range p.IDs {
		if seen[id] {
			return g, fmt.Errorf("重复角色")
		}
		seen[id] = true
		var raw string
		if e := tx.QueryRow("SELECT grants FROM custom_roles WHERE id=?", id).Scan(&raw); e != nil {
			return g, fmt.Errorf("角色不存在，请刷新")
		}
		var r authorization.Grants
		if e := json.Unmarshal([]byte(raw), &r); e != nil {
			return g, e
		}
		for _, v := range r.Roles {
			if !slices.Contains(g.Roles, v) {
				g.Roles = append(g.Roles, v)
			}
		}
		g.Export = g.Export || r.Export
		g.Control = g.Control || r.Control
		g.GrantControl = g.GrantControl || r.GrantControl
	}
	if len(g.Roles) == 0 {
		g.Roles = []string{"viewer"}
	}
	return g, g.Validate()
}
func (s *Service) Roles(a authorization.Actor) ([]Role, error) {
	if !a.Active() || !a.Grants.Manage() {
		return nil, ErrDenied
	}
	rows, e := s.db.Query("SELECT id,name,version,grants FROM custom_roles ORDER BY name")
	if e != nil {
		return nil, e
	}
	out := []Role{}
	for rows.Next() {
		var r Role
		var raw string
		if e = rows.Scan(&r.ID, &r.Name, &r.Version, &raw); e == nil {
			e = json.Unmarshal([]byte(raw), &r.Grants)
		}
		if e != nil {
			rows.Close()
			return nil, e
		}
		out = append(out, r)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return nil, e
	}
	rows, e = s.db.Query("SELECT role_ids FROM user_role_policy")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	for rows.Next() {
		var raw string
		var ids []string
		if e = rows.Scan(&raw); e != nil {
			return nil, e
		}
		if e = json.Unmarshal([]byte(raw), &ids); e != nil {
			return nil, e
		}
		for i := range out {
			if slices.Contains(ids, out[i].ID) {
				out[i].Members++
			}
		}
	}
	return out, rows.Err()
}

// ChangeRole changes a role definition, membership or deletes an unused role.
// The complete policy update and user version changes share one transaction.
func (s *Service) ChangeRole(a authorization.Actor, id string, in Role, members []RoleMemberChange, remove bool) (Role, error) {
	if !a.Active() || !a.Grants.Manage() {
		return Role{}, ErrDenied
	}
	if len(members) > 1000 {
		return Role{}, fmt.Errorf("一次最多修改1000个成员")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(a.ID, a.Version) {
		return Role{}, ErrDenied
	}
	tx, e := s.db.Begin()
	if e != nil {
		return Role{}, e
	}
	defer tx.Rollback()
	var old Role
	if id != "" {
		var raw string
		if e = tx.QueryRow("SELECT id,name,version,grants FROM custom_roles WHERE id=?", id).Scan(&old.ID, &old.Name, &old.Version, &raw); e != nil {
			return Role{}, fmt.Errorf("角色不存在")
		}
		if e = json.Unmarshal([]byte(raw), &old.Grants); e != nil {
			return Role{}, e
		}
		if old.Version != in.Version {
			return Role{}, fmt.Errorf("角色版本已变化，请刷新")
		}
		if !a.Grants.MayGrant(old.Grants) {
			return Role{}, ErrDenied
		}
	}
	if members != nil || remove {
		in = Role{ID: id, Name: old.Name, Version: old.Version, Grants: old.Grants}
	}
	if !remove {
		in.Name = strings.TrimSpace(in.Name)
		if !usernameValid(in.Name) || len(in.Name) > 128 || in.Grants.AllStations || len(in.Grants.StationIDs) > 0 || len(in.Grants.ScreenIDs) > 0 || len(in.Grants.ExternalScreenIDs) > 0 {
			return Role{}, fmt.Errorf("角色名称或权限无效；站点范围请在用户中配置")
		}
		if !a.Grants.MayGrant(in.Grants) {
			return Role{}, ErrDenied
		}
		var n int
		if e = tx.QueryRow("SELECT count(*) FROM custom_roles WHERE lower(name)=lower(?) AND id<>?", in.Name, id).Scan(&n); e != nil {
			return Role{}, e
		}
		if n != 0 {
			return Role{}, fmt.Errorf("角色名称已存在")
		}
		if id == "" {
			id = randomID()
		}
		in.ID = id
		in.Version = old.Version + 1
		raw, _ := json.Marshal(in.Grants)
		if _, e = tx.Exec("INSERT INTO custom_roles(id,name,version,grants) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,version=excluded.version,grants=excluded.grants", id, in.Name, in.Version, string(raw)); e != nil {
			return Role{}, e
		}
	}
	changes := map[string]RoleMemberChange{}
	for _, m := range members {
		if _, ok := changes[m.UserID]; ok {
			return Role{}, fmt.Errorf("重复成员")
		}
		changes[m.UserID] = m
	}
	rows, e := tx.Query("SELECT * FROM users")
	if e != nil {
		return Role{}, e
	}
	users := []User{}
	for rows.Next() {
		u, _, err := scanUser(rows)
		if err != nil {
			rows.Close()
			return Role{}, err
		}
		users = append(users, u)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return Role{}, e
	}
	affected := map[string]bool{}
	admins := 0
	for _, u := range users {
		p, err := policyTx(tx, u)
		if err != nil {
			return Role{}, err
		}
		had := slices.Contains(p.IDs, id)
		m, changed := changes[u.ID]
		if remove && had {
			return Role{}, fmt.Errorf("角色仍有成员，请先解除分配")
		}
		if changed {
			delete(changes, u.ID)
			if u.Version != m.Version {
				return Role{}, fmt.Errorf("成员账号版本已变化，请刷新")
			}
			if m.Assigned && !had {
				p.IDs = append(p.IDs, id)
			} else if !m.Assigned && had {
				p.IDs = slices.DeleteFunc(p.IDs, func(v string) bool { return v == id })
			}
		}
		if (had && members == nil && !remove) || (changed && m.Assigned != had) {
			if u.ID == a.ID {
				return Role{}, fmt.Errorf("不能通过角色修改自己的权限，请由另一位授权管理员操作")
			}
			g, err := effectiveTx(tx, p)
			if err != nil {
				return Role{}, err
			}
			if !a.Grants.MayGrant(u.Grants) || !a.Grants.MayGrant(g) {
				return Role{}, ErrDenied
			}
			raw, _ := json.Marshal(g)
			if _, e = tx.Exec("UPDATE users SET grants=?,version=version+1 WHERE id=?", string(raw), u.ID); e != nil {
				return Role{}, e
			}
			if e = savePolicy(tx, u.ID, p); e != nil {
				return Role{}, e
			}
			u.Grants = g
			affected[u.ID] = true
		}
		if !u.Disabled && u.Grants.Manage() {
			admins++
		}
	}
	if len(changes) > 0 {
		return Role{}, fmt.Errorf("未知成员账号")
	}
	if admins == 0 {
		return Role{}, fmt.Errorf("不能移除最后一个管理员")
	}
	action := "role.change"
	if members != nil {
		action = "role.members"
	}
	if remove {
		action = "role.delete"
		if _, e = tx.Exec("DELETE FROM custom_roles WHERE id=?", id); e != nil {
			return Role{}, e
		}
	}
	if e = auditTx(tx, a.ID, action, id, fmt.Sprintf("saved; %d user sessions revoked", len(affected))); e != nil {
		return Role{}, e
	}
	if e = tx.Commit(); e != nil {
		return Role{}, e
	}
	for k, v := range s.sessions {
		if affected[v.UserID] {
			delete(s.sessions, k)
		}
	}
	return in, nil
}

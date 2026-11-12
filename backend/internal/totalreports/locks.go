package totalreports

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

type Lease struct {
	Address string `json:"address"`
	Actor   string `json:"actor"`
	Name    string `json:"name"`
	Client  string `json:"client"`
	Expires int64  `json:"expires"`
}
type LeaseRequest struct {
	Client    string   `json:"client"`
	Addresses []string `json:"addresses"`
}
type LeaseResult struct {
	Items []Lease `json:"items"`
	Cells []Cell  `json:"cells"`
}

func (s *Service) Leases(ctx context.Context, kind string, year int) ([]Lease, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return nil, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, `SELECT address,actor,name,client,expires FROM total_report_locks WHERE doc=? AND expires>? ORDER BY address`, key, s.now().Unix())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Lease{}
	for rows.Next() {
		var v Lease
		if e = rows.Scan(&v.Address, &v.Actor, &v.Name, &v.Client, &v.Expires); e != nil {
			return nil, e
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// Acquire or renew the selected range atomically. An empty range releases this
// client's locks. Separate tabs have separate random client IDs, even when the
// account is shared. Names come only from the authenticated server identity.
func (s *Service) Acquire(ctx context.Context, kind string, year int, in LeaseRequest) (LeaseResult, error) {
	actor, e := permission(ctx, "edit")
	if e != nil {
		return LeaseResult{}, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return LeaseResult{}, e
	}
	if !operationID.MatchString(in.Client) || len(in.Addresses) > 1000 {
		return LeaseResult{}, fmt.Errorf("一次最多编辑1000格")
	}
	tx, _, t, e := s.lock(ctx, key)
	if e != nil {
		return LeaseResult{}, e
	}
	defer tx.Rollback()
	now := s.now().Unix()
	if _, e = tx.Exec(`DELETE FROM total_report_locks WHERE doc=? AND expires<=?`, key, now); e != nil {
		return LeaseResult{}, e
	}
	allowed := editable(t, year)
	seen := map[string]bool{}
	name := actor
	if a, ok := authorization.FromContext(ctx); ok && a.DisplayName != "" {
		name = a.DisplayName
	}
	for _, address := range in.Addresses {
		if !allowed[address] || seen[address] {
			return LeaseResult{}, fmt.Errorf("%s不可编辑或重复", address)
		}
		seen[address] = true
		var owner, client, label string
		e = tx.QueryRow(`SELECT actor,client,name FROM total_report_locks WHERE doc=? AND address=?`, key, address).Scan(&owner, &client, &label)
		if e != nil && e != sql.ErrNoRows {
			return LeaseResult{}, e
		}
		if e == nil && (owner != actor || client != in.Client) {
			return LeaseResult{}, fmt.Errorf("%w：%s 正在编辑 %s", ErrConflict, label, address)
		}
	}
	if _, e = tx.Exec(`DELETE FROM total_report_locks WHERE doc=? AND actor=? AND client=?`, key, actor, in.Client); e != nil {
		return LeaseResult{}, e
	}
	result := LeaseResult{Items: []Lease{}, Cells: []Cell{}}
	for _, address := range in.Addresses {
		lease := Lease{address, actor, name, in.Client, now + 45}
		if _, e = tx.Exec(`INSERT INTO total_report_locks(doc,address,actor,name,client,expires) VALUES(?,?,?,?,?,?)`, key, address, actor, name, in.Client, lease.Expires); e != nil {
			return LeaseResult{}, e
		}
		cell := Cell{Address: address}
		e = tx.QueryRow(`SELECT value,revision,actor FROM total_report_cells WHERE doc=? AND address=?`, key, address).Scan(&cell.Value, &cell.Revision, &cell.Actor)
		if e != nil && e != sql.ErrNoRows {
			return LeaseResult{}, e
		}
		cell.Format, e = readFormat(tx, key, address)
		if e != nil {
			return LeaseResult{}, e
		}
		result.Items = append(result.Items, lease)
		result.Cells = append(result.Cells, cell)
	}
	if _, e = permission(ctx, "edit"); e != nil {
		return LeaseResult{}, e
	}
	return result, tx.Commit()
}
func (s *Service) checkLease(ctx context.Context, tx *persistence.Tx, key, address, actor, client string) error {
	if !operationID.MatchString(client) {
		return fmt.Errorf("请先取得单元格编辑锁")
	}
	var owner, tab, label string
	var expires int64
	e := tx.QueryRow(`SELECT actor,client,name,expires FROM total_report_locks WHERE doc=? AND address=?`, key, address).Scan(&owner, &tab, &label, &expires)
	if e != nil && e != sql.ErrNoRows {
		return e
	}
	if e == sql.ErrNoRows || expires <= s.now().Unix() {
		return fmt.Errorf("%w：%s编辑锁已到期，请重新选择", ErrConflict, address)
	}
	if owner != actor || tab != client {
		return fmt.Errorf("%w：%s 正在编辑 %s", ErrConflict, label, address)
	}
	return nil
}

package totalreports

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
)

type DesignVersion struct {
	Revision int64  `json:"revision"`
	Created  int64  `json:"created"`
	Actor    string `json:"actor"`
}
type DesignRestore struct {
	Revision int64 `json:"revision"`
	Expected int64 `json:"expected"`
	Confirm  bool  `json:"confirm"`
}

func (s *Service) DesignHistory(ctx context.Context, kind string, year int) ([]DesignVersion, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return nil, e
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, `SELECT revision,created,actor FROM total_report_design_history WHERE doc=? ORDER BY revision DESC LIMIT 100`, key)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []DesignVersion{}
	for rows.Next() {
		var v DesignVersion
		if e = rows.Scan(&v.Revision, &v.Created, &v.Actor); e != nil {
			return nil, e
		}
		out = append(out, v)
	}
	return out, rows.Err()
}
func (s *Service) RestoreDesign(ctx context.Context, kind string, year int, in DesignRestore) (Saved, error) {
	actor, e := permission(ctx, "template")
	if e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "rollback"); e != nil {
		return Saved{}, e
	}
	if !in.Confirm {
		return Saved{}, fmt.Errorf("请确认恢复整张报表的配置和人工内容")
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return Saved{}, e
	}
	tx, rev, current, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	if rev != in.Expected {
		return Saved{}, ErrConflict
	}
	if e = s.ensureNoLeases(tx, key, nil); e != nil {
		return Saved{}, e
	}
	var raw string
	var data []byte
	e = tx.QueryRow(`SELECT h.data,c.data FROM total_report_design_history h JOIN total_report_checkpoints c ON c.doc=h.doc AND c.revision=h.revision WHERE h.doc=? AND h.revision=?`, key, in.Revision).Scan(&raw, &data)
	if e == sql.ErrNoRows {
		return Saved{}, ErrMissing
	}
	if e != nil {
		return Saved{}, e
	}
	var previous Template
	if e = json.Unmarshal([]byte(raw), &previous); e != nil {
		return Saved{}, e
	}
	snapshot, e := decodeCheckpoint(data)
	if e != nil {
		return Saved{}, e
	}
	if e = s.designCheckpoint(tx, key, actor, rev, current); e != nil {
		return Saved{}, e
	}
	values := map[string]Cell{}
	for _, c := range snapshot {
		values[c.Address] = c
	}
	// Restoring a smaller layout must remove cells and formats outside its bounds.
	for _, table := range []string{"total_report_cells", "total_report_formats"} {
		if _, e = tx.Exec("DELETE FROM "+table+" WHERE doc=?", key); e != nil {
			return Saved{}, e
		}
	}
	changes := []Cell{}
	rev++
	for _, cell := range grid(previous, year) {
		a := address(cell.R, cell.C)
		v := values[a]
		v.Address = a
		v.Revision = rev
		v.Actor = "configuration"
		if historyOwned(previous, cell.R, cell.C) {
			v.Value = ""
		}
		if e = writeCell(tx, key, v); e != nil {
			return Saved{}, e
		}
		changes = append(changes, v)
	}
	if _, e = tx.Exec(`DELETE FROM total_report_readings WHERE doc=?`, key); e != nil {
		return Saved{}, e
	}
	if _, e = tx.Exec(`UPDATE total_report_docs SET revision=?,template=? WHERE doc=?`, rev, raw, key); e != nil {
		return Saved{}, e
	}
	// Equal dimensions do not imply equal cell meaning (labels and bindings can
	// change too). Any full design restore establishes a new content boundary.
	if customKind.MatchString(kind) {
		if e = markPageLayout(tx, key, rev); e != nil {
			return Saved{}, e
		}
	}
	if _, e = permission(ctx, "template"); e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "rollback"); e != nil {
		return Saved{}, e
	}
	return Saved{rev, changes}, tx.Commit()
}

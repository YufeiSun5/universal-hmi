package totalreports

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

// Page state is locked before annual documents on every write, so deletion
// cannot race with a save, a lease acquisition, or first access to a new year.
func lockPage(tx *persistence.Tx, kind string, archived bool) (int64, bool, error) {
	if !customKind.MatchString(kind) {
		return 0, false, nil
	}
	if _, e := tx.Exec(`INSERT INTO total_report_page_state(kind,deleted,revision,actor,changed) VALUES(?,0,0,'',0) ON CONFLICT(kind) DO NOTHING`, kind); e != nil {
		return 0, false, e
	}
	if _, e := tx.Exec(`UPDATE total_report_page_state SET revision=revision WHERE kind=?`, kind); e != nil {
		return 0, false, e
	}
	var rev int64
	var deleted int
	e := tx.QueryRow(`SELECT revision,deleted FROM total_report_page_state WHERE kind=?`, kind).Scan(&rev, &deleted)
	if e == nil && deleted != 0 && !archived {
		e = ErrMissing
	}
	return rev, deleted != 0, e
}

func (s *Service) pageAvailable(ctx context.Context, kind string) error {
	if !customKind.MatchString(kind) {
		return nil
	}
	var deleted int
	e := s.db.QueryRowContext(ctx, `SELECT deleted FROM total_report_page_state WHERE kind=?`, kind).Scan(&deleted)
	if e == sql.ErrNoRows {
		return nil
	}
	if e == nil && deleted != 0 {
		return ErrMissing
	}
	return e
}

type PageYear struct {
	Year     int   `json:"year"`
	Revision int64 `json:"revision"`
}
type PageInfo struct {
	Kind    string     `json:"kind"`
	Name    string     `json:"name"`
	Deleted bool       `json:"deleted"`
	Years   []PageYear `json:"years"`
	Token   string     `json:"token"`
}
type PageAction struct {
	Token   string `json:"token"`
	Confirm bool   `json:"confirm"`
}

func pageInfo(tx *persistence.Tx, kind string, rev int64, deleted bool) (PageInfo, error) {
	out := PageInfo{Kind: kind, Deleted: deleted, Years: []PageYear{}}
	var raw string
	e := tx.QueryRow(`SELECT data FROM total_report_templates WHERE kind=?`, kind).Scan(&raw)
	if e == sql.ErrNoRows {
		return out, ErrMissing
	}
	if e != nil {
		return out, e
	}
	var t Template
	if e = json.Unmarshal([]byte(raw), &t); e != nil {
		return out, e
	}
	out.Name = t.Name
	rows, e := tx.Query(`SELECT doc,revision FROM total_report_docs WHERE substr(doc,1,?)=? ORDER BY doc`, len(kind)+1, kind+"/")
	if e != nil {
		return out, e
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		var y PageYear
		if e = rows.Scan(&key, &y.Revision); e != nil {
			return out, e
		}
		if _, e = fmt.Sscanf(strings.TrimPrefix(key, kind+"/"), "%d", &y.Year); e != nil {
			return out, e
		}
		out.Years = append(out.Years, y)
	}
	if e = rows.Err(); e != nil {
		return out, e
	}
	out.Token = digest(struct {
		Info     PageInfo
		Revision int64
		Template string
	}{out, rev, raw})
	return out, nil
}

func (s *Service) PageInfo(ctx context.Context, kind string) (PageInfo, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return PageInfo{}, e
	}
	if !customKind.MatchString(kind) {
		return PageInfo{}, fmt.Errorf("仅自定义报表页面支持此操作")
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return PageInfo{}, e
	}
	defer tx.Rollback()
	rev, deleted, e := lockPage(tx, kind, true)
	if e != nil {
		return PageInfo{}, e
	}
	out, e := pageInfo(tx, kind, rev, deleted)
	if e != nil {
		return out, e
	}
	return out, tx.Commit()
}

func (s *Service) ArchivedPages(ctx context.Context) ([]PageInfo, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, `SELECT t.kind,t.data FROM total_report_templates t JOIN total_report_page_state p ON p.kind=t.kind WHERE p.deleted=1 ORDER BY t.kind`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []PageInfo{}
	for rows.Next() {
		var kind, raw string
		var t Template
		if e = rows.Scan(&kind, &raw); e != nil {
			return nil, e
		}
		if e = json.Unmarshal([]byte(raw), &t); e != nil {
			return nil, e
		}
		out = append(out, PageInfo{Kind: kind, Name: t.Name, Deleted: true})
	}
	return out, rows.Err()
}

// Deletion is reversible: retained years and originals are inaccessible until
// an authorized developer explicitly restores the same stable page identity.
func (s *Service) SetPageDeleted(ctx context.Context, kind string, in PageAction, deleted bool) (PageInfo, error) {
	actor, e := permission(ctx, "template")
	if e != nil {
		return PageInfo{}, e
	}
	if !deleted {
		if _, e = permission(ctx, "rollback"); e != nil {
			return PageInfo{}, e
		}
	}
	if !customKind.MatchString(kind) || !in.Confirm {
		return PageInfo{}, fmt.Errorf("请先核对页面及全部年份，再确认操作")
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return PageInfo{}, e
	}
	defer tx.Rollback()
	rev, wasDeleted, e := lockPage(tx, kind, true)
	if e != nil {
		return PageInfo{}, e
	}
	info, e := pageInfo(tx, kind, rev, wasDeleted)
	if e != nil {
		return info, e
	}
	if in.Token != info.Token {
		return info, ErrConflict
	}
	for _, y := range info.Years {
		key, _ := documentKey(kind, y.Year)
		if e = s.ensureNoLeases(tx, key, nil); e != nil {
			return info, e
		}
	}
	value := 0
	if deleted {
		value = 1
	}
	if _, e = tx.Exec(`UPDATE total_report_page_state SET deleted=?,revision=revision+1,actor=?,changed=? WHERE kind=?`, value, actor, s.now().Unix(), kind); e != nil {
		return info, e
	}
	if _, e = permission(ctx, "template"); e != nil {
		return info, e
	}
	if !deleted {
		if _, e = permission(ctx, "rollback"); e != nil {
			return info, e
		}
	}
	info.Deleted = deleted
	info.Token = ""
	return info, tx.Commit()
}

type PageReplace struct {
	Workbook WorkbookUpload `json:"workbook"`
	Expected int64          `json:"expected"`
	Token    string         `json:"token"`
	Confirm  bool           `json:"confirm"`
}
type PageReplacementPreview struct {
	Year        int    `json:"year"`
	Revision    int64  `json:"revision"`
	OldRows     int    `json:"old_rows"`
	OldColumns  int    `json:"old_columns"`
	Rows        int    `json:"rows"`
	Columns     int    `json:"columns"`
	EditedCells int    `json:"edited_cells"`
	Bindings    int    `json:"bindings"`
	Token       string `json:"token"`
}

// Replacement changes this year's frozen document only. Other years and the
// catalog seed remain intact. The whole previous design and cells are restorable.
func (s *Service) ReplacePage(ctx context.Context, kind string, year int, in PageReplace, apply bool) (PageReplacementPreview, error) {
	out := PageReplacementPreview{Year: year}
	actor, e := permission(ctx, "template")
	if e != nil {
		return out, e
	}
	if !customKind.MatchString(kind) {
		return out, fmt.Errorf("仅自定义报表页面支持整页替换")
	}
	key, e := documentKey(kind, year)
	if e != nil {
		return out, e
	}
	// Parse before opening a write transaction; a preview creates no catalog entry.
	t, data, e := parsePage(PageImport{ID: strings.TrimPrefix(kind, "page_"), Name: "替换预览", Sheet: in.Workbook.Sheet, Data: in.Workbook.Data}, nil, nil)
	if e != nil {
		return out, e
	}
	tx, rev, old, e := s.lock(ctx, key)
	if e != nil {
		return out, e
	}
	defer tx.Rollback()
	if rev != in.Expected {
		return out, ErrConflict
	}
	t.Name = old.Name
	cells, e := readCells(tx, key, -1)
	if e != nil {
		return out, e
	}
	out.Revision = rev
	out.OldRows = old.Rows
	out.OldColumns = old.Columns
	out.Rows = t.Rows
	out.Columns = t.Columns
	out.Bindings = len(old.History)
	for _, c := range cells {
		if c.Actor != "template" && c.Actor != "source" && c.Actor != "configuration" {
			out.EditedCells++
		}
	}
	out.Token = digest(struct {
		Key      string
		Revision int64
		Old      Template
		New      Template
	}{key, rev, old, t})
	if !apply {
		return out, nil
	}
	if !in.Confirm || in.Token != out.Token {
		return out, fmt.Errorf("%w：请重新预览并确认替换内容", ErrConflict)
	}
	if e = s.ensureNoLeases(tx, key, nil); e != nil {
		return out, e
	}
	if e = s.designCheckpoint(tx, key, actor, rev, old); e != nil {
		return out, e
	}
	if e = storeOriginal(tx, t.Original, data); e != nil {
		return out, e
	}
	for _, table := range []string{"total_report_cells", "total_report_formats", "total_report_readings"} {
		if _, e = tx.Exec("DELETE FROM "+table+" WHERE doc=?", key); e != nil {
			return out, e
		}
	}
	// Stamp even empty cells so stale clients cannot save old zero-revision edits.
	for _, c := range grid(t, year) {
		v := ""
		if c.V != nil {
			v = fmt.Sprint(c.V)
		}
		if c.F != "" {
			v = c.F
		}
		if e = writeCell(tx, key, Cell{Address: address(c.R, c.C), Value: v, Revision: rev + 1, Actor: "configuration"}); e != nil {
			return out, e
		}
	}
	raw, e := json.Marshal(t)
	if e != nil {
		return out, e
	}
	if _, e = tx.Exec(`UPDATE total_report_docs SET revision=?,template=? WHERE doc=?`, rev+1, string(raw), key); e != nil {
		return out, e
	}
	if e = markPageLayout(tx, key, rev+1); e != nil {
		return out, e
	}
	if _, e = permission(ctx, "template"); e != nil {
		return out, e
	}
	return out, tx.Commit()
}

func markPageLayout(tx *persistence.Tx, key string, rev int64) error {
	_, e := tx.Exec(`INSERT INTO total_report_settings(key,revision,value) VALUES(?,?,'') ON CONFLICT(key) DO UPDATE SET revision=excluded.revision`, "page_layout/"+key, rev)
	return e
}

package totalreports

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/xuri/excelize/v2"
)

func liveCurrent(b HistoryBinding) bool {
	if b.Mode != "nearest" {
		return false
	}
	if b.LiveCurrent != nil {
		return *b.LiveCurrent
	}
	return strings.HasPrefix(b.ID, "legacy_")
}

func historyQueryTarget(b HistoryBinding, t externaldata.ReportTarget, now time.Time) (externaldata.ReportTarget, bool, bool) {
	begin, _ := time.Parse(time.RFC3339, t.From)
	end, _ := time.Parse(time.RFC3339, t.To)
	if b.Mode == "nearest" {
		end = begin
	}
	if !end.After(now) {
		return t, true, false
	}
	start := begin.Add(-24 * time.Hour)
	if liveCurrent(b) && !now.Before(start) {
		return externaldata.ReportTarget{From: start.Format(time.RFC3339), To: now.Format(time.RFC3339)}, true, true
	}
	return t, false, false
}

// HistoryState reads local provenance only; it never starts an external query.
func (s *Service) HistoryState(ctx context.Context, kind string, year int) ([]HistoryPreview, error) {
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return nil, e
	}
	key, _ := documentKey(kind, year)
	rows, e := s.db.QueryContext(ctx, `SELECT address,data FROM total_report_readings WHERE doc=?`, key)
	if e != nil {
		return nil, e
	}
	saved := map[string]HistoryPreview{}
	for rows.Next() {
		var a, raw string
		if e = rows.Scan(&a, &raw); e != nil {
			rows.Close()
			return nil, e
		}
		var v HistoryPreview
		if e = json.Unmarshal([]byte(raw), &v); e != nil {
			rows.Close()
			return nil, e
		}
		saved[a] = v
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return nil, e
	}
	out := []HistoryPreview{}
	now := s.now()
	for _, b := range d.Template.History {
		addresses, targets, e := bindingTargets(d, b)
		if e != nil {
			return nil, e
		}
		for i, t := range targets {
			_, eligible, provisional := historyQueryTarget(b, t, now)
			v := saved[addresses[i]]
			if v.From != t.From || v.To != t.To {
				v = HistoryPreview{Address: addresses[i], From: t.From, To: t.To}
			}
			v.Eligible = eligible
			// A cached provisional value stays explicitly provisional after midnight
			// until a successful boundary query replaces it.
			v.Provisional = v.Provisional || provisional
			out = append(out, v)
		}
	}
	if _, e = permission(ctx, "read"); e != nil {
		return nil, e
	}
	return out, nil
}

func (s *Service) normalizeHeatClock(tx *persistence.Tx, key string, t Template, rev int64, cells []Cell) (int64, error) {
	indices := []int{}
	for i, c := range cells {
		col, row, e := excelize.CellNameToCoordinates(c.Address)
		if e == nil && col == 3 && row > t.HeaderRows && c.Value == "24:00" {
			indices = append(indices, i)
		}
	}
	if len(indices) == 0 {
		return rev, nil
	}
	if _, e := s.checkpoint(tx, key, "system", "热量时间显示改为00:00前", rev, true); e != nil {
		return rev, e
	}
	rev++
	for _, i := range indices {
		cells[i].Value = "00:00"
		cells[i].Revision = rev
		cells[i].Actor = "source"
		if e := writeCell(tx, key, cells[i]); e != nil {
			return rev, e
		}
	}
	_, e := tx.Exec(`UPDATE total_report_docs SET revision=? WHERE doc=?`, rev, key)
	return rev, e
}

func (s *Service) annotateCurrentHistory(ctx context.Context, f *excelize.File, sheet, kind string, year int, region *cellRect) error {
	items, e := s.HistoryState(ctx, kind, year)
	if e != nil {
		return e
	}
	comments, e := f.GetComments(sheet)
	if e != nil {
		return e
	}
	existing := map[string]excelize.Comment{}
	for _, c := range comments {
		kept := []excelize.RichTextRun{}
		removed := false
		for _, part := range c.Paragraph {
			if strings.HasPrefix(part.Text, "\n【报表临时值】") {
				removed = true
			} else {
				kept = append(kept, part)
			}
		}
		if removed {
			if e = f.DeleteComment(sheet, c.Cell); e != nil {
				return e
			}
			c.Paragraph = kept
			if len(kept) > 0 || c.Text != "" {
				if e = f.AddComment(sheet, c); e != nil {
					return e
				}
			}
		}
		existing[c.Cell] = c
	}
	for _, v := range items {
		if !v.Provisional || v.Value == nil {
			continue
		}
		c, r, e := excelize.CellNameToCoordinates(v.Address)
		if e != nil {
			return e
		}
		if region != nil && !region.contains(r-1, c-1) {
			continue
		}
		stamp := "未知"
		if v.SampleTime != nil {
			stamp = *v.SampleTime
		}
		comment := existing[v.Address]
		comment.Cell = v.Address
		if comment.Author == "" {
			comment.Author = "报表数据"
		}
		comment.Paragraph = append(comment.Paragraph, excelize.RichTextRun{Text: fmt.Sprintf("\n【报表临时值】当期最新采样，截至%s，尚未结算；当日及月/季合计含暂计值。目标期末：%s。", stamp, v.From)})
		if e = f.AddComment(sheet, comment); e != nil {
			return e
		}
	}
	return nil
}

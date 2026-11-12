package totalreports

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/xuri/excelize/v2"
	"math"
	"regexp"
	"strings"
)

var formatColor = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

func validFormat(f CellFormat) bool {
	for k, v := range f {
		switch k {
		case "bg", "fc":
			s, ok := v.(string)
			if !ok || !formatColor.MatchString(s) {
				return false
			}
		case "ff", "nf":
			s, ok := v.(string)
			if !ok || len(s) > 100 || strings.ContainsAny(s, "\x00\r\n") {
				return false
			}
		case "fs", "bl", "it", "un", "cl", "ht", "vt", "tb":
			n, ok := v.(float64)
			if !ok || math.IsNaN(n) || math.IsInf(n, 0) {
				return false
			}
			if k == "fs" {
				if n < 6 || n > 48 {
					return false
				}
			} else if n < 0 || n > 2 || n != math.Trunc(n) {
				return false
			}
		default:
			return false
		}
	}
	return true
}
func sameFormat(a, b CellFormat) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}
func readFormat(tx *persistence.Tx, key, address string) (CellFormat, error) {
	var raw string
	e := tx.QueryRow(`SELECT data FROM total_report_formats WHERE doc=? AND address=?`, key, address).Scan(&raw)
	if e == sql.ErrNoRows {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	var f CellFormat
	e = json.Unmarshal([]byte(raw), &f)
	return f, e
}
func writeCell(tx *persistence.Tx, key string, c Cell) error {
	if _, e := tx.Exec(`INSERT INTO total_report_cells(doc,address,value,revision,actor) VALUES(?,?,?,?,?) ON CONFLICT(doc,address) DO UPDATE SET value=excluded.value,revision=excluded.revision,actor=excluded.actor`, key, c.Address, c.Value, c.Revision, c.Actor); e != nil {
		return e
	}
	if len(c.Format) == 0 {
		_, e := tx.Exec(`DELETE FROM total_report_formats WHERE doc=? AND address=?`, key, c.Address)
		return e
	}
	b, e := json.Marshal(c.Format)
	if e != nil {
		return e
	}
	_, e = tx.Exec(`INSERT INTO total_report_formats(doc,address,data) VALUES(?,?,?) ON CONFLICT(doc,address) DO UPDATE SET data=excluded.data`, key, c.Address, string(b))
	return e
}
func applyFortuneFormat(cell map[string]any, f CellFormat) {
	for k, v := range f {
		if k == "nf" {
			ct, ok := cell["ct"].(map[string]any)
			if !ok {
				ct = map[string]any{"t": "g"}
			}
			ct["fa"] = v
			cell["ct"] = ct
			delete(cell, "m")
		} else {
			cell[k] = v
		}
	}
}
func exportStyle(t Template, c TemplateCell, f CellFormat) *excelize.Style {
	style := &excelize.Style{Font: &excelize.Font{Size: 11}, Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center", WrapText: true}}
	if source, ok := t.cellStyle(c.R, c.C); ok {
		style.Font.Color = strings.TrimPrefix(source.FG, "#")
		style.Font.Bold = source.Bold
		if source.Size > 0 {
			style.Font.Size = source.Size
		}
		style.Fill = excelize.Fill{Type: "pattern", Color: []string{strings.TrimPrefix(source.BG, "#")}, Pattern: 1}
	}
	for k, v := range f {
		switch k {
		case "bg":
			style.Fill = excelize.Fill{Type: "pattern", Color: []string{strings.TrimPrefix(fmt.Sprint(v), "#")}, Pattern: 1}
		case "fc":
			style.Font.Color = strings.TrimPrefix(fmt.Sprint(v), "#")
		case "ff":
			style.Font.Family = fmt.Sprint(v)
		case "nf":
			s := fmt.Sprint(v)
			style.CustomNumFmt = &s
		default:
			n, _ := v.(float64)
			switch k {
			case "fs":
				style.Font.Size = n
			case "bl":
				style.Font.Bold = n != 0
			case "it":
				style.Font.Italic = n != 0
			case "cl":
				style.Font.Strike = n != 0
			case "un":
				if n != 0 {
					style.Font.Underline = "single"
				}
			case "ht":
				style.Alignment.Horizontal = []string{"center", "left", "right"}[int(n)]
			case "vt":
				style.Alignment.Vertical = []string{"center", "top", "bottom"}[int(n)]
			case "tb":
				style.Alignment.WrapText = n == 2
			}
		}
	}
	return style
}

package totalreports

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/xuri/excelize/v2"
)

// Seasonal templates share readable geometry between the online grid and XLSX.
// This is a presentation adjustment; frozen cells, formulas and originals are
// never rewritten. User-uploaded standalone pages retain their native layout.
func (d Document) seasonalLayout() (map[string]float64, map[string]float64) {
	widths := map[string]float64{}
	for k, v := range d.Template.Widths {
		widths[k] = v
	}
	heights := map[string]float64{}
	if !d.seasonal() {
		return widths, heights
	}
	for c := 0; c < d.Template.Columns; c++ {
		minimum := 110.0
		// Old templates sometimes leave month/season captions unmerged in A.
		// Keep them readable without merging away neighbouring legacy text.
		if c == 1 {
			minimum = 48
		} else if c == 2 {
			minimum = 64
		}
		key := strconv.Itoa(c)
		widths[key] = math.Max(widths[key], minimum)
	}
	for _, c := range d.resolved() {
		text, ok := c.V.(string)
		if !ok || c.F != "" || c.R >= d.Template.HeaderRows || text == "" {
			continue
		}
		span, rows := 1, 1
		covered := false
		for _, m := range d.Template.Merges {
			if c.R >= m.R && c.R < m.R+m.RS && c.C >= m.C && c.C < m.C+m.CS {
				covered = c.R != m.R || c.C != m.C
				span, rows = m.CS, m.RS
				break
			}
		}
		if covered {
			continue
		}
		width := -16.0 // padding on both sides of the cell
		for col := c.C; col < c.C+span; col++ {
			width += widths[strconv.Itoa(col)]
		}
		size := 11.0
		if style, ok := d.Template.cellStyle(c.R, c.C); ok && style.Size > 0 {
			size = style.Size
		}
		if n, ok := d.Template.Formats[address(c.R, c.C)]["fs"].(float64); ok {
			size = n
		}
		for _, saved := range d.Cells {
			if saved.Address == address(c.R, c.C) {
				if n, ok := saved.Format["fs"].(float64); ok {
					size = n
				}
				break
			}
		}
		lines := 0.0
		for _, line := range strings.Split(text, "\n") {
			pixels := 0.0
			for _, r := range line {
				factor := 1.05
				if r < 128 {
					factor = .65
				}
				pixels += size * 4 / 3 * factor
			}
			lines += math.Max(1, math.Ceil(pixels/math.Max(16, width)))
		}
		height := math.Max(28, math.Ceil((lines*size*4/3*1.35+12)/float64(rows)))
		for r := c.R; r < c.R+rows; r++ {
			key := strconv.Itoa(r)
			heights[key] = math.Max(heights[key], height)
		}
	}
	return widths, heights
}

func (d Document) seasonal() bool {
	return d.Template.Rows == 0 && (d.Kind == "heat" || d.Kind == "electricity" || d.Kind == "water")
}

func (d Document) wrapHeader(c TemplateCell) bool {
	_, text := c.V.(string)
	return d.seasonal() && c.R < d.Template.HeaderRows && c.F == "" && text
}

func (d Document) applySeasonalExcelLayout(f *excelize.File, sheet string) error {
	if !d.seasonal() {
		return nil
	}
	widths, heights := d.seasonalLayout()
	for key, pixels := range widths {
		c, _ := strconv.Atoi(key)
		col, err := excelize.ColumnNumberToName(c + 1)
		if err != nil {
			return err
		}
		if err = f.SetColWidth(sheet, col, col, (pixels-5)/7); err != nil {
			return err
		}
	}
	for key, pixels := range heights {
		r, err := strconv.Atoi(key)
		if err != nil {
			return fmt.Errorf("invalid header row: %w", err)
		}
		if err = f.SetRowHeight(sheet, r+1, pixels*.75); err != nil {
			return err
		}
	}
	return nil
}

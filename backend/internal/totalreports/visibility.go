package totalreports

import (
	"context"
	"strconv"

	"github.com/xuri/excelize/v2"
)

// Sheet applies the immutable Excel original's visibility to the online grid.
// Hidden cells remain present for formulas and exports, including old documents
// whose frozen template predates support for visibility in the renderer.
func (s *Service) Sheet(ctx context.Context, d Document) (map[string]any, error) {
	if _, err := permission(ctx, "read"); err != nil {
		return nil, err
	}
	sheet := d.Sheet()
	if d.Template.Original == nil {
		return sheet, nil
	}
	var data []byte
	if err := s.db.QueryRowContext(ctx, `SELECT data FROM total_report_originals WHERE id=?`, d.Template.Original.ID).Scan(&data); err != nil {
		return nil, err
	}
	f, err := openOriginal(data)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	columns, rows := map[string]int{}, map[string]int{}
	name := d.Template.Original.Sheet
	for c := 0; c < d.Template.Columns; c++ {
		col, _ := excelize.ColumnNumberToName(c + 1)
		visible, err := f.GetColVisible(name, col)
		if err != nil {
			return nil, err
		}
		if !visible {
			columns[strconv.Itoa(c)] = 0
		}
	}
	// Fixed pages retain original row coordinates. Seasonal rows are generated
	// for a different calendar, so old daily row numbers cannot be reused.
	for r := 0; r < d.Template.Rows; r++ {
		visible, err := f.GetRowVisible(name, r+1)
		if err != nil {
			return nil, err
		}
		if !visible {
			rows[strconv.Itoa(r)] = 0
		}
	}
	config := sheet["config"].(map[string]any)
	config["colhidden"], config["rowhidden"] = columns, rows
	return sheet, nil
}

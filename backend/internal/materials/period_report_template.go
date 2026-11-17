package materials

import (
	_ "embed"
	"encoding/json"
	"fmt"

	"github.com/xuri/excelize/v2"
)

// Only formatting and headings were extracted from the user's newer white
// report sheet. No historical rows, formulas, signatures or workbook links are
// bundled with the application.
//
//go:embed templates/period-report.json
var periodReportTemplateJSON []byte

type periodReportTemplateColumn struct {
	Label       string  `json:"label"`
	Width       float64 `json:"width"`
	HeaderStyle int     `json:"header_style"`
	BodyStyle   int     `json:"body_style"`
}

type periodReportTemplate struct {
	Title      string                       `json:"title"`
	TitleStyle int                          `json:"title_style"`
	GroupStyle int                          `json:"group_style"`
	NoteStyle  int                          `json:"note_style"`
	RowHeights []float64                    `json:"row_heights"`
	Columns    []periodReportTemplateColumn `json:"columns"`
	Styles     map[int]excelize.Style       `json:"styles"`
}

func readPeriodReportTemplate() (periodReportTemplate, error) {
	var t periodReportTemplate
	err := json.Unmarshal(periodReportTemplateJSON, &t)
	return t, err
}

func (t periodReportTemplate) column(kind, label string) (periodReportTemplateColumn, error) {
	columns := t.Columns[:13]
	if kind == "outbound" {
		columns = t.Columns[13:]
	}
	for _, c := range columns {
		if c.Label == label {
			return c, nil
		}
	}
	// Newly requested fields have no source column. Reuse the matching text or
	// amount formatting, with enough width for their independent headings.
	widths := map[string]float64{"料号": 16, "合同号": 20, "质量证明书份数": 12, "运杂费（整单，勿累加）": 20, "用途": 25.375, "备注": 25.375}
	width, ok := widths[label]
	if !ok {
		return periodReportTemplateColumn{}, fmt.Errorf("missing report column style: %s", label)
	}
	source := "名称"
	if label == "运杂费（整单，勿累加）" {
		source = "金额"
	}
	c, err := t.column(kind, source)
	c.Label, c.Width = label, width
	return c, err
}

// Package totalreports owns annual spreadsheet inputs and collaborative saving.
// It never writes to acquisition or the external source database.
package totalreports

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

var ErrConflict = errors.New("报表已被其他人修改，请核对冲突后重试")
var ErrLocked = errors.New("单元格正在编辑，请稍后重试")
var ErrMissing = errors.New("报表或检查点不存在")

// Template contains no historical readings. Row formulas are translated once
// when an annual document is created, and then frozen with that document.
type Template struct {
	History      []HistoryBinding      `json:"history,omitempty"`
	Generic      bool                  `json:"generic,omitempty"`
	Original     *OriginalWorkbook     `json:"original,omitempty"`
	Workbook     *WorkbookUpload       `json:"workbook,omitempty"`
	Rows         int                   `json:"rows,omitempty"`
	Formats      map[string]CellFormat `json:"formats,omitempty"`
	Kind         string                `json:"kind"`
	Name         string                `json:"name"`
	Columns      int                   `json:"columns"`
	HeaderRows   int                   `json:"header_rows"`
	Cells        []TemplateCell        `json:"cells"`
	Daily        []TemplateCell        `json:"daily"`
	InputColumns []int                 `json:"input_columns"`
	Widths       map[string]float64    `json:"widths"`
	Merges       []Merge               `json:"merges"`
	Bindings     []HeatBinding         `json:"bindings,omitempty"`
	Styles       map[string]CellStyle  `json:"styles,omitempty"`
}
type CellStyle struct {
	BG   string  `json:"bg"`
	FG   string  `json:"fg"`
	Bold bool    `json:"bold"`
	Size float64 `json:"size,omitempty"`
}
type Merge struct {
	R  int `json:"r"`
	C  int `json:"c"`
	RS int `json:"rs"`
	CS int `json:"cs"`
}
type TemplateCell struct {
	R        int    `json:"r"`
	C        int    `json:"c"`
	V        any    `json:"v,omitempty"`
	F        string `json:"f,omitempty"`
	Editable bool   `json:"editable,omitempty"`
}
type Cell struct {
	Address  string     `json:"address"`
	Value    string     `json:"value"`
	Revision int64      `json:"revision"`
	Actor    string     `json:"actor"`
	Format   CellFormat `json:"format,omitempty"`
}
type Change struct {
	Address  string     `json:"address"`
	Value    string     `json:"value"`
	Expected int64      `json:"expected"`
	Format   CellFormat `json:"format,omitempty"`
}
type CellFormat map[string]any
type Patch struct {
	ID      string   `json:"id"`
	Changes []Change `json:"changes"`
	Client  string   `json:"client"`
}
type Saved struct {
	Revision int64  `json:"revision"`
	Cells    []Cell `json:"cells"`
}
type Document struct {
	Kind        string   `json:"kind"`
	Year        int      `json:"year"`
	Revision    int64    `json:"revision"`
	Template    Template `json:"template"`
	Cells       []Cell   `json:"cells"`
	CanEdit     bool     `json:"can_edit"`
	CanRollback bool     `json:"can_rollback"`
	CanExport   bool     `json:"can_export"`
}
type Checkpoint struct {
	ID       string `json:"id"`
	Revision int64  `json:"revision"`
	Created  int64  `json:"created"`
	Actor    string `json:"actor"`
	Reason   string `json:"reason"`
}
type Rollback struct {
	ID         string   `json:"id"`
	Checkpoint string   `json:"checkpoint"`
	Expected   int64    `json:"expected"`
	Addresses  []string `json:"addresses,omitempty"`
}

func permission(ctx context.Context, action string) (string, error) {
	a, ok := authorization.FromContext(ctx)
	if !ok {
		return "local-development", nil
	}
	if !a.Active() || !a.Grants.AllStations {
		return "", authorization.ErrDenied
	}
	// Named online capabilities remain available on the public request-local
	// read-only actor, just like the existing equipment maintenance capability.
	// Report export is explicitly available in runtime clients. Use the
	// server-owned original grant ceiling when transport strips generic exports;
	// this does not restore any other export or development capability.
	if action == "edit" && !a.Grants.TotalReportsEdit || action == "rollback" && !a.Grants.TotalReportsRollback || action == "export" && !a.GrantPolicy().Export || action == "template" && (a.ReadOnly || !a.Grants.Develop()) {
		return "", authorization.ErrDenied
	}
	return a.ID, nil
}
func documentKey(kind string, year int) (string, error) {
	if (kind != "heat" && kind != "electricity" && kind != "water" && !customKind.MatchString(kind)) || year < 2000 || year > 2100 {
		return "", fmt.Errorf("报表类型或年份无效")
	}
	return fmt.Sprintf("%s/%d", kind, year), nil
}

var customKind = regexp.MustCompile(`^page_[a-zA-Z0-9_-]{8,64}$`)

var operationID = regexp.MustCompile(`^[a-zA-Z0-9_-]{8,100}$`)
var cellAddress = regexp.MustCompile(`^([A-Z]{1,3})([1-9][0-9]{0,3})$`)

func numeric(v string) bool {
	if v == "" {
		return true
	}
	if len(v) > 40 || strings.TrimSpace(v) != v {
		return false
	}
	n, e := strconv.ParseFloat(v, 64)
	return e == nil && !math.IsNaN(n) && !math.IsInf(n, 0) && math.Abs(n) <= 1e15
}

package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type ReportColumn struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Visible  bool   `json:"visible"`
	Width    int    `json:"width,omitempty"`
	Align    string `json:"align,omitempty"`
	Decimals *int   `json:"decimals,omitempty"`
	Group    string `json:"group,omitempty"`
}
type ReportLayout struct {
	GroupLabels map[string]string `json:"group_labels,omitempty"`
	Columns     []ReportColumn    `json:"columns,omitempty"`
	HeaderColor string            `json:"header_color,omitempty"`
	StripeColor string            `json:"stripe_color,omitempty"`
	RowHeight   int               `json:"row_height,omitempty"`
	FontSize    int               `json:"font_size,omitempty"`
}
type ProcedureParameter struct {
	Name     string `json:"name"`
	Label    string `json:"label"`
	Type     string `json:"type"`
	Default  string `json:"default,omitempty"`
	Required bool   `json:"required"`
}
type ProcedureReport struct {
	Schema     string               `json:"schema"`
	Name       string               `json:"name"`
	Parameters []ProcedureParameter `json:"parameters"`
}

var sqlIdentifier = regexp.MustCompile(`^[\p{L}_][\p{L}\p{N}_]{0,127}$`)
var reportColor = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
var reportDecimal = regexp.MustCompile(`^-?[0-9]{1,28}(\.[0-9]{1,10})?$`)

func validateReportLayouts(layouts map[string]ReportLayout) error {
	if len(layouts) > 24 {
		return fmt.Errorf("最多保存24种报表布局")
	}
	for key, layout := range layouts {
		if len(layout.GroupLabels) > 128 {
			return fmt.Errorf("最多保存128个上层标题")
		}
		for id, label := range layout.GroupLabels {
			if strings.TrimSpace(id) == "" || len(id) > 2048 || strings.ContainsAny(id, "\x00\r\n") || !validName(label) {
				return fmt.Errorf("报表上层标题的标识或显示名称无效")
			}
		}
		if !validName(key) || len(layout.Columns) > 128 || (layout.RowHeight != 0 && (layout.RowHeight < 28 || layout.RowHeight > 64)) || (layout.FontSize != 0 && (layout.FontSize < 10 || layout.FontSize > 20)) {
			return fmt.Errorf("报表字号、行高或列数无效")
		}
		for _, color := range []string{layout.HeaderColor, layout.StripeColor} {
			if color != "" && !reportColor.MatchString(color) {
				return fmt.Errorf("报表颜色须为 #RRGGBB")
			}
		}
		seen, visible := map[string]bool{}, 0
		for _, col := range layout.Columns {
			if (strings.TrimSpace(col.Key) == "" || len(col.Key) > 1024 || strings.ContainsAny(col.Key, "\x00\r\n")) || !validName(col.Label) || seen[col.Key] || (col.Width != 0 && (col.Width < 55 || col.Width > 800)) || !slices.Contains([]string{"", "left", "center", "right"}, col.Align) || (col.Decimals != nil && (*col.Decimals < 0 || *col.Decimals > 6)) || len(col.Group) > 128 || strings.ContainsAny(col.Group, "\r\n\x00") {
				return fmt.Errorf("报表列字段、列名或样式无效")
			}
			seen[col.Key] = true
			if col.Visible {
				visible++
			}
		}
		if len(layout.Columns) > 0 && visible == 0 {
			return fmt.Errorf("报表至少保留一列")
		}
	}
	return nil
}

func validateProcedure(p *ProcedureReport, kind string) error {
	// An omitted definition on an existing screen is preserved on a name edit.
	if p == nil {
		return nil
	}
	if kind != "custom" || !sqlIdentifier.MatchString(p.Schema) || !sqlIdentifier.MatchString(p.Name) || len(p.Parameters) > 16 {
		return fmt.Errorf("请选择有效的自定义报表存储过程（最多16个参数）")
	}
	seen := map[string]bool{}
	for _, arg := range p.Parameters {
		key := strings.ToLower(arg.Name)
		if !sqlIdentifier.MatchString(arg.Name) || !validName(arg.Label) || seen[key] || !slices.Contains([]string{"text", "date", "datetime", "integer", "decimal", "boolean"}, arg.Type) || len(arg.Default) > 1024 {
			return fmt.Errorf("存储过程参数名称、类型或默认值无效")
		}
		seen[key] = true
		if arg.Default != "" {
			if _, err := procedureValue(arg, arg.Default); err != nil {
				return err
			}
		}
	}
	return nil
}

func procedureValue(arg ProcedureParameter, raw string) (any, error) {
	bad := func() (any, error) { return nil, fmt.Errorf("参数“%s”不符合%s类型", arg.Label, arg.Type) }
	if len(raw) > 1024 || strings.ContainsRune(raw, 0) {
		return bad()
	}
	switch arg.Type {
	case "text":
		return raw, nil
	case "date":
		if _, err := time.Parse("2006-01-02", raw); err != nil {
			return bad()
		}
		return raw, nil
	case "datetime":
		for _, format := range []string{time.RFC3339Nano, "2006-01-02T15:04:05", "2006-01-02T15:04", "2006-01-02 15:04:05"} {
			if _, err := time.Parse(format, raw); err == nil {
				return raw, nil
			}
		}
		return bad()
	case "integer":
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return bad()
		}
		return v, nil
	case "decimal":
		if !reportDecimal.MatchString(raw) {
			return bad()
		}
		return raw, nil
	case "boolean":
		if raw == "1" || raw == "true" {
			return true, nil
		}
		if raw == "0" || raw == "false" {
			return false, nil
		}
		return bad()
	}
	return bad()
}

func procedureQuery(p *ProcedureReport, values map[string]*string) (string, []any, error) {
	if p == nil {
		return "", nil, fmt.Errorf("请在开发端配置报表存储过程")
	}
	if err := validateProcedure(p, "custom"); err != nil {
		return "", nil, err
	}
	known := map[string]bool{}
	args := []any{}
	bindings := []string{}
	for i, arg := range p.Parameters {
		known[arg.Name] = true
		raw, provided := values[arg.Name]
		if !provided && arg.Default != "" {
			v := arg.Default
			raw = &v
			provided = true
		}
		if !provided {
			if arg.Required {
				return "", nil, fmt.Errorf("请填写参数“%s”", arg.Label)
			}
			continue // Omit optional parameters so SQL defaults remain effective.
		}
		var v any
		var err error
		if raw != nil {
			v, err = procedureValue(arg, *raw)
		} else if arg.Required {
			return "", nil, fmt.Errorf("请填写参数“%s”", arg.Label)
		}
		if err != nil {
			return "", nil, err
		}
		name := fmt.Sprintf("p%d", i)
		args = append(args, sql.Named(name, v))
		bindings = append(bindings, "@"+arg.Name+"=@"+name)
	}
	for key := range values {
		if !known[key] {
			return "", nil, fmt.Errorf("未知报表参数“%s”", key)
		}
	}
	return "EXEC [" + p.Schema + "].[" + p.Name + "] " + strings.Join(bindings, ","), args, nil
}

func (s *Service) queryProcedure(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	query, args, err := procedureQuery(view.Procedure, in.Parameters)
	if err != nil {
		return Result{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, release, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer release()
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return Result{}, interfaceFailure(ctx, view.Name, "执行存储过程", err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Result{}, interfaceFailure(ctx, view.Name, "读取列定义", err)
	}
	if len(cols) == 0 || len(cols) > 128 {
		return Result{}, fmt.Errorf("报表应返回1至128列")
	}
	seen := map[string]bool{}
	for _, col := range cols {
		if !validName(col) || seen[col] {
			return Result{}, fmt.Errorf("返回列名为空或重复，请在存储过程中设置唯一列名")
		}
		seen[col] = true
	}
	zone := source.UTCOffsetMinutes
	sign := "+"
	if zone < 0 {
		sign = "-"
		zone = -zone
	}
	data, err := scanInterfaceSetBudget(rows, nil, 10000, fmt.Sprintf("%s%02d:%02d", sign, zone/60, zone%60), 8*1024*1024)
	if err != nil {
		return Result{}, interfaceFailure(ctx, view.Name, "读取返回字段", err)
	}
	if rows.NextResultSet() {
		return Result{}, fmt.Errorf("报表返回多张结果表，请选择只返回一张结果表的查询过程")
	}
	if err = rows.Err(); err != nil {
		return Result{}, interfaceFailure(ctx, view.Name, "读取返回字段", err)
	}
	for _, col := range view.ReportLayouts["custom"].Columns {
		if !seen[col.Key] {
			return Result{}, fmt.Errorf("返回字段已变化，缺少“%s”，请重新核对列定义", col.Key)
		}
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	return Result{Points: []Point{}, Rows: []Row{}, ReportColumns: cols, ReportRows: data, Total: len(data), SourceRevision: source.Revision, ScreenRevision: view.Revision}, nil
}

// Metadata is only exposed through the engineering source authorization path.
func (s *Service) Procedures(ctx context.Context, id string) ([]map[string]string, error) {
	source, _, err := s.source(ctx, id, false)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	db, release, err := s.database(ctx, source)
	if err != nil {
		return nil, err
	}
	defer release()
	rows, err := db.QueryContext(ctx, `SELECT TOP (2048) SCHEMA_NAME(p.schema_id),p.name,COALESCE(a.name,''),COALESCE(TYPE_NAME(a.system_type_id),''),COALESCE(a.is_output,0) FROM sys.procedures p LEFT JOIN sys.parameters a ON a.object_id=p.object_id AND a.parameter_id>0 WHERE p.is_ms_shipped=0 ORDER BY SCHEMA_NAME(p.schema_id),p.name,a.parameter_id`)
	if err != nil {
		return nil, interfaceFailure(ctx, "存储过程目录", "读取", err)
	}
	defer rows.Close()
	out := []map[string]string{}
	for rows.Next() {
		var schema, name, param, kind string
		var output bool
		if err = rows.Scan(&schema, &name, &param, &kind, &output); err != nil {
			return nil, err
		}
		out = append(out, map[string]string{"schema": schema, "name": name, "parameter": strings.TrimPrefix(param, "@"), "sql_type": kind, "output": strconv.FormatBool(output)})
	}
	return out, rows.Err()
}

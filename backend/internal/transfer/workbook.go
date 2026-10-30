package transfer

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"github.com/xuri/excelize/v2"
	"strconv"
	"strings"
)

var heads = [][]string{
	{"key", "name", "station", "template_id", "schema_version", "width", "height", "payload"},
	{"key", "name", "station", "data_type", "unit", "source_type", "source_alias", "topic", "source_path", "scale_factor", "offset", "rw_mode", "writable", "write_source_alias", "write_topic", "write_path", "min", "max", "expression", "inputs", "stale_ms"},
	{"screen_key", "node_id", "property", "variable_key", "operation", "rule_match", "condition_slot", "condition_operator", "condition_value", "condition_variable_key"},
}

func scalar(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}
func humanRows(b Bundle, idx int) [][]string {
	out := [][]string{heads[idx]}
	g := [][]json.RawMessage{b.Screens, b.Variables, b.Bindings}[idx]
	for _, raw := range g {
		var obj map[string]any
		_ = json.Unmarshal(raw, &obj)
		switch idx {
		case 0:
			d, _ := obj["document"].(map[string]any)
			out = append(out, []string{scalar(obj["key"]), scalar(d["name"]), scalar(d["station"]), scalar(d["template_id"]), scalar(d["schema_version"]), scalar(d["width"]), scalar(d["height"]), string(raw)})
		case 1:
			d, _ := obj["definition"].(map[string]any)
			r := []string{scalar(obj["key"])}
			for _, h := range heads[1][1:] {
				key := h
				if h == "source_alias" {
					key = "source_id"
				}
				if h == "write_source_alias" {
					key = "write_source_id"
				}
				r = append(r, scalar(d[key]))
			}
			out = append(out, r)
		case 2:
			base := []string{scalar(obj["screen_key"]), scalar(obj["node_id"]), scalar(obj["property"]), scalar(obj["variable_key"]), scalar(obj["operation"])}
			rule, _ := obj["rule"].(map[string]any)
			conds, _ := rule["conditions"].([]any)
			if len(conds) == 0 {
				out = append(out, append(base, "", "", "", "", ""))
			} else {
				for _, c := range conds {
					m, _ := c.(map[string]any)
					r := append([]string{}, base...)
					r = append(r, scalar(rule["match"]), scalar(m["slot"]), scalar(m["operator"]), scalar(m["value"]), scalar(m["point_id"]))
					out = append(out, r)
				}
			}
		}
	}
	return out
}
func parseHuman(rs [][]string, idx int) ([]json.RawMessage, error) {
	out := []json.RawMessage{}
	if len(rs) == 0 {
		return nil, fmt.Errorf("missing header")
	}
	cols := map[string]int{}
	for i, h := range rs[0] {
		if _, ok := cols[h]; ok {
			return nil, fmt.Errorf("duplicate column %s", h)
		}
		cols[h] = i
	}
	for _, h := range heads[idx] {
		if _, ok := cols[h]; !ok {
			return nil, fmt.Errorf("missing column %s", h)
		}
	}
	get := func(r []string, k string) string {
		i := cols[k]
		if i < len(r) {
			return r[i]
		}
		return ""
	}
	bindings := map[string]map[string]any{}
	order := []string{}
	for _, r := range rs[1:] {
		empty := true
		for _, v := range r {
			if v != "" {
				empty = false
			}
		}
		if empty {
			continue
		}
		var obj map[string]any
		switch idx {
		case 0:
			if e := json.Unmarshal([]byte(get(r, "payload")), &obj); e != nil {
				return nil, fmt.Errorf("screen payload required: %w", e)
			}
			obj["key"] = get(r, "key")
			d, ok := obj["document"].(map[string]any)
			if !ok {
				return nil, fmt.Errorf("document required")
			}
			for _, h := range heads[0][1:7] {
				v := get(r, h)
				switch h {
				case "width", "height", "schema_version":
					n, e := strconv.ParseFloat(v, 64)
					if e != nil {
						return nil, fmt.Errorf("invalid %s", h)
					}
					d[h] = n
				default:
					d[h] = v
				}
			}
		case 1:
			d := map[string]any{}
			obj = map[string]any{"key": get(r, "key"), "definition": d}
			for _, h := range heads[1][1:] {
				v := get(r, h)
				k := h
				if h == "source_alias" {
					k = "source_id"
				}
				if h == "write_source_alias" {
					k = "write_source_id"
				}
				switch h {
				case "scale_factor", "offset", "min", "max", "stale_ms":
					if v == "" {
						continue
					}
					n, e := strconv.ParseFloat(v, 64)
					if e != nil {
						return nil, fmt.Errorf("invalid %s", h)
					}
					d[k] = n
				case "writable":
					if v == "" {
						continue
					}
					n, e := strconv.ParseBool(v)
					if e != nil {
						return nil, e
					}
					d[k] = n
				case "inputs":
					if v == "" {
						continue
					}
					var a []string
					if e := json.Unmarshal([]byte(v), &a); e != nil {
						return nil, e
					}
					d[k] = a
				default:
					d[k] = v
				}
			}
		case 2:
			key := get(r, "screen_key") + "/" + get(r, "node_id") + "/" + get(r, "property")
			obj = bindings[key]
			if obj == nil {
				obj = map[string]any{}
				for _, h := range heads[2][:5] {
					obj[h] = get(r, h)
				}
				bindings[key] = obj
				order = append(order, key)
			} else {
				for _, h := range heads[2][:5] {
					if scalar(obj[h]) != get(r, h) {
						return nil, fmt.Errorf("conflicting binding rows")
					}
				}
			}
			if get(r, "condition_slot") != "" {
				rule, _ := obj["rule"].(map[string]any)
				if rule == nil {
					rule = map[string]any{"match": get(r, "rule_match"), "conditions": []any{}}
					obj["rule"] = rule
				}
				if rule["match"] != get(r, "rule_match") {
					return nil, fmt.Errorf("conflicting rule match")
				}
				v, e := strconv.ParseFloat(get(r, "condition_value"), 64)
				if e != nil {
					return nil, e
				}
				rule["conditions"] = append(rule["conditions"].([]any), map[string]any{"slot": get(r, "condition_slot"), "operator": get(r, "condition_operator"), "value": v, "point_id": get(r, "condition_variable_key")})
			}
			continue
		}
		raw, e := json.Marshal(obj)
		if e != nil {
			return nil, e
		}
		out = append(out, raw)
	}
	if idx == 2 {
		for _, key := range order {
			raw, _ := json.Marshal(bindings[key])
			out = append(out, raw)
		}
	}
	return out, nil
}
func Encode(b Bundle, format, kind string) ([]byte, error) {
	if b.Navigation != nil && format != "json" {
		return nil, fmt.Errorf("navigation requires JSON export")
	}
	if e := b.Validate(); e != nil {
		return nil, e
	}
	if format == "json" {
		return encodeTechnical(b, format, kind)
	}
	if format == "csv" {
		idx := -1
		for i, k := range []string{"screens", "variables", "bindings"} {
			if kind == k {
				idx = i
			}
		}
		if idx < 0 {
			return nil, fmt.Errorf("CSV requires single kind")
		}
		var buf bytes.Buffer
		w := csv.NewWriter(&buf)
		if e := w.WriteAll(csvSafe(humanRows(b, idx))); e != nil {
			return nil, e
		}
		return buf.Bytes(), nil
	}
	if format != "xlsx" {
		return nil, fmt.Errorf("unsupported format")
	}
	f := excelize.NewFile()
	defer f.Close()
	_, _ = f.NewSheet("_payload")
	for ri, row := range rows(b.Screens) {
		for ci, v := range row {
			cell, _ := excelize.CoordinatesToCellName(ci+1, ri+1)
			_ = f.SetCellStr("_payload", cell, v)
		}
	}
	_ = f.SetSheetVisible("_payload", false)
	for i, s := range sheets {
		if i == 0 {
			_ = f.SetSheetName("Sheet1", s)
		} else {
			_, _ = f.NewSheet(s)
		}
		for ri, r := range humanRows(b, i) {
			for ci, v := range r {
				if i == 0 && ci == 7 && ri > 0 {
					v = "@payload:" + r[0]
				}
				cell, _ := excelize.CoordinatesToCellName(ci+1, ri+1)
				if e := f.SetCellStr(s, cell, v); e != nil {
					return nil, e
				}
			}
		}
	}
	buf, e := f.WriteToBuffer()
	if e != nil {
		return nil, e
	}
	return buf.Bytes(), nil
}
func Decode(data []byte, format, kind string) (Bundle, error) {
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	if format == "json" {
		return decodeTechnical(data, format, kind)
	}
	b := Bundle{Format: Format, Version: 1}
	if len(data) > MaxBytes {
		return b, fmt.Errorf("file too large")
	}
	targets := []*[]json.RawMessage{&b.Screens, &b.Variables, &b.Bindings}
	if format == "csv" {
		rs, e := csv.NewReader(bytes.NewReader(data)).ReadAll()
		if e != nil {
			return b, e
		}
		rs = csvRestore(rs)
		if kind == "" && len(rs) > 0 {
			if len(rs[0]) > 0 && rs[0][0] == "screen_key" {
				kind = "bindings"
			} else if len(rs[0]) > 3 && rs[0][3] == "data_type" {
				kind = "variables"
			} else {
				kind = "screens"
			}
		}
		idx := -1
		for i, k := range []string{"screens", "variables", "bindings"} {
			if k == kind {
				idx = i
			}
		}
		if idx < 0 {
			return b, fmt.Errorf("CSV requires single kind")
		}
		*targets[idx], e = parseHuman(rs, idx)
		if e != nil {
			return b, e
		}
	} else if format == "xlsx" {
		f, e := excelize.OpenReader(bytes.NewReader(data), excelize.Options{UnzipSizeLimit: 64 << 20})
		if e != nil {
			return b, e
		}
		defer f.Close()
		payloadRows, pe := f.GetRows("_payload", excelize.Options{RawCellValue: true})
		payload := map[string]string{}
		if pe == nil {
			raws, e := parseRows(payloadRows)
			if e != nil {
				return b, e
			}
			for _, raw := range raws {
				payload[rowKey(raw)] = string(raw)
			}
		}
		for i, s := range sheets {
			rs, e := f.GetRows(s, excelize.Options{RawCellValue: true})
			if e != nil {
				return b, e
			}
			for ri, r := range rs {
				for ci := range r {
					cell, _ := excelize.CoordinatesToCellName(ci+1, ri+1)
					formula, _ := f.GetCellFormula(s, cell)
					if formula != "" {
						return b, fmt.Errorf("formulas forbidden")
					}
				}
			}
			if i == 0 {
				for ri := 1; ri < len(rs); ri++ {
					if len(rs[ri]) > 7 && len(rs[ri][7]) > 9 && rs[ri][7][:9] == "@payload:" {
						key := rs[ri][7][9:]
						raw, ok := payload[key]
						if !ok {
							return b, fmt.Errorf("screen payload missing")
						}
						rs[ri][7] = raw
					}
				}
			}
			*targets[i], e = parseHuman(rs, i)
			if e != nil {
				return b, e
			}
		}
	} else {
		return b, fmt.Errorf("unsupported format")
	}
	return b, b.Validate()
}

func csvSafe(rows [][]string) [][]string {
	for ri := 1; ri < len(rows); ri++ {
		for ci, v := range rows[ri] {
			trim := strings.TrimLeft(v, " \t\r\n")
			if strings.HasPrefix(v, "'") || len(trim) > 0 && strings.ContainsRune("=+-@", rune(trim[0])) {
				rows[ri][ci] = "'" + v
			}
		}
	}
	return rows
}
func csvRestore(rows [][]string) [][]string {
	for ri := 1; ri < len(rows); ri++ {
		for ci, v := range rows[ri] {
			if strings.HasPrefix(v, "'") {
				rest := v[1:]
				trim := strings.TrimLeft(rest, " \t\r\n")
				if strings.HasPrefix(rest, "'") || len(trim) > 0 && strings.ContainsRune("=+-@", rune(trim[0])) {
					rows[ri][ci] = rest
				}
			}
		}
	}
	return rows
}

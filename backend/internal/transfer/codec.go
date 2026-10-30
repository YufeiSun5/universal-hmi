package transfer

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"github.com/xuri/excelize/v2"
	"io"
	"strconv"
	"strings"
)

const Format = "universal-hmi-process-bundle"
const MaxBytes = 32 << 20

type Bundle struct {
	Navigation *Navigation       `json:"navigation,omitempty"`
	Format     string            `json:"format"`
	Version    int               `json:"version"`
	Screens    []json.RawMessage `json:"screens"`
	Variables  []json.RawMessage `json:"variables"`
	Bindings   []json.RawMessage `json:"bindings"`
}

var sheets = []string{"画面", "变量", "绑定"}

func (b Bundle) Validate() error {
	if b.Format != Format || b.Version != 1 {
		return fmt.Errorf("unsupported format/version")
	}
	if len(b.Screens) > 512 || len(b.Variables) > 20000 || len(b.Bindings) > 100000 {
		return fmt.Errorf("item limit exceeded")
	}
	for _, g := range [][]json.RawMessage{b.Screens, b.Variables, b.Bindings} {
		for _, r := range g {
			var m map[string]json.RawMessage
			if json.Unmarshal(r, &m) != nil || m == nil {
				return fmt.Errorf("row must be object")
			}
		}
	}
	return nil
}
func rowKey(r json.RawMessage) string {
	var v struct {
		Key      string `json:"key"`
		Screen   string `json:"screen_key"`
		Node     string `json:"node_id"`
		Property string `json:"property"`
	}
	_ = json.Unmarshal(r, &v)
	if v.Key != "" {
		return v.Key
	}
	return v.Screen + "/" + v.Node + "/" + v.Property
}

func rows(g []json.RawMessage) [][]string {
	o := [][]string{{"key", "part", "parts", "json"}}
	for _, v := range g {
		r := []rune(string(v))
		n := (len(r) + 29999) / 30000
		for i := 0; i < n; i++ {
			end := (i + 1) * 30000
			if end > len(r) {
				end = len(r)
			}
			o = append(o, []string{rowKey(v), strconv.Itoa(i + 1), strconv.Itoa(n), string(r[i*30000 : end])})
		}
	}
	return o
}
func parseRows(rs [][]string) ([]json.RawMessage, error) {
	o := []json.RawMessage{}
	if len(rs) == 0 || strings.Join(rs[0], ",") != "key,part,parts,json" {
		return nil, fmt.Errorf("expected key,part,parts,json")
	}
	for i := 1; i < len(rs); {
		r := rs[i]
		if len(r) != 4 {
			return nil, fmt.Errorf("invalid row")
		}
		n, e := strconv.Atoi(r[2])
		if e != nil || n < 1 || n > 1000 {
			return nil, fmt.Errorf("invalid parts")
		}
		var b strings.Builder
		for p := 1; p <= n; p++ {
			if i >= len(rs) {
				return nil, fmt.Errorf("missing part")
			}
			v := rs[i]
			if len(v) != 4 || v[0] != r[0] || v[1] != strconv.Itoa(p) || v[2] != r[2] {
				return nil, fmt.Errorf("part sequence invalid")
			}
			b.WriteString(v[3])
			if b.Len() > MaxBytes {
				return nil, fmt.Errorf("row too large")
			}
			i++
		}
		v := json.RawMessage(b.String())
		if !json.Valid(v) || rowKey(v) != r[0] {
			return nil, fmt.Errorf("invalid JSON or key")
		}
		o = append(o, v)
	}
	return o, nil
}
func encodeTechnical(b Bundle, format, kind string) ([]byte, error) {
	if e := b.Validate(); e != nil {
		return nil, e
	}
	g := [][]json.RawMessage{b.Screens, b.Variables, b.Bindings}
	switch format {
	case "json":
		return json.MarshalIndent(b, "", "  ")
	case "csv":
		idx := -1
		for i, k := range []string{"screens", "variables", "bindings"} {
			if kind == k {
				idx = i
			}
		}
		if idx < 0 {
			return nil, fmt.Errorf("CSV requires kind")
		}
		var buf bytes.Buffer
		w := csv.NewWriter(&buf)
		if e := w.WriteAll(rows(g[idx])); e != nil {
			return nil, e
		}
		return buf.Bytes(), nil
	case "xlsx":
		f := excelize.NewFile()
		defer f.Close()
		for i, s := range sheets {
			if i == 0 {
				_ = f.SetSheetName("Sheet1", s)
			} else {
				if _, e := f.NewSheet(s); e != nil {
					return nil, e
				}
			}
			for ri, r := range rows(g[i]) {
				for ci, v := range r {
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
	return nil, fmt.Errorf("unsupported format")
}
func decodeTechnical(data []byte, format, kind string) (Bundle, error) {
	b := Bundle{Format: Format, Version: 1}
	if len(data) > MaxBytes {
		return b, fmt.Errorf("file too large")
	}
	switch format {
	case "json":
		d := json.NewDecoder(bytes.NewReader(data))
		d.DisallowUnknownFields()
		if e := d.Decode(&b); e != nil {
			return b, e
		}
		if d.Decode(new(any)) != io.EOF {
			return b, fmt.Errorf("expected one object")
		}
	case "csv":
		rs, e := csv.NewReader(bytes.NewReader(data)).ReadAll()
		if e != nil {
			return b, e
		}
		v, e := parseRows(rs)
		if e != nil {
			return b, e
		}
		switch kind {
		case "screens":
			b.Screens = v
		case "variables":
			b.Variables = v
		case "bindings":
			b.Bindings = v
		default:
			return b, fmt.Errorf("CSV requires kind")
		}
	case "xlsx":
		f, e := excelize.OpenReader(bytes.NewReader(data), excelize.Options{UnzipSizeLimit: 64 << 20})
		if e != nil {
			return b, e
		}
		defer f.Close()
		targets := []*[]json.RawMessage{&b.Screens, &b.Variables, &b.Bindings}
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
						return b, fmt.Errorf("formula forbidden")
					}
				}
			}
			*targets[i], e = parseRows(rs)
			if e != nil {
				return b, e
			}
		}
	default:
		return b, fmt.Errorf("unsupported format")
	}
	return b, b.Validate()
}

package acquisition

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

func Decode(source, topic, protocol string, payload []byte) ([]Raw, error) {
	if len(payload) > maxPayloadBytes {
		return nil, fmt.Errorf("payload too large")
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(payload, &doc); err != nil {
		return nil, err
	}
	if doc == nil {
		return nil, fmt.Errorf("message must be an object")
	}
	out := make([]Raw, 0)
	appendRow := func(path string, value any, quality string, at time.Time) {
		out = append(out, Raw{SourceID: source, Topic: topic, Path: path, Value: value, Quality: quality, Time: at})
	}
	switch protocol {
	case "generic":
		var rows []struct {
			Path      string `json:"path"`
			Value     any    `json:"value"`
			Quality   string `json:"quality"`
			Timestamp string `json:"timestamp"`
		}
		if err := json.Unmarshal(doc["points"], &rows); err != nil {
			return nil, err
		}
		if len(rows) > 10000 {
			return nil, fmt.Errorf("too many points")
		}
		for _, r := range rows {
			at, err := time.Parse(time.RFC3339Nano, r.Timestamp)
			if err != nil {
				return nil, fmt.Errorf("source timestamp required")
			}
			q := "bad"
			if r.Quality == "good" {
				q = "good"
			}
			appendRow(r.Path, r.Value, q, at)
		}
	case "kep":
		var rows []struct {
			ID      string `json:"id"`
			Value   any    `json:"v"`
			Quality *bool  `json:"q"`
			Time    int64  `json:"t"`
		}
		if err := json.Unmarshal(doc["values"], &rows); err != nil {
			return nil, err
		}
		if len(rows) > 10000 {
			return nil, fmt.Errorf("too many points")
		}
		for _, r := range rows {
			q := "bad"
			if r.Quality != nil && *r.Quality {
				q = "good"
			}
			if r.Time <= 0 {
				return nil, fmt.Errorf("source timestamp required")
			}
			appendRow(r.ID, r.Value, q, time.UnixMilli(r.Time))
		}
	case "kingio", "kio":
		// No object means no update. PVs supplies defaults only for explicitly
		// listed objects; it must never synthesize other configured points.
		if _, ok := doc["Objs"]; !ok {
			return out, nil
		}
		var rows []struct {
			Name    string          `json:"N"`
			Value   json.RawMessage `json:"1"`
			Time    json.RawMessage `json:"2"`
			Quality json.RawMessage `json:"3"`
		}
		if err := json.Unmarshal(doc["Objs"], &rows); err != nil {
			return nil, err
		}
		if len(rows) > 10000 {
			return nil, fmt.Errorf("too many points")
		}
		out = make([]Raw, 0, len(rows))
		var defaults map[string]json.RawMessage
		if pvs, ok := doc["PVs"]; ok {
			if err := json.Unmarshal(pvs, &defaults); err != nil {
				return nil, err
			}
		}
		for _, r := range rows {
			if r.Name == "" {
				continue
			}
			valueJSON := r.Value
			if len(valueJSON) == 0 {
				valueJSON = defaults["1"]
			}
			if len(valueJSON) == 0 || isNull(valueJSON) {
				continue
			}
			var value any
			if err := json.Unmarshal(valueJSON, &value); err != nil {
				return nil, err
			}
			qualityJSON := r.Quality
			if len(qualityJSON) == 0 {
				qualityJSON = defaults["3"]
			}
			q := "bad"
			if n, ok := rawNumber(qualityJSON); ok && n == 192 {
				q = "good"
			}
			at, ok := kioSourceTime(r.Time, defaults["2"], doc["WriteTime"])
			if !ok {
				return nil, fmt.Errorf("source timestamp required")
			}
			appendRow(r.Name, value, q, at)
		}
	default:
		return nil, fmt.Errorf("unsupported protocol")
	}
	return out, nil
}

func isKIO(protocol string) bool        { return protocol == "kingio" || protocol == "kio" }
func isNull(value json.RawMessage) bool { return strings.TrimSpace(string(value)) == "null" }

// A JSON number in Objs.2 with a PVs.2 field is always a millisecond offset.
// A malformed base may fall back to WriteTime, but never reinterpret the
// offset as a Unix epoch (which could make old data appear fresh).
func kioSourceTime(object, base, writeTime json.RawMessage) (time.Time, bool) {
	if offset, ok := numericJSON(object); ok && len(base) > 0 {
		if at, valid := parseKIOTime(base); valid {
			milliseconds := math.Trunc(offset)
			if milliseconds > float64(math.MaxInt64/int64(time.Millisecond)) || milliseconds < float64(math.MinInt64/int64(time.Millisecond)) {
				return time.Time{}, false
			}
			return at.Add(time.Duration(milliseconds) * time.Millisecond), true
		}
		object = nil
	}
	for _, candidate := range []json.RawMessage{object, base, writeTime} {
		if at, ok := parseKIOTime(candidate); ok {
			return at, true
		}
	}
	return time.Time{}, false
}

func parseKIOTime(value json.RawMessage) (time.Time, bool) {
	if n, ok := numericJSON(value); ok {
		if n <= 0 || n >= float64(math.MaxInt64) {
			return time.Time{}, false
		}
		if n >= 1e12 {
			return time.UnixMilli(int64(n)), true
		}
		return time.Unix(int64(n), 0), true
	}
	var text string
	if err := json.Unmarshal(value, &text); err != nil {
		return time.Time{}, false
	}
	text = strings.TrimSpace(text)
	for _, layout := range []string{"2006-01-02 15:04:05.000 -0700", "2006-01-02 15:04:05 -0700", time.RFC3339Nano} {
		if at, err := time.Parse(layout, text); err == nil {
			return at, true
		}
	}
	for _, layout := range []string{"2006-01-02 15:04:05.000", "2006-01-02 15:04:05"} {
		if at, err := time.ParseInLocation(layout, text, time.Local); err == nil {
			return at, true
		}
	}
	return time.Time{}, false
}

func numericJSON(value json.RawMessage) (float64, bool) {
	if len(value) == 0 {
		return 0, false
	}
	var n json.Number
	if value[0] == '"' || isNull(value) {
		return 0, false
	}
	if err := json.Unmarshal(value, &n); err != nil {
		return 0, false
	}
	f, err := n.Float64()
	return f, err == nil && !math.IsNaN(f) && !math.IsInf(f, 0)
}
func rawNumber(value json.RawMessage) (float64, bool) {
	var v any
	if err := json.Unmarshal(value, &v); err != nil {
		return 0, false
	}
	return number(v)
}
func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, !math.IsNaN(n) && !math.IsInf(n, 0)
	case string:
		f, e := strconv.ParseFloat(n, 64)
		return f, e == nil && !math.IsNaN(f) && !math.IsInf(f, 0)
	}
	return 0, false
}

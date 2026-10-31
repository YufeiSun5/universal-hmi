package runtime

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
)

// One bounded catalogue for the whole engine, independent of configured points.
// It contains observations from current MQTT connection generations only.
const MaxDiscoveredPoints = 20000

type DiscoveredPoint struct {
	SourceID        string    `json:"source_id"`
	Topic           string    `json:"topic"`
	Path            string    `json:"path"`
	Name            string    `json:"name"`
	DataType        string    `json:"data_type"`
	TypeStatus      string    `json:"type_status"`
	Preview         string    `json:"preview"`
	Quality         string    `json:"quality"`
	SourceTime      time.Time `json:"source_time"`
	LastSeen        time.Time `json:"last_seen"`
	Retained        bool      `json:"retained"`
	ExistingID      string    `json:"existing_id,omitempty"`
	ExistingStation string    `json:"existing_station,omitempty"`
}

type DiscoveryPage struct {
	Revision       string                 `json:"revision"`
	Items          []DiscoveredPoint      `json:"items"`
	SourceID       string                 `json:"source_id"`
	State          string                 `json:"state"`
	Connected      bool                   `json:"connected"`
	Observed       int                    `json:"observed"`
	Total          int                    `json:"total"`
	Offset         int                    `json:"offset"`
	Limit          int                    `json:"limit"`
	Capacity       int                    `json:"capacity"`
	OmittedSamples uint64                 `json:"omitted_samples"`
	Metrics        acquisition.QueueStats `json:"metrics"`
}

// Plain text is a substring search. Wildcards match the complete path or topic.
// Comma/newline separated alternatives are OR; regex syntax stays literal.
func discoveryMatcher(query string) func(string) bool {
	query = strings.ToLower(strings.TrimSpace(query))
	parts := strings.FieldsFunc(query, func(r rune) bool { return r == ',' || r == '，' || r == '\n' || r == '\r' })
	matchers := make([]func(string) bool, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.ContainsAny(part, "*?") {
			matchers = append(matchers, func(value string) bool { return strings.Contains(value, part) })
			continue
		}
		pattern := strings.NewReplacer(`\*`, ".*", `\?`, ".").Replace(regexp.QuoteMeta(part))
		re := regexp.MustCompile("(?s)^" + pattern + "$")
		matchers = append(matchers, re.MatchString)
	}
	return func(value string) bool {
		if query == "" {
			return true
		}
		for _, match := range matchers {
			if match(strings.ToLower(value)) {
				return true
			}
		}
		return false
	}
}

func inferredType(v any) string {
	switch n := v.(type) {
	case bool:
		return "BOOL"
	case string:
		return "STRING"
	case float64:
		if !math.IsNaN(n) && !math.IsInf(n, 0) {
			// An integral sample cannot prove the source tag is an integer tag.
			return "FLOAT"
		}
	}
	return ""
}

func discoveryText(value string, maxBytes int) string {
	if len(value) <= maxBytes {
		return value
	}
	value = value[:maxBytes]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return value
}

func (e *Engine) clearDiscoveryLocked(id string) {
	for key := range e.discovered {
		if key.Source == id {
			delete(e.discovered, key)
		}
	}
	delete(e.discoveryOmitted, id)
}

// Called by the decoder worker, not the network callback. Old connections must
// not repopulate the catalogue after disconnect/reconfigure/reconnect.
func (e *Engine) receiveSource(id string, generation uint64, rows []acquisition.Raw) {
	e.mu.Lock()
	if e.connectionGeneration[id] != generation {
		e.mu.Unlock()
		return
	}
	e.observeDiscoveryLocked(id, rows)
	for i := range rows {
		rows[i].Generation = generation
	}
	e.mu.Unlock()
	e.Submit(rows)
}

func (e *Engine) observeDiscoveryLocked(id string, rows []acquisition.Raw) {
	if e.discovered == nil {
		e.discovered = map[inputKey]DiscoveredPoint{}
		e.discoveryOmitted = map[string]uint64{}
	}
	for _, r := range rows {
		if r.SourceID != id {
			continue
		}
		key := inputKey{id, r.Topic, r.Path}
		previous, exists := e.discovered[key]
		if r.Path == "" || strings.TrimSpace(r.Path) != r.Path || strings.TrimSpace(r.Topic) != r.Topic || len(r.Path) > 1024 || len(r.Topic) > 512 || strings.ContainsAny(r.Path+r.Topic, "\x00") || !utf8.ValidString(r.Path+r.Topic) || (!exists && len(e.discovered) >= MaxDiscoveredPoints) {
			e.discoveryOmitted[id]++
			continue
		}
		kind := inferredType(r.Value)
		status := "inferred"
		if previous.TypeStatus == "conflict" || (kind != "" && previous.DataType != "" && previous.DataType != kind) {
			kind, status = "", "conflict"
		} else if kind == "" {
			kind = previous.DataType
			if kind == "" {
				status = "unknown"
			}
		}
		preview, err := json.Marshal(r.Value)
		if err != nil {
			preview = []byte("无法显示")
		}
		seen := r.ReceivedTime
		if seen.IsZero() {
			seen = time.Now().UTC()
		}
		e.discovered[key] = DiscoveredPoint{
			SourceID: id, Topic: r.Topic, Path: r.Path,
			Name: discoveryText(r.Path, 256), DataType: kind, TypeStatus: status,
			Preview: discoveryText(string(preview), 256), Quality: r.Quality,
			SourceTime: r.Time, LastSeen: seen, Retained: r.Retained,
		}
	}
}

// Discovery never connects a source or changes point configuration. Pagination
// and filtering happen before returning data to the UI.
func (e *Engine) Discovery(id, query string, offset, limit int) (DiscoveryPage, error) {
	result := DiscoveryPage{Items: []DiscoveredPoint{}, SourceID: id, Offset: offset, Limit: limit, Capacity: MaxDiscoveredPoints}
	if offset < 0 || limit < 1 || limit > 500 || len(query) > 256 {
		return result, fmt.Errorf("invalid discovery page (limit 1..500, query up to 256 bytes)")
	}
	e.mu.Lock()
	found := false
	for _, source := range e.sources {
		if source.ID == id {
			found = true
			break
		}
	}
	if !found {
		e.mu.Unlock()
		return result, fmt.Errorf("source not found")
	}
	result.State = e.sourceState[id]
	if connection := e.connections[id]; connection != nil {
		result.Connected = connection.Client != nil && connection.Client.IsConnected()
		result.Metrics = connection.Stats()
	}
	result.OmittedSamples = e.discoveryOmitted[id]
	matches := discoveryMatcher(query)
	for key, row := range e.discovered {
		if key.Source != id {
			continue
		}
		result.Observed++
		if matches(row.Path) || matches(row.Topic) {
			result.Items = append(result.Items, row)
		}
	}
	e.mu.Unlock()
	sort.Slice(result.Items, func(i, j int) bool {
		a, b := result.Items[i], result.Items[j]
		if a.Path == b.Path {
			return a.Topic < b.Topic
		}
		return a.Path < b.Path
	})
	result.Total = len(result.Items)
	// Check saved definitions, including drafts and wildcard-topic mappings.
	existing := map[inputKey][2]string{}
	for _, p := range e.Points.List() {
		if p.SourceType == "mqtt" && p.SourceID == id {
			existing[inputKey{id, p.Topic, p.SourcePath}] = [2]string{p.ID, p.Station}
		}
	}
	hash := sha256.New()
	encoder := json.NewEncoder(hash)
	for i, row := range result.Items {
		match := existing[inputKey{id, row.Topic, row.Path}]
		if match[0] == "" {
			match = existing[inputKey{id, "", row.Path}]
		}
		result.Items[i].ExistingID, result.Items[i].ExistingStation = match[0], match[1]
		// Values/timestamps change continuously and must not invalidate selection.
		_ = encoder.Encode([]string{row.Topic, row.Path, row.DataType, row.TypeStatus, match[0], match[1]})
	}
	result.Revision = fmt.Sprintf("%x", hash.Sum(nil))
	start := min(offset, result.Total)
	result.Items = result.Items[start:min(start+limit, result.Total)]
	return result, nil
}

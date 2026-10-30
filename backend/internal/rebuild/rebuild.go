// Package rebuild plans an explicitly authorized, offline configuration rebuild.
// It never starts acquisition and never deletes history or identity data.
package rebuild

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"

	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

const MigrationID = "process-rebuild-v10"
const markerKey = "maintenance." + MigrationID

type Change struct {
	Kind      string `json:"kind"`
	ID        string `json:"id"`
	Operation string `json:"operation"`
	Reason    string `json:"reason"`
}
type Result struct {
	MigrationID          string            `json:"migration_id"`
	Status               string            `json:"status"`
	PreviewToken         string            `json:"preview_token,omitempty"`
	BackupManifestSHA256 string            `json:"backup_manifest_sha256,omitempty"`
	Changes              []Change          `json:"changes,omitempty"`
	Counts               map[string]int    `json:"counts,omitempty"`
	Preserved            map[string]string `json:"preserved,omitempty"`
	ResidualStations     []string          `json:"residual_stations,omitempty"`
}

func hash(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func rawHash(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func snapshotHash(s *storage.ConfigurationSnapshot) string {
	configs := map[string]string{}
	docs := map[string]map[string]string{}
	for k, v := range s.Config {
		configs[k] = rawHash(v)
	}
	for kind, list := range s.Documents {
		docs[kind] = map[string]string{}
		for id, v := range list {
			docs[kind][id] = rawHash(v)
		}
	}
	return hash([]any{configs, docs})
}
func encode(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
func object(b []byte) (map[string]json.RawMessage, error) {
	m := map[string]json.RawMessage{}
	e := json.Unmarshal(b, &m)
	if m == nil && e == nil {
		e = errors.New("invalid configuration object")
	}
	return m, e
}
func text(b []byte) string { var s string; _ = json.Unmarshal(b, &s); return s }
func increment(m map[string]json.RawMessage) {
	var n int64
	_ = json.Unmarshal(m["revision"], &n)
	m["revision"] = encode(n + 1)
}

func Plan(s *storage.ConfigurationSnapshot, backupHash string) (Result, error) {
	out := Result{MigrationID: MigrationID, Status: "ready", BackupManifestSHA256: backupHash, Changes: []Change{}, Counts: map[string]int{}, Preserved: map[string]string{}, ResidualStations: []string{}}
	if b, ok := s.Config[markerKey]; ok {
		if e := json.Unmarshal(b, &out); e != nil {
			return out, errors.New("invalid rebuild marker")
		}
		out.Status = "already_applied"
		return out, nil
	}
	add := func(kind, id, op, reason string) {
		out.Changes = append(out.Changes, Change{kind, id, op, reason})
		out.Counts[kind]++
	}
	beforeHash := snapshotHash(s)
	for k, v := range s.Config {
		if k != "rules" && k != "policy" && k != "station_policies" && k != "station_directory" && k != "page_navigation" && k != "equipment_register" {
			out.Preserved[k] = rawHash(v)
		}
	}
	deletedScreens := map[string]bool{}
	docs := s.Documents["screens"]
	// Documents adapter uses process_screens as the public screen document kind.
	if docs == nil {
		docs = s.Documents["process_screens"]
	}
	for id, b := range docs {
		m, e := object(b)
		if e != nil {
			return out, e
		}
		if text(m["kind"]) != "gis" {
			deletedScreens[id] = true
			delete(docs, id)
			add("screen", id, "delete", "non-GIS process screen")
		}
	}
	deletedPoints := map[string]bool{}
	if b := s.Documents["points"]["definitions"]; len(b) > 0 {
		var list []map[string]json.RawMessage
		if e := json.Unmarshal(b, &list); e != nil {
			return out, e
		}
		for _, p := range list {
			id := text(p["id"])
			deletedPoints[id] = true
			add("variable", id, "delete", "old variable definition")
		}
	}
	if s.Documents["points"] == nil {
		s.Documents["points"] = map[string]json.RawMessage{}
	}
	s.Documents["points"]["definitions"] = encode([]any{})
	for id, b := range docs {
		m, e := object(b)
		if e != nil {
			return out, e
		}
		changed := false
		var gis map[string]json.RawMessage
		if len(m["gis"]) > 0 {
			if e = json.Unmarshal(m["gis"], &gis); e != nil {
				return out, e
			}
			var stations []map[string]json.RawMessage
			if e = json.Unmarshal(gis["stations"], &stations); e != nil {
				return out, e
			}
			for _, st := range stations {
				sid := text(st["id"])
				var zones []map[string]json.RawMessage
				if len(st["zones"]) > 0 {
					if e = json.Unmarshal(st["zones"], &zones); e != nil {
						return out, e
					}
				}
				for _, section := range append([]map[string]json.RawMessage{st}, zones...) {
					var bindings map[string]string
					if len(section["bindings"]) > 0 {
						if e = json.Unmarshal(section["bindings"], &bindings); e != nil {
							return out, e
						}
						for k, p := range bindings {
							if p != "" {
								delete(bindings, k)
								changed = true
								add("gis_binding", id+"/"+sid+"/"+text(section["id"])+"/"+k, "clear", "old variable reference")
							}
						}
						section["bindings"] = encode(bindings)
					}
				}
				if len(st["zones"]) > 0 {
					st["zones"] = encode(zones)
				}
				target := text(st["target_screen_id"])
				if deletedScreens[target] {
					delete(st, "target_screen_id")
					changed = true
					add("gis_target", id+"/"+sid, "clear", "deleted process screen")
				}
			}
			gis["stations"] = encode(stations)
			m["gis"] = encode(gis)
		}
		if owner := text(m["station"]); owner != "" {
			out.ResidualStations = append(out.ResidualStations, owner)
		}
		if changed {
			increment(m)
			docs[id] = encode(m)
		}
	}
	// Remove rules depending on removed points or their removed station scopes.
	if b := s.Config["rules"]; len(b) > 0 {
		var rules []map[string]json.RawMessage
		if e := json.Unmarshal(b, &rules); e != nil {
			return out, e
		}
		keep := []map[string]json.RawMessage{}
		for _, rule := range rules {
			drop := text(rule["station"]) != ""
			for _, key := range []string{"conditions", "actions"} {
				var refs []map[string]json.RawMessage
				if len(rule[key]) > 0 {
					if e := json.Unmarshal(rule[key], &refs); e != nil {
						return out, e
					}
					for _, ref := range refs {
						if text(ref["point_id"]) != "" {
							drop = true
						}
					}
				}
			}
			if drop {
				add("rule", text(rule["id"]), "delete", "old variable or station scope")
			} else {
				keep = append(keep, rule)
			}
		}
		s.Config["rules"] = encode(keep)
	}
	if b := s.Config["policy"]; len(b) > 0 {
		m, e := object(b)
		if e != nil {
			return out, e
		}
		m["enabled"] = encode(false)
		m["station"] = encode("")
		m["point_ids"] = encode([]string{})
		s.Config["policy"] = encode(m)
		add("storage_policy", "global", "disable", "prevent implicit collection of replacement variables")
	}
	if b := s.Config["station_policies"]; len(b) > 0 {
		var policies map[string]json.RawMessage
		if e := json.Unmarshal(b, &policies); e != nil {
			return out, e
		}
		for station := range policies {
			add("storage_policy", station, "delete", "old station policy")
		}
	}
	s.Config["station_policies"] = encode(map[string]any{})
	if b := s.Config["equipment_register"]; len(b) > 0 {
		var devices []map[string]json.RawMessage
		if e := json.Unmarshal(b, &devices); e != nil {
			return out, e
		}
		changed := false
		for _, d := range devices {
			var signals map[string]json.RawMessage
			if len(d["signals"]) == 0 {
				continue
			}
			if e := json.Unmarshal(d["signals"], &signals); e != nil {
				return out, e
			}
			deviceChanged := false
			for _, key := range []string{"fault", "running"} {
				if len(signals[key]) == 0 || string(signals[key]) == "null" {
					continue
				}
				m, e := object(signals[key])
				if e != nil {
					return out, e
				}
				if text(m["point_id"]) != "" {
					delete(signals, key)
					deviceChanged = true
					add("equipment_signal", text(d["id"])+"/"+key, "clear", "old variable reference; asset preserved")
				}
			}
			if deviceChanged {
				d["signals"] = encode(signals)
				increment(d)
				changed = true
			}
		}
		if changed {
			s.Config["equipment_register"] = encode(devices)
		}
	}
	if b := s.Config["page_navigation"]; len(b) > 0 {
		m, e := object(b)
		if e != nil {
			return out, e
		}
		var nodes []map[string]json.RawMessage
		if e = json.Unmarshal(m["nodes"], &nodes); e != nil {
			return out, e
		}
		var clear func([]map[string]json.RawMessage) error
		changed := false
		clear = func(nodes []map[string]json.RawMessage) error {
			for _, n := range nodes {
				if deletedScreens[text(n["screen_id"])] {
					delete(n, "screen_id")
					changed = true
					add("navigation", text(n["id"]), "clear", "deleted process screen")
				}
				if len(n["children"]) > 0 {
					var children []map[string]json.RawMessage
					if e := json.Unmarshal(n["children"], &children); e != nil {
						return e
					}
					if e := clear(children); e != nil {
						return e
					}
					n["children"] = encode(children)
				}
			}
			return nil
		}
		if e = clear(nodes); e != nil {
			return out, e
		}
		if changed {
			m["nodes"] = encode(nodes)
			increment(m)
			s.Config["page_navigation"] = encode(m)
		}
	}
	s.Config["station_directory"] = encode([]string{})
	s.Config["station_directory_mode"] = encode("explicit")
	add("station_directory", "explicit", "clear", "history retained independently")
	sort.Slice(out.Changes, func(i, j int) bool {
		a, b := out.Changes[i], out.Changes[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		return a.ID < b.ID
	})
	sort.Strings(out.ResidualStations)
	out.PreviewToken = hash([]any{MigrationID, beforeHash, backupHash, out.Changes})
	return out, nil
}

func Run(ctx context.Context, store *storage.Store, operation, backupHash, token string) (Result, error) {
	var out Result
	e := store.MaintainConfiguration(ctx, operation == "commit", func(s *storage.ConfigurationSnapshot) error {
		if b, ok := s.Config[markerKey]; ok {
			if e := json.Unmarshal(b, &out); e != nil {
				return errors.New("invalid rebuild marker")
			}
			out.Status = "already_applied"
			return nil
		}
		if operation == "status" {
			out = Result{MigrationID: MigrationID, Status: "pending"}
			return nil
		}
		if operation != "plan" && operation != "commit" {
			return errors.New("unsupported rebuild operation")
		}
		if backupHash == "" {
			return errors.New("verified backup manifest required")
		}
		var e error
		out, e = Plan(s, backupHash)
		if e != nil {
			return e
		}
		if operation == "commit" {
			if token == "" || token != out.PreviewToken {
				return errors.New("rebuild plan changed; plan again")
			}
			out.Status = "applied"
			s.Config[markerKey] = encode(out)
		}
		return nil
	})
	return out, e
}

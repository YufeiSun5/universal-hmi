// Package ownership previews and saves explicit point station assignments.
// Artwork is evidence for a suggestion, never proof of physical ownership.
package ownership

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
)

var ErrConflict = errors.New("ownership plan changed or blocked; preview again")

type Request struct {
	Targets      []points.StationTarget `json:"targets"`
	PreviewToken string                 `json:"preview_token,omitempty"`
}
type Reference struct {
	ScreenID   string `json:"screen_id"`
	ScreenName string `json:"screen_name"`
	Station    string `json:"station"`
	Property   string `json:"property"`
}
type Item struct {
	ID               string      `json:"id"`
	Name             string      `json:"name"`
	Revision         string      `json:"revision"`
	Station          string      `json:"station"`
	SuggestedStation string      `json:"suggested_station"`
	Classification   string      `json:"classification"`
	ScreenStations   []string    `json:"screen_stations"`
	References       []Reference `json:"references"`
	TargetStation    string      `json:"target_station"`
	Status           string      `json:"status"`
	Blockers         []string    `json:"blockers"`
	Dependencies     []string    `json:"dependencies"`
}
type BackupEntry struct {
	ID                    string `json:"id"`
	Station               string `json:"station"`
	TargetStation         string `json:"target_station"`
	BeforeRevision        string `json:"before_revision"`
	AfterRevision         string `json:"after_revision"`
	PreservedFieldsSHA256 string `json:"preserved_fields_sha256"`
}
type Backup struct {
	Schema          string                 `json:"schema"`
	ID              string                 `json:"id"`
	PreviewToken    string                 `json:"preview_token"`
	Entries         []BackupEntry          `json:"entries"`
	RollbackTargets []points.StationTarget `json:"rollback_targets"`
}
type Result struct {
	PreviewToken  string         `json:"preview_token"`
	CanCommit     bool           `json:"can_commit"`
	RequiresApply bool           `json:"requires_apply"`
	Applied       bool           `json:"applied"`
	Saved         bool           `json:"saved"`
	Backup        *Backup        `json:"backup,omitempty"`
	Items         []Item         `json:"items"`
	Counts        map[string]int `json:"counts"`
}
type ConfigStore interface{ LoadConfig(string, any) error }
type Service struct {
	Points   *points.Service
	Screens  *process.Service
	Stations *stations.Service
	Store    ConfigStore
	mu       sync.Mutex
}

func digest(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func require(ctx context.Context) error {
	a, ok := authorization.FromContext(ctx)
	if ok && (!a.Active() || !a.Grants.Develop()) {
		return authorization.ErrDenied
	}
	return nil
}
func stationAllowed(ctx context.Context, name string) bool {
	a, ok := authorization.FromContext(ctx)
	return !ok || a.Active() && a.Station(name)
}
func contains(v any, id string) bool {
	switch x := v.(type) {
	case string:
		return x == id
	case []any:
		for _, v := range x {
			if contains(v, id) {
				return true
			}
		}
	case map[string]any:
		for _, v := range x {
			if contains(v, id) {
				return true
			}
		}
	}
	return false
}

func (s *Service) plan(ctx context.Context, r Request, rows []points.Definition, directory []stations.Station) (Result, error) {
	out := Result{RequiresApply: true, Items: []Item{}, Counts: map[string]int{"total": 0, "single": 0, "shared": 0, "unreferenced": 0, "selected": len(r.Targets), "ready": 0, "blocked": 0}}
	if err := require(ctx); err != nil {
		return out, err
	}
	if len(r.Targets) > points.MaxDefinitions {
		return out, errors.New("ownership selection too large")
	}
	selected := map[string]points.StationTarget{}
	for _, t := range r.Targets {
		if t.ID == "" || t.Revision == "" || t.Station == "" || len(t.Station) > 128 || strings.TrimSpace(t.Station) != t.Station {
			return out, errors.New("invalid ownership target")
		}
		if _, ok := selected[t.ID]; ok {
			return out, errors.New("duplicate ownership target")
		}
		selected[t.ID] = t
	}
	names := map[string]bool{}
	for _, st := range directory {
		names[st.Name] = true
	}
	references := map[string][]Reference{}
	screenState := []process.Document{}
	if s.Screens != nil {
		summaries, err := s.Screens.ListAll()
		if err != nil {
			return out, err
		}
		a, secured := authorization.FromContext(ctx)
		for _, summary := range summaries {
			d, err := s.Screens.Get(summary.ID)
			if err != nil {
				return out, err
			}
			screenState = append(screenState, d)
			if d.Kind == "gis" || d.Station == "" || secured && !a.Screen(d.ID, d.Station) {
				continue
			}
			add := func(id, property string) {
				if id != "" {
					references[id] = append(references[id], Reference{d.ID, d.Name, d.Station, property})
				}
			}
			for _, n := range d.Nodes {
				add(n.PointID, n.ID+"/point_id")
				for _, pair := range []struct {
					name string
					rule *process.ArrowRule
				}{{"arrow_visible_rule", n.ArrowVisibleRule}, {"arrow_motion_rule", n.ArrowMotionRule}} {
					if pair.rule != nil {
						for i, c := range pair.rule.Conditions {
							add(c.PointID, fmt.Sprintf("%s/%s/%d", n.ID, pair.name, i))
						}
					}
				}
			}
		}
	}
	configs := map[string]any{}
	for _, key := range []string{"station_policies", "policy", "rules"} {
		var v any
		if err := s.Store.LoadConfig(key, &v); err != nil {
			return out, err
		}
		configs[key] = v
	}
	next := map[string]string{}
	for _, p := range rows {
		next[p.ID] = p.Station
	}
	for _, t := range r.Targets {
		next[t.ID] = t.Station
	}
	collisions := map[string]int{}
	for _, p := range rows {
		collisions[next[p.ID]+"\x00"+p.Name]++
	}
	derivedDependents := map[string]bool{}
	for _, p := range rows {
		for _, id := range p.Inputs {
			derivedDependents[id] = true
		}
	}
	found := 0
	for _, p := range rows {
		t, isSelected := selected[p.ID]
		if !stationAllowed(ctx, p.Station) {
			if isSelected {
				return out, authorization.ErrDenied
			}
			continue
		}
		it := Item{ID: p.ID, Name: p.Name, Revision: points.Revision(p), Station: p.Station, TargetStation: p.Station, Status: "unchanged", ScreenStations: []string{}, References: references[p.ID], Blockers: []string{}, Dependencies: []string{}}
		if it.References == nil {
			it.References = []Reference{}
		}
		seen := map[string]bool{}
		for _, ref := range it.References {
			seen[ref.Station] = true
		}
		for st := range seen {
			it.ScreenStations = append(it.ScreenStations, st)
		}
		sort.Strings(it.ScreenStations)
		it.Classification = "unreferenced"
		if len(seen) == 1 {
			it.Classification = "single"
			it.SuggestedStation = it.ScreenStations[0]
		} else if len(seen) > 1 {
			it.Classification = "shared"
		}
		if derivedDependents[p.ID] {
			it.Dependencies = append(it.Dependencies, "derived-dependent")
		}
		if len(p.Inputs) > 0 {
			it.Dependencies = append(it.Dependencies, "derived-inputs")
		}
		if isSelected {
			found++
			it.TargetStation = t.Station
			if !stationAllowed(ctx, t.Station) {
				return out, authorization.ErrDenied
			}
			block := func(code string) { it.Blockers = append(it.Blockers, code) }
			if t.Revision != it.Revision {
				block("revision-conflict")
			}
			if !names[t.Station] {
				block("target-station-missing")
			}
			if collisions[t.Station+"\x00"+p.Name] > 1 {
				block("target-name-collision")
			}
			if t.Station != p.Station {
				// Explicit station point selections cannot silently change storage scope.
				if policies, ok := configs["station_policies"].(map[string]any); ok {
					for st, policy := range policies {
						if contains(policy, p.ID) {
							it.Dependencies = append(it.Dependencies, "station-storage-policy")
							if st != t.Station {
								block("station-storage-policy")
							}
						}
						if policy, ok := policy.(map[string]any); ok {
							enabled, _ := policy["enabled"].(bool)
							ids, _ := policy["point_ids"].([]any)
							if enabled && len(ids) == 0 && (st == p.Station || st == t.Station) {
								block("enabled-whole-station-storage-policy")
							}
						}
					}
				}
				// Scoped automation must be reviewed rather than silently changing its input scope.
				if rules, ok := configs["rules"].([]any); ok {
					for _, raw := range rules {
						if rule, ok := raw.(map[string]any); ok && contains(rule, p.ID) {
							it.Dependencies = append(it.Dependencies, "automation-rule")
							if st, _ := rule["station"].(string); st != "" && st != t.Station {
								block("scoped-automation-rule")
							}
						}
					}
				}
				// Foreign derived scope is retained and surfaced; formulas remain stable-ID references.
				if len(it.Blockers) == 0 {
					it.Status = "ready"
					out.Counts["ready"]++
				}
			}
			if len(it.Blockers) > 0 {
				it.Status = "blocked"
				out.Counts["blocked"]++
			}
		}
		out.Items = append(out.Items, it)
		out.Counts["total"]++
		out.Counts[it.Classification]++
	}
	if found != len(selected) {
		return out, errors.New("ownership target unavailable")
	}
	sort.Slice(out.Items, func(i, j int) bool { return out.Items[i].ID < out.Items[j].ID })
	out.CanCommit = len(selected) > 0 && out.Counts["blocked"] == 0 && out.Counts["ready"] > 0
	a, _ := authorization.FromContext(ctx)
	r.PreviewToken = ""
	out.PreviewToken = digest([]any{r, out.Items, rows, screenState, directory, configs, a.ID, a.Version})
	return out, nil
}

func (s *Service) Run(ctx context.Context, r Request, commit bool) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := require(ctx); err != nil {
		return Result{}, err
	}
	directory, err := s.Stations.List()
	if err != nil {
		return Result{}, err
	}
	if !commit {
		return s.plan(ctx, r, s.Points.List(), directory)
	}
	var out Result
	err = s.Points.ReassignStations(r.Targets, func(rows []points.Definition) (string, []byte, error) {
		var err error
		out, err = s.plan(ctx, r, rows, directory)
		if err != nil {
			return "", nil, err
		}
		if !out.CanCommit || r.PreviewToken == "" || r.PreviewToken != out.PreviewToken {
			return "", nil, ErrConflict
		}
		if err = require(ctx); err != nil {
			return "", nil, err
		}
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return "", nil, err
		}
		backup := &Backup{Schema: "universal-hmi-point-ownership-recovery-v1", ID: hex.EncodeToString(random[:]), PreviewToken: out.PreviewToken, Entries: []BackupEntry{}, RollbackTargets: []points.StationTarget{}}
		targets := map[string]points.StationTarget{}
		for _, t := range r.Targets {
			targets[t.ID] = t
		}
		for _, p := range rows {
			if t, ok := targets[p.ID]; ok && t.Station != p.Station {
				after := p
				after.Station = t.Station
				preserved := p
				preserved.Station = ""
				backup.Entries = append(backup.Entries, BackupEntry{p.ID, p.Station, t.Station, points.Revision(p), points.Revision(after), digest(preserved)})
				backup.RollbackTargets = append(backup.RollbackTargets, points.StationTarget{ID: p.ID, Revision: points.Revision(after), Station: p.Station})
			}
		}
		out.Backup = backup
		b, err := json.Marshal(backup)
		return backup.ID, b, err
	})
	if err != nil {
		return out, err
	}
	out.Saved = true
	return out, nil
}

// Package configdelete plans non-cascading engineering configuration deletion.
package configdelete

import (
	"context"
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
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

var ErrConflict = errors.New("delete plan changed or blocked; preview again")

type Target struct {
	ID       string `json:"id,omitempty"`
	Name     string `json:"name,omitempty"`
	Revision string `json:"revision,omitempty"`
}
type Request struct {
	Targets      []Target `json:"targets"`
	PreviewToken string   `json:"preview_token,omitempty"`
}
type Reference struct {
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Property string `json:"property"`
}
type Item struct {
	ID         string      `json:"id,omitempty"`
	Name       string      `json:"name,omitempty"`
	Revision   string      `json:"revision,omitempty"`
	Status     string      `json:"status"`
	References []Reference `json:"references"`
}
type Result struct {
	PreviewToken string   `json:"preview_token"`
	CanCommit    bool     `json:"can_commit"`
	Items        []Item   `json:"items"`
	Deleted      []string `json:"deleted,omitempty"`
}
type Service struct {
	Screens        *process.Service
	Points         *points.Service
	Stations       *stations.Service
	Store          *storage.Store
	ActiveStations func() map[string][]string
	mu             sync.Mutex
}

func hash(v any) string {
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
func decode(raw []byte) (any, error) { var v any; e := json.Unmarshal(raw, &v); return v, e }

func pointReferences(v any, id, path string, emit func(string)) {
	switch n := v.(type) {
	case map[string]any:
		for k, x := range n {
			p := path + "/" + k
			if k == "point_id" && x == id {
				emit(p)
				continue
			}
			if k == "inputs" || k == "point_ids" {
				if list, ok := x.([]any); ok {
					for i, a := range list {
						if a == id {
							emit(fmt.Sprintf("%s/%d", p, i))
						}
					}
				}
				continue
			}
			if k == "bindings" {
				if m, ok := x.(map[string]any); ok {
					for b, a := range m {
						if a == id {
							emit(p + "/" + b)
						}
					}
				}
			}
			pointReferences(x, id, p, emit)
		}
	case []any:
		for i, x := range n {
			pointReferences(x, id, fmt.Sprintf("%s/%d", path, i), emit)
		}
	}
}
func stationReferences(v any, name, path string, emit func(string)) {
	switch n := v.(type) {
	case map[string]any:
		for k, x := range n {
			p := path + "/" + k
			if (k == "station" || k == "name" && strings.Contains(path, "/gis/stations/")) && x == name {
				emit(p)
			}
			stationReferences(x, name, p, emit)
		}
	case []any:
		for i, x := range n {
			stationReferences(x, name, fmt.Sprintf("%s/%d", path, i), emit)
		}
	}
}
func refs(s storage.ConfigurationSnapshot, target string, station bool, selected map[string]bool) ([]Reference, error) {
	out := []Reference{}
	scan := func(kind, id string, b []byte) error {
		v, e := decode(b)
		if e != nil {
			return e
		}
		emit := func(path string) { out = append(out, Reference{kind, id, path}) }
		if station {
			stationReferences(v, target, "", emit)
		} else {
			pointReferences(v, target, "", emit)
		}
		return nil
	}
	for kind, docs := range s.Documents {
		if kind != "screens" && kind != "points" {
			continue
		}
		for id, b := range docs {
			if kind == "points" && !station {
				var list []map[string]any
				if e := json.Unmarshal(b, &list); e != nil {
					return nil, e
				}
				for _, p := range list {
					pid, _ := p["id"].(string)
					if selected[pid] {
						continue
					}
					data, _ := json.Marshal(p)
					if e := scan("variable", pid, data); e != nil {
						return nil, e
					}
				}
			} else {
				if e := scan(kind, id, b); e != nil {
					return nil, e
				}
			}
		}
	}
	for _, key := range []string{"rules", "policy", "station_policies", "equipment_register"} {
		b := s.Config[key]
		if len(b) == 0 {
			continue
		}
		if e := scan(key, key, b); e != nil {
			return nil, e
		}
		if station && key == "station_policies" {
			var m map[string]any
			if e := json.Unmarshal(b, &m); e != nil {
				return nil, e
			}
			if _, ok := m[target]; ok {
				out = append(out, Reference{key, target, "/" + target})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		if a.ID != b.ID {
			return a.ID < b.ID
		}
		return a.Property < b.Property
	})
	return out, nil
}
func (s *Service) plan(ctx context.Context, r Request, station bool, snapshot storage.ConfigurationSnapshot, stationNames map[string]bool, active map[string][]string) (Result, error) {
	out := Result{CanCommit: true, Items: []Item{}}
	if e := require(ctx); e != nil {
		return out, e
	}
	if len(r.Targets) == 0 || len(r.Targets) > points.MaxDefinitions {
		return out, errors.New("invalid delete selection")
	}
	selected := map[string]bool{}
	for _, t := range r.Targets {
		key := t.ID
		if station {
			key = t.Name
		}
		if key == "" || selected[key] {
			return out, errors.New("empty or duplicate delete target")
		}
		selected[key] = true
	}
	index := map[string]points.Definition{}
	currentPoints := s.Points.List()
	for _, p := range currentPoints {
		index[p.ID] = p
	}
	documents := map[string]map[string]json.RawMessage{}
	for kind, docs := range snapshot.Documents {
		documents[kind] = docs
	}
	snapshot.Documents = documents
	snapshot.Documents["points"] = map[string]json.RawMessage{}
	snapshot.Documents["points"]["definitions"], _ = json.Marshal(currentPoints)

	for _, t := range r.Targets {
		it := Item{ID: t.ID, Name: t.Name, Status: "ready", References: []Reference{}}
		key := t.ID
		if station {
			key = t.Name
			if !stationNames[key] {
				it.Status = "conflict"
			}
		} else {
			p, ok := index[t.ID]
			if !ok || t.Revision == "" || points.Revision(p) != t.Revision {
				it.Status = "conflict"
			}
			if ok {
				it.Revision = points.Revision(p)
			}
		}
		var e error
		it.References, e = refs(snapshot, key, station, selected)
		if e != nil {
			return out, e
		}
		if station {
			for _, id := range active[key] {
				it.References = append(it.References, Reference{Kind: "runtime", ID: id, Property: "active_owner_apply_before_delete"})
			}
		}
		if len(it.References) > 0 && it.Status == "ready" {
			it.Status = "blocked"
		}
		if it.Status != "ready" {
			out.CanCommit = false
		}
		out.Items = append(out.Items, it)
	}
	actor, _ := authorization.FromContext(ctx)
	r.PreviewToken = ""
	out.PreviewToken = hash([]any{r, out.Items, actor.ID, actor.Version, snapshot.Config["station_directory"], snapshot.Config["station_directory_deleted"], stationNames, active})
	return out, nil
}
func (s *Service) Run(ctx context.Context, r Request, station, commit bool) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out Result
	if e := require(ctx); e != nil {
		return out, e
	}
	legacyScreens := map[string]json.RawMessage{}
	if s.Screens != nil {
		summaries, e := s.Screens.ListAll()
		if e != nil {
			return out, e
		}
		for _, summary := range summaries {
			d, e := s.Screens.Get(summary.ID)
			if e != nil {
				return out, e
			}
			legacyScreens[d.ID], _ = json.Marshal(d)
		}
	}
	stationNames := map[string]bool{}
	active := map[string][]string{}
	if station && s.ActiveStations != nil {
		active = s.ActiveStations()
	}
	if station {
		all, e := s.Stations.List()
		if e != nil {
			return out, e
		}
		for _, st := range all {
			stationNames[st.Name] = true
		}
	}
	e := s.Store.MaintainConfiguration(ctx, station && commit, func(snapshot *storage.ConfigurationSnapshot) error {
		scanSnapshot := *snapshot
		scanSnapshot.Documents = map[string]map[string]json.RawMessage{}
		for kind, docs := range snapshot.Documents {
			scanSnapshot.Documents[kind] = docs
		}
		if len(scanSnapshot.Documents["screens"]) == 0 {
			scanSnapshot.Documents["screens"] = legacyScreens
		}
		var e error
		out, e = s.plan(ctx, r, station, scanSnapshot, stationNames, active)
		if e != nil {
			return e
		}
		if !commit {
			return nil
		}
		if !out.CanCommit || r.PreviewToken == "" || out.PreviewToken != r.PreviewToken {
			return ErrConflict
		}
		if station {
			var names, deleted []string
			if b := snapshot.Config["station_directory"]; len(b) > 0 {
				if e = json.Unmarshal(b, &names); e != nil {
					return e
				}
			}
			if b := snapshot.Config["station_directory_deleted"]; len(b) > 0 {
				if e = json.Unmarshal(b, &deleted); e != nil {
					return e
				}
			}
			remove := map[string]bool{}
			for _, t := range r.Targets {
				remove[t.Name] = true
				deleted = append(deleted, t.Name)
				out.Deleted = append(out.Deleted, t.Name)
			}
			keep := []string{}
			for _, name := range names {
				if !remove[name] {
					keep = append(keep, name)
				}
			}
			snapshot.Config["station_directory"], _ = json.Marshal(keep)
			sort.Strings(deleted)
			unique := []string{}
			for _, name := range deleted {
				if len(unique) == 0 || unique[len(unique)-1] != name {
					unique = append(unique, name)
				}
			}
			snapshot.Config["station_directory_deleted"], _ = json.Marshal(unique)
		}
		return nil
	})
	if e != nil {
		return out, e
	}
	if commit && !station {
		targets := map[string]string{}
		for _, t := range r.Targets {
			targets[t.ID] = t.Revision
		}
		if e = require(ctx); e != nil {
			return out, e
		}
		if e = s.Points.DeleteBatchRevisions(targets); e != nil {
			return out, ErrConflict
		}
		for _, t := range r.Targets {
			out.Deleted = append(out.Deleted, t.ID)
		}
	}
	return out, nil
}

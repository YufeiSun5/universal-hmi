package transfer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"reflect"
	"sort"
	"strings"
	"sync"
)

type Target struct {
	ID       string          `json:"id"`
	Mode     string          `json:"mode"`
	Revision json.RawMessage `json:"revision"`
}
type Request struct {
	NavigationTarget *NavigationTarget `json:"navigation_target,omitempty"`
	ImportIdentity   string            `json:"import_identity,omitempty"`
	CreateStations   []string          `json:"create_stations,omitempty"`
	Bundle           Bundle            `json:"bundle"`
	ScreenTargets    map[string]Target `json:"screen_targets"`
	VariableTargets  map[string]Target `json:"variable_targets"`
	StationMap       map[string]string `json:"station_map"`
	SourceMap        map[string]string `json:"source_map"`
	PreviewToken     string            `json:"preview_token,omitempty"`
}
type Screen struct {
	Key      string           `json:"key"`
	Document process.Document `json:"document"`
}
type Variable struct {
	Key        string             `json:"key"`
	Definition points.CreateInput `json:"definition"`
}
type Binding struct {
	ScreenKey   string             `json:"screen_key"`
	NodeID      string             `json:"node_id"`
	Property    string             `json:"property"`
	VariableKey string             `json:"variable_key"`
	Operation   string             `json:"operation"`
	Rule        *process.ArrowRule `json:"rule,omitempty"`
}
type Item struct {
	Kind       string           `json:"kind"`
	Key        string           `json:"key"`
	Status     string           `json:"status"`
	Message    string           `json:"message,omitempty"`
	Before     any              `json:"before,omitempty"`
	After      any              `json:"after,omitempty"`
	Candidates []MatchCandidate `json:"candidates,omitempty"`
}
type Result struct {
	RetryRequest *Request `json:"retry_request,omitempty"`
	PreviewToken string   `json:"preview_token"`
	Items        []Item   `json:"items"`
	Remaining    []Item   `json:"remaining"`
}
type Service struct {
	Navigation *navigation.Service
	Stations   *stations.Service
	Points     *points.Service
	Screens    *process.Service
	Sources    func() []map[string]string
	mu         sync.Mutex
}

func New(p *points.Service, s *process.Service) *Service { return &Service{Points: p, Screens: s} }
func digest(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func allowed(ctx context.Context) bool {
	a, ok := authorization.FromContext(ctx)
	return !ok || a.Active() && a.Grants.Develop()
}
func stationAllowed(ctx context.Context, s string) bool {
	a, ok := authorization.FromContext(ctx)
	return !ok || a.Active() && a.Station(s)
}
func revString(t Target) string { var s string; _ = json.Unmarshal(t.Revision, &s); return s }
func revNumber(t Target) int64  { var n int64; _ = json.Unmarshal(t.Revision, &n); return n }
func input(p points.Definition) points.CreateInput {
	b, _ := json.Marshal(p)
	var in points.CreateInput
	_ = json.Unmarshal(b, &in)
	return in
}
func (s *Service) Catalog(ctx context.Context) (any, error) {
	if !allowed(ctx) {
		return nil, authorization.ErrDenied
	}
	v := []map[string]any{}
	for _, p := range s.Points.List() {
		if stationAllowed(ctx, p.Station) {
			v = append(v, map[string]any{"id": p.ID, "name": p.Name, "station": p.Station, "revision": points.Revision(p), "definition": input(p)})
		}
	}
	screens, e := s.Screens.VisibleList(ctx, "", true)
	if e != nil {
		return nil, e
	}
	sources := []map[string]string{}
	if s.Sources != nil {
		sources = s.Sources()
	}
	catalog := map[string]any{"variables": v, "screens": screens, "sources": sources}
	if s.Navigation != nil {
		c, err := s.Navigation.Get()
		if err != nil {
			return nil, err
		}
		catalog["navigation"] = c
	}
	return catalog, nil
}

// Preview and Commit use the same planner. Commit rechecks every public service
// boundary; successful earlier items are reported even when later writes fail.
func (s *Service) Preview(ctx context.Context, r Request) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.run(ctx, r, false)
}
func (s *Service) Commit(ctx context.Context, r Request) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.PreviewToken == "" {
		return Result{}, fmt.Errorf("preview token required")
	}
	preview, e := s.run(ctx, r, false)
	if e != nil {
		return preview, e
	}
	for _, it := range preview.Items {
		if it.Kind == "navigation" && (it.Status == "error" || it.Status == "unresolved" || it.Status == "failed") {
			return preview, fmt.Errorf("navigation plan blocked; preview again")
		}
	}
	if preview.PreviewToken != r.PreviewToken {
		allUnchanged := len(preview.Items) > 0
		for _, target := range r.VariableTargets {
			if target.Mode == "match_existing" {
				allUnchanged = false
				break
			}
		}
		for _, it := range preview.Items {
			if it.Status != "unchanged" {
				allUnchanged = false
			}
		}
		if allUnchanged {
			return preview, nil
		}
		return preview, fmt.Errorf("preview changed; preview again")
	}
	return s.run(ctx, r, true)
}
func (s *Service) run(ctx context.Context, r Request, commit bool) (Result, error) {
	out := Result{Items: []Item{}, Remaining: []Item{}}
	if !allowed(ctx) {
		return out, authorization.ErrDenied
	}
	if e := r.Bundle.Validate(); e != nil {
		return out, e
	}
	for _, raw := range r.Bundle.Screens {
		var v Screen
		if e := json.Unmarshal(raw, &v); e != nil {
			return out, e
		}
	}
	ordered, e := orderVariables(r.Bundle.Variables)
	if e != nil {
		return out, e
	}
	r.Bundle.Variables = ordered
	for _, raw := range r.Bundle.Variables {
		var v Variable
		if e := json.Unmarshal(raw, &v); e != nil {
			return out, e
		}
	}
	for _, raw := range r.Bundle.Bindings {
		var v Binding
		if e := json.Unmarshal(raw, &v); e != nil {
			return out, e
		}
	}
	sourceIDs := map[string]bool{}
	if s.Sources != nil {
		for _, src := range s.Sources() {
			sourceIDs[src["id"]] = true
		}
	}
	rows := s.Points.List()
	index := map[string]points.Definition{}
	for _, p := range rows {
		index[p.ID] = p
	}
	resolved := map[string]string{}
	seen := map[string]bool{}
	add := func(kind, key, status, msg string, before, after any) {
		it := Item{Kind: kind, Key: key, Status: status, Message: msg, Before: before, After: after}
		out.Items = append(out.Items, it)
		if status == "error" || status == "unresolved" || status == "failed" {
			out.Remaining = append(out.Remaining, it)
		}
	}
	stationNames := map[string]bool{"": true}
	if s.Stations != nil {
		list, e := s.Stations.List()
		if e != nil {
			return out, e
		}
		for _, st := range list {
			stationNames[st.Name] = true
		}
	}
	for _, name := range r.CreateStations {
		if name == "" {
			add("station", name, "error", "empty station name", nil, nil)
			continue
		}
		if stationNames[name] {
			add("station", name, "unchanged", "station exists", nil, name)
			continue
		}
		if !allowed(ctx) {
			add("station", name, "error", "permission denied", nil, nil)
			continue
		}
		if commit {
			if s.Stations == nil {
				add("station", name, "failed", "station service unavailable", nil, nil)
				continue
			}
			if _, e := s.Stations.Create(name); e != nil {
				add("station", name, "failed", e.Error(), nil, nil)
				continue
			}
		}
		stationNames[name] = true
		status := "ready"
		if commit {
			status = "saved"
		}
		add("station", name, status, "", nil, name)
	}
	for key, t := range r.VariableTargets {
		if p, ok := index[t.ID]; ok && stationAllowed(ctx, p.Station) && t.Mode == "reference" {
			resolved[key] = t.ID
		}
	}
	for _, raw := range r.Bundle.Variables {
		var v Variable
		if e := json.Unmarshal(raw, &v); e != nil {
			return out, e
		}
		if v.Key == "" || seen["v/"+v.Key] {
			add("variable", v.Key, "error", "duplicate or empty key", nil, nil)
			continue
		}
		seen["v/"+v.Key] = true
		t, explicit := r.VariableTargets[v.Key]
		in := v.Definition
		if t.Mode == "match_existing" {
			var fields struct {
				Definition map[string]json.RawMessage `json:"definition"`
			}
			_ = json.Unmarshal(raw, &fields)
			offsetRaw, offsetProvided := fields.Definition["offset"]
			it, id := s.matchExisting(ctx, v, r.SourceMap, rows, sourceIDs, offsetProvided && string(offsetRaw) != "null")
			out.Items = append(out.Items, it)
			if id != "" {
				resolved[v.Key] = id
			} else {
				out.Remaining = append(out.Remaining, it)
			}
			continue
		}
		if t.Mode == "reference" {
			if id := resolved[v.Key]; id != "" {
				add("variable", v.Key, "unchanged", "explicit reference", nil, index[id])
				continue
			}
			add("variable", v.Key, "unresolved", "reference not accessible", nil, nil)
			continue
		}
		st, ok := r.StationMap[in.Station]
		if !ok {
			add("variable", v.Key, "unresolved", "station mapping required", nil, nil)
			continue
		}
		if s.Stations != nil && !stationNames[st] {
			add("variable", v.Key, "unresolved", "target station missing; explicitly create station", nil, nil)
			continue
		}
		in.Station = st
		if in.SourceID != "" {
			mapped, ok := r.SourceMap[in.SourceID]
			if !ok {
				add("variable", v.Key, "unresolved", "source mapping required", nil, nil)
				continue
			}
			if s.Sources != nil && !sourceIDs[mapped] {
				add("variable", v.Key, "error", "source target not found", nil, nil)
				continue
			}
			in.SourceID = mapped
		}
		if in.WriteSourceID != "" {
			mapped, ok := r.SourceMap[in.WriteSourceID]
			if !ok {
				add("variable", v.Key, "unresolved", "write source mapping required", nil, nil)
				continue
			}
			if s.Sources != nil && !sourceIDs[mapped] {
				add("variable", v.Key, "error", "write source target not found", nil, nil)
				continue
			}
			in.WriteSourceID = mapped
		}
		missing := false
		for i, k := range in.Inputs {
			if id := resolved[k]; id != "" {
				in.Inputs[i] = id
			} else {
				missing = true
			}
		}
		if missing {
			add("variable", v.Key, "unresolved", "input variable mapping required (dependencies must precede dependent)", nil, nil)
			continue
		}
		if in.DataType == "" || in.SourceType == "" {
			add("variable", v.Key, "unresolved", "data type/source type is not confirmed", nil, nil)
			continue
		}
		p, e := points.Normalize(in)
		if e != nil || !stationAllowed(ctx, in.Station) {
			add("variable", v.Key, "error", "invalid definition or station permission", nil, nil)
			continue
		}
		// Only a full source identity may resolve automatically. Names never resolve.
		candidates := []points.Definition{}
		if p.SourceID != "" && p.Topic != "" && p.SourcePath != "" {
			for _, q := range rows {
				if q.SourceID == p.SourceID && q.Topic == p.Topic && q.SourcePath == p.SourcePath {
					candidates = append(candidates, q)
				}
			}
		}
		if !explicit {
			if len(candidates) == 1 && stationAllowed(ctx, candidates[0].Station) {
				if candidates[0].DataType != p.DataType || candidates[0].Unit != p.Unit {
					add("variable", v.Key, "error", "source identity type/unit conflict", candidates[0], p)
					continue
				}
				resolved[v.Key] = candidates[0].ID
				add("variable", v.Key, "unchanged", "unique source identity reference", nil, candidates[0])
				continue
			}
			add("variable", v.Key, "unresolved", "explicit create/update/reference target required; candidates="+fmt.Sprint(len(candidates)), nil, nil)
			continue
		}
		switch t.Mode {
		case "create":
			stableID := t.ID
			if stableID == "" {
				stableID = "pt_imp_" + digest([]any{r.ImportIdentity, v.Key, in.Station, in.SourceID, in.Topic, in.SourcePath})[:24]
			}
			p.ID = stableID
			if prev, exists := index[stableID]; exists {
				if reflect.DeepEqual(prev, p) {
					resolved[v.Key] = stableID
					add("variable", v.Key, "unchanged", "identical import identity", prev, p)
					continue
				}
				add("variable", v.Key, "error", "import identity conflict", prev, p)
				continue
			}
			if len(candidates) > 0 {
				add("variable", v.Key, "error", "source identity already exists; choose reference", nil, nil)
				continue
			}
			for _, q := range rows {
				if q.Station == p.Station && q.Name == p.Name {
					e = fmt.Errorf("name already exists; choose explicit target")
				}
			}
			if e != nil {
				add("variable", v.Key, "error", e.Error(), nil, nil)
				continue
			}
			p.ID = stableID
			if commit {
				if !allowed(ctx) {
					add("variable", v.Key, "failed", "permission revoked", nil, nil)
					continue
				}
				p, _, e = s.Points.CreateIdentity(stableID, in)
				if e != nil {
					add("variable", v.Key, "failed", e.Error(), nil, nil)
					continue
				}
			}
			resolved[v.Key] = p.ID
			index[p.ID] = p
			rows = append(rows, p)
			status := "ready"
			if commit {
				status = "saved"
			}
			add("variable", v.Key, status, "configuration only; not activated", nil, p)
		case "update":
			old, ok := index[t.ID]
			if !ok || !stationAllowed(ctx, old.Station) || old.Station != p.Station {
				add("variable", v.Key, "error", "target missing or ownership change", nil, nil)
				continue
			}
			p.ID = old.ID
			if reflect.DeepEqual(p, old) {
				resolved[v.Key] = old.ID
				add("variable", v.Key, "unchanged", "identical definition", old, p)
				continue
			}
			if revString(t) != points.Revision(old) {
				add("variable", v.Key, "error", "revision conflict", old, p)
				continue
			}
			if commit {
				if !allowed(ctx) {
					add("variable", v.Key, "failed", "permission revoked", old, p)
					continue
				}
				p, e = s.Points.UpdateRevision(old.ID, revString(t), in)
				if e != nil {
					add("variable", v.Key, "failed", e.Error(), old, p)
					continue
				}
			}
			resolved[v.Key] = p.ID
			index[p.ID] = p
			status := "ready"
			if commit {
				status = "saved"
			}
			add("variable", v.Key, status, "", old, p)
		default:
			add("variable", v.Key, "unresolved", "explicit create/update/reference required", nil, nil)
		}
	}
	docs := map[string]process.Document{}
	oldDocs := map[string]process.Document{}
	docKeys := []string{}
	invalid := map[string]string{}
	for _, raw := range r.Bundle.Screens {
		var v Screen
		if e := json.Unmarshal(raw, &v); e != nil {
			return out, e
		}
		if v.Key == "" || seen["s/"+v.Key] {
			add("screen", v.Key, "error", "duplicate or empty key", nil, nil)
			continue
		}
		seen["s/"+v.Key] = true
		t, ok := r.ScreenTargets[v.Key]
		if t.Mode == "update_imported" {
			expected := "sc_imp_" + digest([]any{r.ImportIdentity, v.Key, r.StationMap[v.Document.Station]})[:24]
			if strings.TrimSpace(r.ImportIdentity) == "" || (t.ID != "" && t.ID != expected) {
				add("screen", v.Key, "error", "import identity or exact imported target required", nil, nil)
				continue
			}
			t.ID = expected
		}
		if t.Mode == "create" && t.ID == "" {
			t.ID = "sc_imp_" + digest([]any{r.ImportIdentity, v.Key, r.StationMap[v.Document.Station]})[:24]
		}
		if !ok || t.ID == "" || (t.Mode != "create" && t.Mode != "update" && t.Mode != "update_imported") {
			add("screen", v.Key, "unresolved", "explicit screen target required", nil, nil)
			continue
		}
		d := v.Document
		stripBindings(&d)
		for i := range d.Nodes {
			if d.Nodes[i].Points == nil {
				d.Nodes[i].Points = []process.Position{}
			}
		}
		if d.Assets == nil {
			d.Assets = map[string]process.Asset{}
		}
		d.ID = t.ID
		d.Revision = revNumber(t)
		st, ok := r.StationMap[d.Station]
		if !ok {
			add("screen", v.Key, "unresolved", "station mapping required", nil, nil)
			continue
		}
		if s.Stations != nil && !stationNames[st] {
			add("screen", v.Key, "unresolved", "target station missing; explicitly create station", nil, nil)
			continue
		}
		d.Station = st
		if !stationAllowed(ctx, d.Station) {
			add("screen", v.Key, "error", "station permission denied", nil, nil)
			continue
		}
		old, e := s.Screens.Get(t.ID)
		if t.Mode == "update_imported" {
			if e != nil {
				add("screen", v.Key, "error", "exact imported screen missing; no automatic create", nil, d)
				continue
			}
			oldKind, newKind := old.Kind, d.Kind
			if oldKind == "" {
				oldKind = "process"
			}
			if newKind == "" {
				newKind = "process"
			}
			if old.Station != d.Station || oldKind != newKind {
				add("screen", v.Key, "error", "imported screen station or kind conflict", old, d)
				continue
			}
			d.Revision = old.Revision
		}
		if t.Mode == "create" && e == nil {
			d.Revision = old.Revision
		}
		if t.Mode == "update" && e != nil {
			invalid[v.Key] = "update target missing"
		}
		if e == nil {
			oldDocs[v.Key] = old
			for _, n := range d.Nodes {
				for _, prev := range old.Nodes {
					if prev.ID == n.ID && prev.Kind != n.Kind && (prev.PointID != "" || prev.ArrowVisibleRule != nil || prev.ArrowMotionRule != nil) {
						invalid[v.Key] = "bound element kind changed; explicit binding review required"
					}
				}
			}
			preserveBindings(&d, old)
		}
		docs[v.Key] = d
		docKeys = append(docKeys, v.Key)
	}
	// Binding-only imports load existing target documents explicitly.
	for _, raw := range r.Bundle.Bindings {
		var b Binding
		if e := json.Unmarshal(raw, &b); e != nil {
			return out, e
		}
		key := b.ScreenKey + "/" + b.NodeID + "/" + b.Property
		if seen["b/"+key] {
			add("binding", key, "error", "duplicate binding", nil, nil)
			invalid[b.ScreenKey] = "duplicate binding"
			continue
		}
		seen["b/"+key] = true
		d, ok := docs[b.ScreenKey]
		if !ok {
			t, exists := r.ScreenTargets[b.ScreenKey]
			if !exists || t.Mode != "update" {
				add("binding", key, "unresolved", "screen update target required", nil, nil)
				continue
			}
			var e error
			d, e = s.Screens.Get(t.ID)
			if e != nil || !stationAllowed(ctx, d.Station) {
				add("binding", key, "error", "screen missing or denied", nil, nil)
				continue
			}
			oldDocs[b.ScreenKey] = d
			data, _ := json.Marshal(d)
			_ = json.Unmarshal(data, &d)
			d.Revision = revNumber(t)
			docs[b.ScreenKey] = d
			docKeys = append(docKeys, b.ScreenKey)
		}
		op := b.Operation
		if op == "" {
			op = "keep"
		}
		if op == "keep" {
			add("binding", key, "unchanged", "kept", nil, nil)
			continue
		}
		if op != "set" && op != "clear" {
			invalid[b.ScreenKey] = "invalid binding operation"
			add("binding", key, "error", "invalid operation", nil, nil)
			continue
		}
		id := ""
		if op == "set" && b.Property == "point_id" {
			id = resolved[b.VariableKey]
			if id == "" {
				add("binding", key, "unresolved", "variable target required", nil, nil)
				continue
			}
		}
		bindingUnresolved := false
		found := false
		for i := range d.Nodes {
			n := &d.Nodes[i]
			if n.ID != b.NodeID {
				continue
			}
			found = true
			if n.Kind == "text" || n.Kind == "image" {
				invalid[b.ScreenKey] = "element cannot bind"
				break
			}
			switch b.Property {
			case "point_id":
				n.PointID = id
			case "arrow_visible_rule", "arrow_motion_rule":
				var rule *process.ArrowRule
				existing := n.ArrowVisibleRule
				if b.Property == "arrow_motion_rule" {
					existing = n.ArrowMotionRule
				}
				if op == "clear" && existing != nil {
					data, _ := json.Marshal(existing)
					_ = json.Unmarshal(data, &rule)
					for j := range rule.Conditions {
						rule.Conditions[j].PointID = ""
					}
				}
				if op == "set" {
					if b.Rule == nil {
						invalid[b.ScreenKey] = "rule required"
						break
					}
					if !sameRuleSemantics(existing, b.Rule) {
						invalid[b.ScreenKey] = "condition semantics changed; refresh binding"
						break
					}
					raw, _ := json.Marshal(b.Rule)
					_ = json.Unmarshal(raw, &rule)
					for j := range rule.Conditions {
						k := rule.Conditions[j].PointID
						rule.Conditions[j].PointID = resolved[k]
						if k != "" && rule.Conditions[j].PointID == "" {
							bindingUnresolved = true
							rule = cloneRule(existing)
							add("binding", key, "unresolved", "rule variable unresolved; existing binding kept", nil, b)
							break
						}
					}
				}
				if b.Property == "arrow_visible_rule" {
					n.ArrowVisibleRule = rule
				} else {
					n.ArrowMotionRule = rule
				}
			default:
				invalid[b.ScreenKey] = "invalid property"
			}
		}
		if !found {
			invalid[b.ScreenKey] = "node missing"
		}
		docs[b.ScreenKey] = d
		if msg := invalid[b.ScreenKey]; msg != "" {
			add("binding", key, "error", msg, nil, nil)
		} else if !bindingUnresolved {
			add("binding", key, "ready", "saved with screen", nil, b)
		}
	}
	for _, key := range docKeys {
		d := docs[key]
		old, exists := oldDocs[key]
		if msg := invalid[key]; msg != "" {
			add("screen", key, "error", msg, old, d)
			continue
		}
		if exists {
			a, b := old, d
			a.Revision = 0
			b.Revision = 0
			if reflect.DeepEqual(a, b) {
				add("screen", key, "unchanged", "identical document", old, d)
				continue
			}
			if d.Revision != old.Revision {
				add("screen", key, "error", "revision conflict", old, d)
				continue
			}
		}
		if d.TemplateID != "" {
			d.Bindings = instanceBindings(d)
			d.Nodes = []process.Node{}
			d.Assets = map[string]process.Asset{}
		}
		for _, n := range d.Nodes {
			ids := []string{n.PointID}
			for _, rule := range []*process.ArrowRule{n.ArrowVisibleRule, n.ArrowMotionRule} {
				if rule != nil {
					for _, c := range rule.Conditions {
						ids = append(ids, c.PointID)
					}
				}
			}
			for _, id := range ids {
				if id != "" {
					p, ok := index[id]
					if !ok || !stationAllowed(ctx, p.Station) {
						invalid[key] = "binding variable missing or denied"
					}
				}
			}
		}
		if invalid[key] != "" {
			add("screen", key, "error", invalid[key], old, d)
			continue
		}
		if e := process.Validate(d); e != nil {
			add("screen", key, "error", e.Error(), old, d)
			continue
		}
		status := "ready"
		if commit {
			if !allowed(ctx) || !stationAllowed(ctx, d.Station) {
				add("screen", key, "failed", "permission revoked", old, d)
				continue
			}
			saved, e := s.Screens.SaveAuthorizedPoints(d, func(id string) (string, bool) {
				p, ok := index[id]
				return p.Station, ok && stationAllowed(ctx, p.Station)
			})
			if e != nil {
				add("screen", key, "failed", e.Error(), old, d)
				continue
			}
			d = saved
			status = "saved"
		}
		add("screen", key, status, "", old, d)
	}
	if err := s.planNavigation(ctx, r, &out, docs, commit); err != nil {
		return out, err
	}
	// Token binds request, authoritative before/after plan and actor policy.
	tokenReq := r
	tokenReq.PreviewToken = ""
	actor, _ := authorization.FromContext(ctx)
	if commit {
		screenStatus := map[string]string{}
		for _, it := range out.Items {
			if it.Kind == "screen" {
				screenStatus[it.Key] = it.Status
			}
		}
		for i := range out.Items {
			it := &out.Items[i]
			if it.Kind == "binding" && it.Status == "ready" {
				key := strings.SplitN(it.Key, "/", 2)[0]
				status := screenStatus[key]
				if status == "saved" || status == "unchanged" {
					it.Status = status
				} else {
					it.Status = "failed"
					it.Message = "screen save did not succeed"
				}
			}
		}
		out.Remaining = nil
		for _, it := range out.Items {
			if it.Status == "failed" || it.Status == "error" || it.Status == "unresolved" {
				out.Remaining = append(out.Remaining, it)
			}
		}
	}
	out.RetryRequest = &r
	out.PreviewToken = digest([]any{tokenReq, out.Items, actor.ID, actor.Version})
	return out, nil
}

type ExportRequest struct {
	ScreenIDs    []string `json:"screen_ids"`
	VariableIDs  []string `json:"variable_ids"`
	Format       string   `json:"format"`
	Kind         string   `json:"kind"`
	ExpandShared bool     `json:"expand_shared"`
}

func (s *Service) Export(ctx context.Context, r ExportRequest) (Bundle, error) {
	b := Bundle{Format: Format, Version: 1, Screens: []json.RawMessage{}, Variables: []json.RawMessage{}, Bindings: []json.RawMessage{}}
	if !allowed(ctx) {
		return b, authorization.ErrDenied
	}
	a, secured := authorization.FromContext(ctx)
	if secured && !a.Grants.Export {
		return b, authorization.ErrDenied
	}
	pointKeys := map[string]string{}
	for _, p := range s.Points.List() {
		pointKeys[p.ID] = "var_" + p.ID
	}
	vars := map[string]bool{}
	for _, id := range r.VariableIDs {
		vars[id] = true
	}
	for _, id := range r.ScreenIDs {
		d, e := s.Screens.VisibleDocument(ctx, id, func(id string) bool { return true })
		if e != nil {
			return b, e
		}
		if d.Kind == "gis" {
			return b, fmt.Errorf("GIS transfer is outside process format")
		}
		if d.TemplateID != "" && !r.ExpandShared {
			return b, fmt.Errorf("shared instance export requires expand_shared=true (independent copy)")
		}
		d.TemplateID = ""
		d.TemplateRevision = 0
		d.Bindings = nil
		key := "screen_" + id
		for i := range d.Nodes {
			n := &d.Nodes[i]
			if n.PointID != "" {
				vars[n.PointID] = true
				v := Binding{ScreenKey: key, NodeID: n.ID, Property: "point_id", VariableKey: pointKeys[n.PointID], Operation: "set"}
				raw, _ := json.Marshal(v)
				b.Bindings = append(b.Bindings, raw)
				n.PointID = ""
			}
			for _, pair := range []struct {
				prop string
				rule **process.ArrowRule
			}{{"arrow_visible_rule", &n.ArrowVisibleRule}, {"arrow_motion_rule", &n.ArrowMotionRule}} {
				if *pair.rule == nil {
					continue
				}
				raw, _ := json.Marshal(*pair.rule)
				var rule process.ArrowRule
				_ = json.Unmarshal(raw, &rule)
				for j := range rule.Conditions {
					pid := rule.Conditions[j].PointID
					if pid != "" {
						vars[pid] = true
						rule.Conditions[j].PointID = pointKeys[pid]
					}
				}
				v := Binding{ScreenKey: key, NodeID: n.ID, Property: pair.prop, Operation: "set", Rule: &rule}
				raw, _ = json.Marshal(v)
				b.Bindings = append(b.Bindings, raw)
				for j := range (*pair.rule).Conditions {
					(*pair.rule).Conditions[j].PointID = ""
				}
			}
		}
		d.ID = ""
		d.Revision = 0
		raw, _ := json.Marshal(Screen{key, d})
		b.Screens = append(b.Screens, raw)
	}
	all := s.Points.List()
	known := map[string]bool{}
	for _, p := range all {
		known[p.ID] = true
	}
	for id := range vars {
		if id == "" || !known[id] {
			return b, fmt.Errorf("referenced variable %s is missing; resolve before export", id)
		}
	}
	changed := true
	for changed {
		changed = false
		for _, p := range all {
			if vars[p.ID] {
				for _, id := range p.Inputs {
					if !vars[id] {
						vars[id] = true
						changed = true
					}
				}
			}
		}
	}
	for id := range vars {
		if id == "" || !known[id] {
			return b, fmt.Errorf("referenced dependency %s is missing", id)
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].ID < all[j].ID })
	for _, p := range all {
		if !vars[p.ID] {
			continue
		}
		if !stationAllowed(ctx, p.Station) {
			return b, authorization.ErrDenied
		}
		in := input(p)
		for i, id := range in.Inputs {
			in.Inputs[i] = pointKeys[id]
		}
		raw, _ := json.Marshal(Variable{pointKeys[p.ID], in})
		b.Variables = append(b.Variables, raw)
	}
	ordered, e := orderVariables(b.Variables)
	if e != nil {
		return b, e
	}
	b.Variables = ordered
	switch strings.TrimSpace(r.Kind) {
	case "screens":
		b.Variables = nil
		b.Bindings = nil
	case "variables":
		b.Screens = nil
		b.Bindings = nil
	case "bindings":
		b.Screens = nil
		b.Variables = nil
	case "bundle", "":
	default:
		return b, fmt.Errorf("invalid export kind")
	}
	return b, nil
}
func orderVariables(raws []json.RawMessage) ([]json.RawMessage, error) {
	index := map[string]Variable{}
	rawIndex := map[string]json.RawMessage{}
	keys := []string{}
	for _, raw := range raws {
		var v Variable
		if e := json.Unmarshal(raw, &v); e != nil {
			return nil, e
		}
		if _, ok := index[v.Key]; ok {
			return nil, fmt.Errorf("duplicate variable key")
		}
		index[v.Key] = v
		rawIndex[v.Key] = raw
		keys = append(keys, v.Key)
	}
	out := []json.RawMessage{}
	state := map[string]int{}
	var visit func(string) error
	visit = func(k string) error {
		if state[k] == 1 {
			return fmt.Errorf("cyclic portable variable dependency")
		}
		if state[k] == 2 {
			return nil
		}
		v, ok := index[k]
		if !ok {
			return nil
		}
		state[k] = 1
		for _, input := range v.Definition.Inputs {
			if e := visit(input); e != nil {
				return e
			}
		}
		state[k] = 2
		out = append(out, rawIndex[k])
		return nil
	}
	for _, k := range keys {
		if e := visit(k); e != nil {
			return nil, e
		}
	}
	return out, nil
}

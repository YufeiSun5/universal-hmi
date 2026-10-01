package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"github.com/expr-lang/expr"
	"github.com/expr-lang/expr/vm"
	"math"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Policy struct {
	Enabled       bool     `json:"enabled"`
	IntervalMS    int      `json:"interval_ms"`
	ChangedOnly   bool     `json:"changed_only"`
	RetentionDays int      `json:"retention_days"`
	PointIDs      []string `json:"point_ids"`
}
type Condition struct {
	PointID string  `json:"point_id"`
	Op      string  `json:"op"`
	Value   float64 `json:"value"`
}
type Action struct {
	Type    string  `json:"type"`
	PointID string  `json:"point_id"`
	Value   float64 `json:"value"`
}
type Rule struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Enabled    bool        `json:"enabled"`
	Logic      string      `json:"logic"`
	Conditions []Condition `json:"conditions"`
	HoldMS     int         `json:"hold_ms"`
	CooldownMS int         `json:"cooldown_ms"`
	Trigger    string      `json:"trigger"`
	Actions    []Action    `json:"actions"`
}
type ruleState struct {
	Since  time.Time
	Active bool
	Last   time.Time
}
type Write struct {
	CommandID string  `json:"command_id"`
	PointID   string  `json:"point_id"`
	Value     float64 `json:"value"`
	Version   string  `json:"version"`
}
type Result struct {
	CommandID string    `json:"command_id"`
	PointID   string    `json:"point_id"`
	State     string    `json:"state"`
	Message   string    `json:"message"`
	At        time.Time `json:"at"`
	Value     float64   `json:"value"`
	Version   string    `json:"version"`
}
type Engine struct {
	mu           sync.Mutex
	Points       *points.Service
	Store        *storage.Store
	active       []points.Definition
	programs     map[string]*vm.Program
	order        []string
	live         map[string]storage.Sample
	version      string
	sources      []acquisition.Source
	connections  map[string]*acquisition.Connection
	sourceState  map[string]string
	rules        []Rule
	ruleStates   map[string]*ruleState
	policy       Policy
	lastSave     time.Time
	lastValues   map[string]string
	lastPrune    time.Time
	queue        chan []acquisition.Raw
	dropped      atomic.Int64
	stop         chan struct{}
	done         chan struct{}
	demo         bool
	demoStart    time.Time
	storageError string
}

func New(ps *points.Service, db *storage.Store) (*Engine, error) {
	e := &Engine{Points: ps, Store: db, live: map[string]storage.Sample{}, connections: map[string]*acquisition.Connection{}, sourceState: map[string]string{}, ruleStates: map[string]*ruleState{}, lastValues: map[string]string{}, queue: make(chan []acquisition.Raw, 128), stop: make(chan struct{}), done: make(chan struct{}), policy: Policy{IntervalMS: 1000, RetentionDays: 30}, sources: []acquisition.Source{}, rules: []Rule{}}
	for key, v := range map[string]any{"sources": &e.sources, "rules": &e.rules, "policy": &e.policy} {
		if err := db.LoadConfig(key, v); err != nil {
			return nil, err
		}
	}
	// Restart never automatically reconnects sources or resumes physical event actions.
	for i := range e.rules {
		e.rules[i].Enabled = false
	}
	if _, err := e.Apply(); err != nil {
		return nil, err
	}
	go e.loop()
	return e, nil
}
func (e *Engine) Close() {
	close(e.stop)
	<-e.done
	e.mu.Lock()
	connections := e.connections
	e.connections = map[string]*acquisition.Connection{}
	e.mu.Unlock()
	for _, c := range connections {
		c.Close()
	}
}
func (e *Engine) Submit(rows []acquisition.Raw) {
	select {
	case e.queue <- rows:
	default:
		e.dropped.Add(int64(len(rows)))
	}
}
func (e *Engine) Apply() (string, error) {
	rows := e.Points.List()
	data, _ := json.Marshal(rows)
	sum := sha256.Sum256(data)
	version := hex.EncodeToString(sum[:8])
	programs := map[string]*vm.Program{}
	index := map[string]points.Definition{}
	for _, p := range rows {
		index[p.ID] = p
	}
	seen := map[string]int{}
	order := []string{}
	var visit func(string) error
	visit = func(id string) error {
		if seen[id] == 1 {
			return fmt.Errorf("virtual dependency cycle")
		}
		if seen[id] == 2 {
			return nil
		}
		p, ok := index[id]
		if !ok {
			return fmt.Errorf("missing input %s", id)
		}
		seen[id] = 1
		if p.SourceType == "virtual" {
			if p.Expression == "" {
				seen[id] = 2
				return nil
			}
			if !regexp.MustCompile(`^[0-9v\s+*/%().\[\]<>=!?:&|\-]+$`).MatchString(p.Expression) || strings.Contains(p.Expression, "..") {
				return fmt.Errorf("formula supports bounded arithmetic on v[index] only")
			}
			for _, dep := range p.Inputs {
				if err := visit(dep); err != nil {
					return err
				}
			}
			program, err := expr.Compile(p.Expression, expr.Env(map[string]any{"v": []float64{}}), expr.AsFloat64(), expr.MaxNodes(256))
			if err != nil {
				return fmt.Errorf("%s: %w", p.Name, err)
			}
			programs[id] = program
			order = append(order, id)
		}
		seen[id] = 2
		return nil
	}
	for _, p := range rows {
		if err := visit(p.ID); err != nil {
			return "", err
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.version != version {
		e.live = map[string]storage.Sample{}
		e.lastValues = map[string]string{}
		e.ruleStates = map[string]*ruleState{}
	}
	e.active = rows
	e.programs = programs
	e.order = order
	e.version = version
	return version, nil
}
func (e *Engine) Snapshot() map[string]any {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	values := make([]storage.Sample, 0, len(e.active))
	for _, p := range e.active {
		r, ok := e.live[p.ID]
		if !ok {
			r = storage.Sample{PointID: p.ID, Station: p.Station, Name: p.Name, Unit: p.Unit, Quality: "missing", Version: e.version}
		} else if now.Sub(r.SourceTime) > time.Duration(p.StaleMS)*time.Millisecond {
			r.Quality = "stale"
		}
		values = append(values, r)
	}
	states := map[string]string{}
	for k, v := range e.sourceState {
		states[k] = v
	}
	return map[string]any{"version": e.version, "values": values, "sources": e.sources, "source_states": states, "rules": e.rules, "policy": e.policy, "storage_error": e.storageError, "dropped": e.dropped.Load(), "demo": e.demo}
}
func (e *Engine) Policy(p Policy) error {
	if p.IntervalMS < 200 || p.IntervalMS > 3600000 || p.RetentionDays < 1 || p.RetentionDays > 3650 {
		return fmt.Errorf("invalid storage policy")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.Store.SaveConfig("policy", p); err != nil {
		return err
	}
	e.policy = p
	return nil
}
func (e *Engine) Sources(rows []acquisition.Source) error {
	if len(rows) > 32 {
		return fmt.Errorf("source limit")
	}
	ids := map[string]bool{}
	for _, s := range rows {
		u, err := url.Parse(s.Broker)
		if err != nil || u.Host == "" || (u.Scheme != "tcp" && u.Scheme != "ssl") || u.User != nil || s.ID == "" || s.Topic == "" || ids[s.ID] || (s.Protocol != "generic" && s.Protocol != "kep" && s.Protocol != "kingio") {
			return fmt.Errorf("invalid source")
		}
		ids[s.ID] = true
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range rows {
		if e.connections[s.ID] != nil {
			return fmt.Errorf("disconnect before editing sources")
		}
	}
	for id := range e.connections {
		if !ids[id] {
			return fmt.Errorf("disconnect before deleting source")
		}
	}
	if err := e.Store.SaveConfig("sources", rows); err != nil {
		return err
	}
	e.sources = rows
	return nil
}
func (e *Engine) Connect(id string) error {
	e.mu.Lock()
	var source acquisition.Source
	for _, s := range e.sources {
		if s.ID == id {
			source = s
		}
	}
	if source.ID == "" {
		e.mu.Unlock()
		return fmt.Errorf("source not found")
	}
	if e.connections[id] != nil || e.sourceState[id] == "connecting" {
		e.mu.Unlock()
		return fmt.Errorf("already connected or connecting")
	}
	e.sourceState[id] = "connecting"
	e.mu.Unlock()
	c, err := acquisition.Connect(source, e.Submit, func(state string) { e.mu.Lock(); e.sourceState[id] = state; e.mu.Unlock() })
	e.mu.Lock()
	defer e.mu.Unlock()
	if err != nil {
		e.sourceState[id] = "failed: " + err.Error()
		return err
	}
	e.connections[id] = c
	return nil
}
func (e *Engine) Disconnect(id string) {
	e.mu.Lock()
	c := e.connections[id]
	delete(e.connections, id)
	e.sourceState[id] = "disconnected"
	e.mu.Unlock()
	if c != nil {
		c.Close()
	}
}
func numeric(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, !math.IsNaN(x) && !math.IsInf(x, 0)
	case int:
		return float64(x), true
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	case string:
		n, err := strconv.ParseFloat(x, 64)
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
	}
	return 0, false
}
func (e *Engine) ingest(p points.Definition, raw any, q string, source, now time.Time) {
	if source.IsZero() || source.After(now.Add(5*time.Second)) {
		q = "bad"
	}
	if old, ok := e.live[p.ID]; ok && !old.SourceTime.After(now.Add(5*time.Second)) && source.Before(old.SourceTime) {
		return
	}
	var value any = raw
	switch p.DataType {
	case "FLOAT", "INT":
		n, ok := numeric(raw)
		if !ok || p.DataType == "INT" && math.Trunc(n) != n {
			q = "bad"
			value = nil
		} else {
			n = n*p.ScaleFactor + p.Offset
			if math.IsNaN(n) || math.IsInf(n, 0) {
				q = "bad"
				value = nil
			} else {
				value = n
			}
		}
	case "BOOL":
		if b, ok := raw.(bool); ok {
			value = b
		} else if n, ok := numeric(raw); ok && (n == 0 || n == 1) {
			value = n == 1
		} else {
			q = "bad"
			value = nil
		}
	case "STRING":
		if _, ok := raw.(string); !ok {
			q = "bad"
			value = nil
		}
	}
	if q != "good" {
		q = "bad"
	}
	e.live[p.ID] = storage.Sample{PointID: p.ID, Station: p.Station, Name: p.Name, Value: value, Raw: raw, Unit: p.Unit, Quality: q, SourceTime: source.UTC(), ReceivedTime: now.UTC(), Version: e.version}
}
func (e *Engine) Manual(id string, value any) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, p := range e.active {
		if p.ID == id {
			if p.SourceType != "manual" {
				return fmt.Errorf("only manual inputs accept samples")
			}
			now := time.Now()
			e.ingest(p, value, "good", now, now)
			return nil
		}
	}
	return fmt.Errorf("point not applied")
}
func (e *Engine) Write(w Write) (Result, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.writeLocked(w)
}
func (e *Engine) writeLocked(w Write) (Result, error) {
	result := Result{CommandID: w.CommandID, PointID: w.PointID, At: time.Now().UTC(), State: "failed", Value: w.Value, Version: w.Version}
	if len(w.CommandID) < 8 || len(w.CommandID) > 128 {
		return result, fmt.Errorf("command ID required")
	}
	var old Result
	if err := e.Store.LoadConfig("command:"+w.CommandID, &old); err != nil {
		return result, err
	}
	if old.CommandID != "" {
		if old.PointID != w.PointID || old.Value != w.Value || old.Version != w.Version {
			return result, fmt.Errorf("command ID reused with different payload")
		}
		return old, nil
	}
	if w.Version != e.version {
		return result, fmt.Errorf("configuration version changed; refresh")
	}
	if math.IsNaN(w.Value) || math.IsInf(w.Value, 0) {
		return result, fmt.Errorf("finite value required")
	}
	var target points.Definition
	for _, p := range e.active {
		if p.ID == w.PointID {
			target = p
		}
	}
	if target.ID == "" || !target.Writable || target.SourceType == "virtual" {
		return result, fmt.Errorf("point is not writable")
	}
	if target.Min != nil && w.Value < *target.Min || target.Max != nil && w.Value > *target.Max {
		return result, fmt.Errorf("outside engineering range")
	}
	raw := (w.Value - target.Offset) / target.ScaleFactor
	if math.IsNaN(raw) || math.IsInf(raw, 0) || target.DataType == "INT" && math.Trunc(raw) != raw || target.DataType == "STRING" || target.DataType == "BOOL" && raw != 0 && raw != 1 {
		return result, fmt.Errorf("value cannot be encoded")
	}
	if target.SourceType == "mqtt" {
		supported := false
		for _, s := range e.sources {
			if s.ID == target.SourceID && s.Protocol == "generic" {
				supported = true
			}
		}
		if !supported {
			return result, fmt.Errorf("physical writes require generic command contract; vendor codec not configured")
		}
	}
	// Persist the intent before any side effect. Interrupted commands remain unknown.
	result.State = "unknown"
	result.Message = "intent persisted; outcome requires reconciliation"
	if err := e.Store.SaveConfig("command:"+w.CommandID, result); err != nil {
		return result, err
	}
	if target.SourceType == "manual" || target.SourceType == "simulator" {
		e.ingest(target, raw, "good", result.At, result.At)
		result.State = "readback_confirmed"
		result.Message = "local point updated"
	} else {
		c := e.connections[target.SourceID]
		supported := false
		for _, s := range e.sources {
			if s.ID == target.SourceID && s.Protocol == "generic" {
				supported = true
			}
		}
		if !supported {
			return result, fmt.Errorf("physical writes require the generic command contract; vendor codec not configured")
		}
		if c == nil || target.WriteTopic == "" {
			result.State = "failed"
			result.Message = "write source or topic unavailable"
		} else {
			state, err := c.Publish(target.WriteTopic, map[string]any{"command_id": w.CommandID, "path": target.SourcePath, "value": raw})
			result.State = state
			result.Message = "broker received command; device confirmation unavailable"
			if err != nil {
				result.Message = err.Error()
			}
		}
	}
	if err := e.Store.SaveConfig("command:"+w.CommandID, result); err != nil {
		result.State = "unknown"
		return result, err
	}
	if err := e.Store.Log(map[string]any{"type": "write", "at": result.At, "result": result}); err != nil {
		return result, err
	}
	return result, nil
}
func (e *Engine) SetRules(rules []Rule) error {
	if len(rules) > 200 {
		return fmt.Errorf("rule limit")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	ids := map[string]bool{}
	pointsByID := map[string]points.Definition{}
	for _, p := range e.active {
		pointsByID[p.ID] = p
	}
	for _, r := range rules {
		if r.ID == "" || ids[r.ID] || r.Name == "" || len(r.Conditions) == 0 || len(r.Conditions) > 32 || len(r.Actions) == 0 || len(r.Actions) > 16 || r.HoldMS < 0 || r.HoldMS > 3600000 || r.CooldownMS < 200 || r.CooldownMS > 86400000 || (r.Logic != "and" && r.Logic != "or") || (r.Trigger != "rising" && r.Trigger != "periodic" && r.Trigger != "recovery") {
			return fmt.Errorf("invalid rule")
		}
		ids[r.ID] = true
		for _, c := range r.Conditions {
			if pointsByID[c.PointID].ID == "" || !strings.Contains("|>|>=|<|<=|==|!=|", "|"+c.Op+"|") || math.IsNaN(c.Value) || math.IsInf(c.Value, 0) {
				return fmt.Errorf("invalid condition")
			}
		}
		for _, a := range r.Actions {
			switch a.Type {
			case "write":
				if !pointsByID[a.PointID].Writable {
					return fmt.Errorf("action target is not writable")
				}
			case "snapshot", "storage_start", "storage_stop":
			default:
				return fmt.Errorf("invalid action")
			}
		}
	}
	if err := e.Store.SaveConfig("rules", rules); err != nil {
		return err
	}
	e.rules = rules
	e.ruleStates = map[string]*ruleState{}
	return nil
}
func (e *Engine) good(id string, now time.Time) bool {
	r, ok := e.live[id]
	if !ok || r.Quality != "good" {
		return false
	}
	for _, p := range e.active {
		if p.ID == id {
			return now.Sub(r.SourceTime) <= time.Duration(p.StaleMS)*time.Millisecond
		}
	}
	return false
}
func compare(x, y float64, op string) bool {
	switch op {
	case ">":
		return x > y
	case ">=":
		return x >= y
	case "<":
		return x < y
	case "<=":
		return x <= y
	case "==":
		return x == y
	case "!=":
		return x != y
	}
	return false
}
func (e *Engine) Preview(r Rule) map[string]any {
	e.mu.Lock()
	defer e.mu.Unlock()
	value, known := e.condition(r, time.Now())
	return map[string]any{"matches": value, "known": known, "side_effects": false}
}
func (e *Engine) condition(r Rule, now time.Time) (bool, bool) {
	match := r.Logic != "or"
	for _, c := range r.Conditions {
		if !e.good(c.PointID, now) {
			return false, false
		}
		n, ok := numeric(e.live[c.PointID].Value)
		if !ok {
			return false, false
		}
		hit := compare(n, c.Value, c.Op)
		if r.Logic == "or" {
			match = match || hit
		} else {
			match = match && hit
		}
	}
	return match, true
}
func (e *Engine) snapshotLocked(now time.Time) error {
	rows := make([]storage.Sample, 0, len(e.live))
	for _, p := range e.active {
		r, ok := e.live[p.ID]
		if !ok {
			continue
		}
		if len(e.policy.PointIDs) > 0 {
			selected := false
			for _, id := range e.policy.PointIDs {
				if id == p.ID {
					selected = true
				}
			}
			if !selected {
				continue
			}
		}
		if !e.good(p.ID, now) && r.Quality == "good" {
			r.Quality = "stale"
		}
		rows = append(rows, r)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return e.Store.Append(ctx, rows)
}
func (e *Engine) evaluate(now time.Time) {
	index := map[string]points.Definition{}
	for _, p := range e.active {
		index[p.ID] = p
	}
	for _, id := range e.order {
		p := index[id]
		values := make([]float64, 0, len(p.Inputs))
		q := "good"
		source := now
		for _, dep := range p.Inputs {
			if !e.good(dep, now) {
				q = "bad"
				break
			}
			n, ok := numeric(e.live[dep].Value)
			if !ok {
				q = "bad"
				break
			}
			values = append(values, n)
			if e.live[dep].SourceTime.Before(source) {
				source = e.live[dep].SourceTime
			}
		}
		var value any
		if q == "good" {
			n, err := expr.Run(e.programs[id], map[string]any{"v": values})
			if err != nil {
				q = "bad"
			} else {
				value = n
			}
		}
		e.ingest(p, value, q, source, now)
	}
	for _, rule := range e.rules {
		if !rule.Enabled {
			continue
		}
		s := e.ruleStates[rule.ID]
		if s == nil {
			s = &ruleState{}
			e.ruleStates[rule.ID] = s
		}
		match, known := e.condition(rule, now)
		if !known {
			s.Since = time.Time{}
			s.Active = false
			continue
		}
		previous := s.Active
		if !match {
			s.Since = time.Time{}
			s.Active = false
		} else {
			if s.Since.IsZero() {
				s.Since = now
			}
			s.Active = now.Sub(s.Since) >= time.Duration(rule.HoldMS)*time.Millisecond
		}
		fire := rule.Trigger == "rising" && s.Active && !previous || rule.Trigger == "periodic" && s.Active || rule.Trigger == "recovery" && previous && !s.Active
		if !fire || now.Sub(s.Last) < time.Duration(rule.CooldownMS)*time.Millisecond {
			continue
		}
		s.Last = now
		results := make([]map[string]any, 0, len(rule.Actions))
		executionID := fmt.Sprintf("%s-%d", rule.ID, now.UnixNano())
		for i, a := range rule.Actions {
			state, message := "completed", ""
			var err error
			switch a.Type {
			case "write":
				var result Result
				result, err = e.writeLocked(Write{CommandID: fmt.Sprintf("%s-%d", executionID, i), PointID: a.PointID, Value: a.Value, Version: e.version})
				state = result.State
				message = result.Message
			case "snapshot":
				err = e.snapshotLocked(now)
			case "storage_start", "storage_stop":
				p := e.policy
				p.Enabled = a.Type == "storage_start"
				err = e.Store.SaveConfig("policy", p)
				if err == nil {
					e.policy = p
				}
			}
			if err != nil {
				state = "failed"
				message = err.Error()
			}
			results = append(results, map[string]any{"action": a, "state": state, "message": message})
		}
		if err := e.Store.Log(map[string]any{"type": "rule", "id": executionID, "rule_id": rule.ID, "name": rule.Name, "at": now.UTC(), "results": results}); err != nil {
			e.storageError = err.Error()
		}
	}
	if e.policy.Enabled && now.Sub(e.lastSave) >= time.Duration(e.policy.IntervalMS)*time.Millisecond {
		rows := make([]storage.Sample, 0, len(e.live))
		next := map[string]string{}
		for _, p := range e.active {
			r, ok := e.live[p.ID]
			if !ok {
				continue
			}
			if len(e.policy.PointIDs) > 0 {
				selected := false
				for _, id := range e.policy.PointIDs {
					if id == p.ID {
						selected = true
					}
				}
				if !selected {
					continue
				}
			}
			if !e.good(p.ID, now) && r.Quality == "good" {
				r.Quality = "stale"
			}
			b, _ := json.Marshal([]any{r.Value, r.Quality, r.Version})
			key := string(b)
			if e.policy.ChangedOnly && e.lastValues[p.ID] == key {
				continue
			}
			rows = append(rows, r)
			next[p.ID] = key
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := e.Store.Append(ctx, rows)
		cancel()
		if err != nil {
			e.storageError = err.Error()
		} else {
			e.storageError = ""
			for id, v := range next {
				e.lastValues[id] = v
			}
		}
		e.lastSave = now
	}
	if now.Sub(e.lastPrune) > time.Minute {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := e.Store.Prune(ctx, e.policy.RetentionDays)
		cancel()
		if err != nil {
			e.storageError = err.Error()
		}
		e.lastPrune = now
	}
}
func (e *Engine) loop() {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	defer close(e.done)
	for {
		select {
		case <-e.stop:
			return
		case batch := <-e.queue:
			e.mu.Lock()
			now := time.Now()
			for _, r := range batch {
				for _, p := range e.active {
					if p.SourceType == "mqtt" && p.SourceID == r.SourceID && p.SourcePath == r.Path && (p.Topic == "" || p.Topic == r.Topic) {
						e.ingest(p, r.Value, r.Quality, r.Time, now)
					}
				}
			}
			e.mu.Unlock()
		case now := <-ticker.C:
			e.mu.Lock()
			if e.demo {
				for i, p := range e.active {
					if p.SourceType == "simulator" && !p.Writable {
						t := now.Sub(e.demoStart).Seconds()
						e.ingest(p, 30+float64(i%7)*2+math.Sin(t*.45+float64(i))*(5+float64(i%3)), "good", now, now)
					} else if p.SourceType == "simulator" && p.Writable {
						if previous, ok := e.live[p.ID]; ok {
							e.ingest(p, previous.Raw, "good", now, now)
						}
					}
				}
			}
			e.evaluate(now)
			e.mu.Unlock()
		}
	}
}
func (e *Engine) Demo(enabled bool) error {
	if enabled {
		count := 0
		for _, p := range e.Points.List() {
			if p.SourceType == "simulator" {
				count++
			}
		}
		if count == 0 {
			scale := 1.0
			for station := 1; station <= 30; station++ {
				for _, name := range []string{"温度", "压力", "设定值"} {
					unit := "°C"
					if name == "压力" {
						unit = "bar"
					}
					writable := name == "设定值"
					min, max := 0.0, 100.0
					if _, err := e.Points.Create(points.CreateInput{Station: fmt.Sprintf("IO-%02d", station), Name: name, DataType: "FLOAT", SourceType: "simulator", Unit: unit, ScaleFactor: &scale, Writable: writable, Min: &min, Max: &max}); err != nil {
						return err
					}
				}
			}
		}
		if _, err := e.Apply(); err != nil {
			return err
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.demo = enabled
	e.demoStart = time.Now()
	if enabled {
		for _, p := range e.active {
			if p.SourceType == "simulator" && p.Writable {
				e.ingest(p, 50.0, "good", e.demoStart, e.demoStart)
			}
		}
	}
	return nil
}

func (e *Engine) SnapshotNow() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snapshotLocked(time.Now())
}

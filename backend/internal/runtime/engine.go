package runtime

import (
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
	Station       string   `json:"station"`
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
	Station    string      `json:"station,omitempty"`
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
	PublishState   string     `json:"publish_state"`
	ACKState       string     `json:"ack_state"`
	ReadbackState  string     `json:"readback_state"`
	QID            int64      `json:"qid,omitempty"`
	PublishedAt    *time.Time `json:"published_at,omitempty"`
	AcknowledgedAt *time.Time `json:"acknowledged_at,omitempty"`
	ReadbackAt     *time.Time `json:"readback_at,omitempty"`
	CommandID      string     `json:"command_id"`
	PointID        string     `json:"point_id"`
	State          string     `json:"state"`
	Message        string     `json:"message"`
	At             time.Time  `json:"at"`
	Value          float64    `json:"value"`
	Version        string     `json:"version"`
}
type Engine struct {
	demoMu               sync.Mutex
	mu                   sync.Mutex
	Points               *points.Service
	Store                *storage.Store
	active               []points.Definition
	pointIndex           map[string]points.Definition
	inputIndex           map[inputKey][]points.Definition
	stationPolicies      map[string]Policy
	stationSaves         map[string]time.Time
	stationValues        map[string]map[string]string
	writeQueue           chan writeTask
	writeWorkers         sync.WaitGroup
	pending              map[string]*pendingWrite
	accepted             atomic.Int64
	processed            atomic.Int64
	acceptedSamples      atomic.Int64
	processedSamples     atomic.Int64
	droppedBatches       atomic.Int64
	inFlight             atomic.Int64
	programs             map[string]*vm.Program
	order                []string
	live                 map[string]storage.Sample
	version              string
	sources              []acquisition.Source
	connections          map[string]*acquisition.Connection
	sourceState          map[string]string
	connectionGeneration map[string]uint64
	rules                []Rule
	ruleStates           map[string]*ruleState
	policy               Policy
	lastSave             time.Time
	lastValues           map[string]string
	lastPrune            time.Time
	queueMu              sync.Mutex
	queue                chan []acquisition.Raw
	dropped              atomic.Int64
	stop                 chan struct{}
	done                 chan struct{}
	demo                 bool
	demoStart            time.Time
	storageError         string
	storageFailures      map[string]string
}

func New(ps *points.Service, db *storage.Store) (*Engine, error) {
	e := &Engine{Points: ps, Store: db, live: map[string]storage.Sample{}, connections: map[string]*acquisition.Connection{}, sourceState: map[string]string{}, connectionGeneration: map[string]uint64{}, ruleStates: map[string]*ruleState{}, lastValues: map[string]string{}, queue: make(chan []acquisition.Raw, 128), stop: make(chan struct{}), done: make(chan struct{}), policy: Policy{IntervalMS: 1000, RetentionDays: 30}, stationPolicies: map[string]Policy{}, stationSaves: map[string]time.Time{}, stationValues: map[string]map[string]string{}, writeQueue: make(chan writeTask, 32), pending: map[string]*pendingWrite{}, sources: []acquisition.Source{}, rules: []Rule{}}
	for key, v := range map[string]any{"sources": &e.sources, "rules": &e.rules, "policy": &e.policy, "station_policies": &e.stationPolicies} {
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
	for i := 0; i < 4; i++ {
		e.writeWorkers.Add(1)
		go e.writeLoop()
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
	e.writeWorkers.Wait()
	e.mu.Lock()
	for id, p := range e.pending {
		if p.Result.PublishState == "queued" {
			r := p.Result
			r.State = "failed"
			r.PublishState = "not_sent"
			r.ACKState = "not_requested"
			r.ReadbackState = "not_requested"
			r.Message = "shutdown before publication; command was not sent"
			_ = e.persistResultLocked(r)
			delete(e.pending, id)
		}
	}
	e.mu.Unlock()
}
func (e *Engine) Submit(rows []acquisition.Raw) {
	if len(rows) == 0 {
		return
	}
	e.queueMu.Lock()
	defer e.queueMu.Unlock()
	select {
	case e.queue <- rows:
		e.accepted.Add(1)
		e.acceptedSamples.Add(int64(len(rows)))
	default:
		e.dropped.Add(int64(len(rows)))
		e.droppedBatches.Add(1)
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
	e.pointIndex = index
	e.inputIndex = map[inputKey][]points.Definition{}
	for _, p := range rows {
		if p.SourceType == "mqtt" {
			k := inputKey{p.SourceID, p.Topic, p.SourcePath}
			e.inputIndex[k] = append(e.inputIndex[k], p)
		}
	}
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
	metrics := map[string]any{}
	for id, c := range e.connections {
		metrics[id] = c.Stats()
	}
	return map[string]any{"source_metrics": metrics, "queue": e.queueStats(), "station_policies": e.stationPolicies, "version": e.version, "values": values, "sources": e.sources, "source_states": states, "rules": e.rules, "policy": e.policy, "storage_error": e.storageError, "dropped": e.dropped.Load(), "demo": e.demo}
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
		if s.ACKTimeoutMS < 0 || s.ACKTimeoutMS > 30000 || len(s.ClientID) > 128 || len(s.Writer) > 128 {
			return fmt.Errorf("invalid source write settings")
		}
		ids[s.ID] = true
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range rows {
		if e.connections[s.ID] != nil || e.sourceState[s.ID] == "connecting" {
			return fmt.Errorf("disconnect before editing sources")
		}
	}
	for id, state := range e.sourceState {
		if state == "connecting" && !ids[id] {
			return fmt.Errorf("disconnect before deleting connecting source")
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
	e.connectionGeneration[id]++
	generation := e.connectionGeneration[id]
	e.mu.Unlock()
	c, err := acquisition.Connect(source, e.Submit, func(state string) {
		e.mu.Lock()
		if e.connectionGeneration[id] == generation {
			e.sourceState[id] = state
		}
		e.mu.Unlock()
	})
	e.mu.Lock()
	stopped := false
	select {
	case <-e.stop:
		stopped = true
	default:
	}
	if e.connectionGeneration[id] != generation || stopped {
		e.mu.Unlock()
		if c != nil {
			c.Close()
		}
		return fmt.Errorf("connection cancelled")
	}
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
	e.connectionGeneration[id]++
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
func (e *Engine) ingest(p points.Definition, raw any, q string, source, now time.Time) bool {
	if source.IsZero() || source.After(now.Add(5*time.Second)) {
		q = "bad"
	}
	// Virtual evaluations are ordered under the runtime lock, not by source
	// time. Recovery can legitimately move back from an invalid evaluation's
	// timestamp to the oldest valid input's timestamp. Only external samples
	// need the out-of-order guard; otherwise a virtual point can remain bad
	// after its inputs recover.
	if old, ok := e.live[p.ID]; ok && p.SourceType != "virtual" && !old.SourceTime.After(now.Add(5*time.Second)) && source.Before(old.SourceTime) {
		return false
	}
	var value any = raw
	switch p.DataType {
	case "FLOAT", "INT":
		n, ok := numeric(raw)
		if !ok || p.DataType == "INT" && (math.Trunc(n) != n || math.Abs(n) > 9007199254740991) {
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
	// Nonfinite formula/input results remain invalid, but must not poison the
	// JSON snapshot or an entire historical batch. Preserve a safe diagnostic
	// instead of replacing the invalid raw value with a misleading zero.
	switch n := raw.(type) {
	case float64:
		if math.IsNaN(n) || math.IsInf(n, 0) {
			raw = strconv.FormatFloat(n, 'g', -1, 64)
		}
	case float32:
		if math.IsNaN(float64(n)) || math.IsInf(float64(n), 0) {
			raw = strconv.FormatFloat(float64(n), 'g', -1, 32)
		}
	}
	e.live[p.ID] = storage.Sample{PointID: p.ID, Station: p.Station, Name: p.Name, Value: value, Raw: raw, Unit: p.Unit, Quality: q, SourceTime: source.UTC(), ReceivedTime: now.UTC(), Version: e.version}
	return q == "good"
}
func (e *Engine) Manual(id string, value any) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	p, ok := e.pointIndex[id]
	if !ok {
		return fmt.Errorf("point not applied")
	}
	if p.SourceType != "manual" {
		return fmt.Errorf("only manual inputs accept samples")
	}
	if value == nil {
		return fmt.Errorf("value required")
	}
	now := time.Now()
	e.ingest(p, value, "good", now, now)
	return nil
}
func (e *Engine) SetRules(rules []Rule) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.validateRulesLocked(rules); err != nil {
		return err
	}
	if err := e.Store.SaveConfig("rules", rules); err != nil {
		return err
	}
	nextStates := make(map[string]*ruleState, len(rules))
	previous := make(map[string]Rule, len(e.rules))
	for _, rule := range e.rules {
		previous[rule.ID] = rule
	}
	nextRules := make([]Rule, len(rules))
	for i, rule := range rules {
		if old, exists := previous[rule.ID]; exists && sameRule(old, rule) {
			if state := e.ruleStates[rule.ID]; state != nil {
				nextStates[rule.ID] = state
			}
		}
		nextRules[i] = rule
		nextRules[i].Conditions = append([]Condition(nil), rule.Conditions...)
		nextRules[i].Actions = append([]Action(nil), rule.Actions...)
	}
	e.rules = nextRules
	e.ruleStates = nextStates
	return nil
}
func (e *Engine) good(id string, now time.Time) bool {
	r, ok := e.live[id]
	p, exists := e.pointIndex[id]
	return ok && exists && r.Quality == "good" && now.Sub(r.SourceTime) <= time.Duration(p.StaleMS)*time.Millisecond
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
	if err := e.validateRulesLocked([]Rule{r}); err != nil {
		return map[string]any{"matches": false, "known": false, "side_effects": false, "error": err.Error()}
	}
	value, known := e.condition(r, time.Now())
	return map[string]any{"matches": value, "known": known, "side_effects": false}
}
func (e *Engine) condition(r Rule, now time.Time) (bool, bool) {
	if !e.ruleInScope(r) {
		return false, false
	}
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
func (e *Engine) evaluate(now time.Time) {
	for _, id := range e.order {
		p := e.pointIndex[id]
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
				err = e.snapshotScopeLocked(rule.Station, now)
			case "storage_start", "storage_stop":
				p := e.policyForLocked(rule.Station)
				p.Enabled = a.Type == "storage_start"
				err = e.setPolicyLocked(rule.Station, p)
			}
			if err != nil {
				state = "failed"
				message = err.Error()
			}
			results = append(results, map[string]any{"action": a, "state": state, "message": message})
		}
		err := e.Store.Log(map[string]any{"type": "rule", "id": executionID, "rule_id": rule.ID, "station": rule.Station, "name": rule.Name, "at": now.UTC(), "results": results})
		e.recordStorageErrorLocked("rule:"+rule.ID, err)
	}
	e.storePoliciesLocked(now)
	e.expireReadbacksLocked(now)
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
				keys := []inputKey{{r.SourceID, r.Topic, r.Path}}
				if r.Topic != "" {
					keys = append(keys, inputKey{r.SourceID, "", r.Path})
				}
				for _, k := range keys {
					for _, p := range e.inputIndex[k] {
						received := r.ReceivedTime
						if received.IsZero() {
							received = now
						}
						if e.ingest(p, r.Value, r.Quality, r.Time, received) {
							e.observeReadbackLocked(p, r, received)
						}
					}
				}
			}
			e.mu.Unlock()
			e.queueMu.Lock()
			e.processed.Add(1)
			e.processedSamples.Add(int64(len(batch)))
			e.queueMu.Unlock()
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
	// Serialize initialization and toggles without holding the runtime lock while
	// configuration is saved or Apply acquires that lock.
	e.demoMu.Lock()
	defer e.demoMu.Unlock()
	if enabled {
		count := 0
		for _, p := range e.Points.List() {
			if p.SourceType == "simulator" {
				count++
			}
		}
		if count == 0 {
			scale := 1.0
			inputs := make([]points.CreateInput, 0, 90)
			for station := 1; station <= 30; station++ {
				for _, name := range []string{"温度", "压力", "设定值"} {
					unit := "°C"
					if name == "压力" {
						unit = "bar"
					}
					writable := name == "设定值"
					min, max := 0.0, 100.0
					inputs = append(inputs, points.CreateInput{Station: fmt.Sprintf("IO-%02d", station), Name: name, DataType: "FLOAT", SourceType: "simulator", Unit: unit, ScaleFactor: &scale, Writable: writable, Min: &min, Max: &max})
				}
			}
			// Readers observe either the preceding configuration or all 90 demo
			// definitions, including when a capacity/identity check fails.
			if _, err := e.Points.CreateBatch(inputs); err != nil {
				return err
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
	return e.snapshotScopeLocked("", time.Now())
}

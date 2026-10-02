package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

type inputKey struct{ Source, Topic, Path string }

func (e *Engine) policyForLocked(station string) Policy {
	if station == "" {
		p := e.policy
		p.PointIDs = append([]string(nil), p.PointIDs...)
		return p
	}
	p, ok := e.stationPolicies[station]
	if !ok {
		p = Policy{Station: station, IntervalMS: 1000, RetentionDays: 30}
	}
	p.PointIDs = append([]string(nil), p.PointIDs...)
	return p
}
func (e *Engine) StoragePolicy(station string) Policy {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.policyForLocked(station)
}
func (e *Engine) Policy(p Policy) error { return e.SetPolicy(p.Station, p) }
func (e *Engine) SetPolicy(station string, p Policy) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.setPolicyLocked(station, p)
}
func (e *Engine) setPolicyLocked(station string, p Policy) error {
	if len(station) > 128 || p.Station != "" && p.Station != station || p.IntervalMS < 200 || p.IntervalMS > 3600000 || p.RetentionDays < 1 || p.RetentionDays > 3650 {
		return fmt.Errorf("invalid storage policy")
	}
	p.Station = station
	seen := map[string]bool{}
	for _, id := range p.PointIDs {
		target, ok := e.pointIndex[id]
		if !ok || seen[id] || station != "" && target.Station != station {
			return fmt.Errorf("storage point must belong to the selected station")
		}
		seen[id] = true
	}
	p.PointIDs = append([]string(nil), p.PointIDs...)
	previous, exists := e.stationPolicies[station]
	if station == "" {
		previous, exists = e.policy, true
	}
	if exists && previous.Enabled == p.Enabled && previous.IntervalMS == p.IntervalMS && previous.RetentionDays == p.RetentionDays && previous.ChangedOnly == p.ChangedOnly && slices.Equal(previous.PointIDs, p.PointIDs) {
		// Repeating storage_start or saving an unchanged policy must not reset
		// its cadence or erase the changed-only comparison baseline.
		return nil
	}
	if station == "" {
		if err := e.Store.SaveConfig("policy", p); err != nil {
			return err
		}
		e.policy = p
		e.lastValues = map[string]string{}
		e.lastSave = time.Time{}
		return nil
	}
	next := make(map[string]Policy, len(e.stationPolicies)+1)
	for k, v := range e.stationPolicies {
		next[k] = v
	}
	next[station] = p
	if err := e.Store.SaveConfig("station_policies", next); err != nil {
		return err
	}
	e.stationPolicies = next
	delete(e.stationValues, station)
	delete(e.stationSaves, station)
	return nil
}
func (e *Engine) ruleInScope(r Rule) bool {
	if r.Station == "" {
		return true
	}
	for _, c := range r.Conditions {
		p, ok := e.pointIndex[c.PointID]
		if !ok || p.Station != r.Station {
			return false
		}
	}
	for _, a := range r.Actions {
		if a.Type == "write" {
			p, ok := e.pointIndex[a.PointID]
			if !ok || p.Station != r.Station {
				return false
			}
		}
	}
	return true
}
func (e *Engine) policySamplesLocked(p Policy, now time.Time) []storage.Sample {
	selected := make(map[string]bool, len(p.PointIDs))
	for _, id := range p.PointIDs {
		selected[id] = true
	}
	rows := make([]storage.Sample, 0, len(e.live))
	for _, definition := range e.active {
		if p.Station != "" && definition.Station != p.Station || len(selected) > 0 && !selected[definition.ID] {
			continue
		}
		sample, ok := e.live[definition.ID]
		if !ok {
			continue
		}
		// Never relabel a frozen live sample after a point changes station.
		if sample.Station != definition.Station || sample.Version != e.version {
			continue
		}
		if !e.good(definition.ID, now) && sample.Quality == "good" {
			sample.Quality = "stale"
		}
		rows = append(rows, sample)
	}
	return rows
}
func (e *Engine) snapshotScopeLocked(station string, now time.Time) error {
	if len(station) > 128 {
		return fmt.Errorf("invalid station")
	}
	rows := e.policySamplesLocked(e.policyForLocked(station), now)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := e.Store.Append(ctx, rows)
	e.recordStorageErrorLocked("snapshot:"+station, err)
	return err
}
func (e *Engine) SnapshotStation(station string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snapshotScopeLocked(station, time.Now())
}
func (e *Engine) storePoliciesLocked(now time.Time) {
	policies := make([]Policy, 0, len(e.stationPolicies)+1)
	policies = append(policies, e.policy)
	for _, p := range e.stationPolicies {
		policies = append(policies, p)
	}
	for _, p := range policies {
		last := e.lastSave
		values := e.lastValues
		if p.Station != "" {
			last = e.stationSaves[p.Station]
			values = e.stationValues[p.Station]
		}
		if !p.Enabled || now.Sub(last) < time.Duration(p.IntervalMS)*time.Millisecond {
			continue
		}
		rows := e.policySamplesLocked(p, now)
		next := map[string]string{}
		filtered := make([]storage.Sample, 0, len(rows))
		for _, r := range rows {
			b, _ := json.Marshal([]any{r.Value, r.Quality, r.Version})
			key := string(b)
			if p.ChangedOnly && values[r.PointID] == key {
				continue
			}
			next[r.PointID] = key
			filtered = append(filtered, r)
		}
		var err error
		if len(filtered) > 0 {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			err = e.Store.Append(ctx, filtered)
			cancel()
			e.recordStorageErrorLocked("policy:"+p.Station, err)
		}
		if err == nil {
			if values == nil {
				values = map[string]string{}
			}
			for id, v := range next {
				values[id] = v
			}
		}
		if p.Station == "" {
			e.lastSave = now
			e.lastValues = values
		} else {
			e.stationSaves[p.Station] = now
			e.stationValues[p.Station] = values
		}
	}
	if now.Sub(e.lastPrune) > time.Minute {
		stations := make([]string, 0, len(e.stationPolicies))
		for station, p := range e.stationPolicies {
			stations = append(stations, station)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			err := e.Store.PruneStation(ctx, station, p.RetentionDays)
			cancel()
			e.recordStorageErrorLocked("retention:"+station, err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := e.Store.PruneExcept(ctx, e.policy.RetentionDays, stations)
		cancel()
		e.recordStorageErrorLocked("retention:", err)
		e.lastPrune = now
	}
}

// A successful operation only clears its own failure. An unrelated station,
// empty sampling pass, or successful history write cannot hide a failed rule log.
const maxStorageFailureDetails = 256

func (e *Engine) recordStorageErrorLocked(operation string, err error) {
	if e.storageFailures == nil {
		e.storageFailures = map[string]string{}
	}
	if err == nil {
		delete(e.storageFailures, operation)
	} else {
		_, tracked := e.storageFailures[operation]
		if tracked || len(e.storageFailures) < maxStorageFailureDetails {
			e.storageFailures[operation] = err.Error()
		} else {
			// Do not allocate one entry per failed command forever, or imply
			// recovery of omitted operations when a different operation succeeds.
			e.storageFailures["overflow"] = "additional storage failures omitted; diagnostic overflow remains until restart"
		}
	}
	keys := make([]string, 0, len(e.storageFailures))
	for key := range e.storageFailures {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	messages := make([]string, 0, len(keys))
	for _, key := range keys {
		messages = append(messages, key+": "+e.storageFailures[key])
	}
	e.storageError = strings.Join(messages, "; ")
}

func (e *Engine) queueStats() map[string]any {
	e.queueMu.Lock()
	defer e.queueMu.Unlock()
	accepted, processed, depth := e.accepted.Load(), e.processed.Load(), len(e.queue)
	// Channel-dequeued work counts as in-flight, including the brief lock handoff.
	return map[string]any{"accepted_batches": accepted, "processed_batches": processed, "dropped_batches": e.droppedBatches.Load(), "accepted_samples": e.acceptedSamples.Load(), "processed_samples": e.processedSamples.Load(), "dropped_samples": e.dropped.Load(), "queued_batches": depth, "in_flight_batches": accepted - processed - int64(depth), "capacity_batches": cap(e.queue), "capacity": cap(e.queue), "depth": depth}
}

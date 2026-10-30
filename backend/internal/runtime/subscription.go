package runtime

import (
	"context"
	"fmt"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

const MaxSubscriptionPoints = 5000

// SubscriptionSnapshot reads only requested point IDs, plus their dependencies
// for quality/authorization. nil IDs explicitly requests the authorized catalog;
// an empty non-nil list requests health only. Every response is detached from the
// engine's mutable maps before the caller encodes it.
func (e *Engine) SubscriptionSnapshot(ctx context.Context, ids []string) (map[string]any, error) {
	if len(ids) > MaxSubscriptionPoints {
		return nil, fmt.Errorf("point subscription limit")
	}
	a, secured := authorization.FromContext(ctx)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.requireIdentity && !secured || secured && !a.Active() {
		return nil, authorization.ErrDenied
	}
	if ids == nil {
		ids = make([]string, 0, len(e.active))
		for _, p := range e.active {
			if !secured || a.Station(p.Station) {
				ids = append(ids, p.ID)
			}
		}
	}
	rows := e.selectedLocked(a, secured, ids, time.Now())
	values := make([]storage.Sample, 0, len(rows))
	seen := map[string]bool{}
	for _, id := range ids {
		if v, ok := rows[id]; ok && !seen[id] {
			values = append(values, v)
			seen[id] = true
		}
	}
	data := map[string]any{"version": e.version, "values": values}
	if !secured || a.Grants.Develop() {
		for k, v := range e.metadataLocked() {
			data[k] = v
		}
	}
	return data, nil
}

func (e *Engine) selectedLocked(a authorization.Actor, secured bool, ids []string, now time.Time) map[string]storage.Sample {
	memo := map[string]string{}
	visiting := map[string]bool{}
	var quality func(string) string
	quality = func(id string) string {
		if q, ok := memo[id]; ok {
			return q
		}
		if visiting[id] {
			return "missing"
		}
		visiting[id] = true
		defer delete(visiting, id)
		p, ok := e.pointIndex[id]
		q := "good"
		if !ok || secured && !a.Station(p.Station) {
			q = "unavailable"
		} else if v, found := e.live[id]; !found {
			q = "missing"
		} else if v.Quality != "good" {
			q = v.Quality
		} else if !e.freshLocked(p, v, now) {
			q = "stale"
		}
		if q == "good" && p.SourceType == "mqtt" && e.sourceState[p.SourceID] != "connected" {
			q = "offline"
		}
		if q == "good" && p.SourceType == "virtual" {
			for _, dep := range p.Inputs {
				if quality(dep) != "good" {
					q = "invalid_dependency"
					break
				}
			}
		}
		memo[id] = q
		return q
	}
	out := make(map[string]storage.Sample, len(ids))
	for _, id := range ids {
		q := quality(id)
		if q == "unavailable" {
			continue
		}
		p := e.pointIndex[id]
		v, ok := e.live[id]
		if !ok {
			v = storage.Sample{PointID: id, Station: p.Station, Name: p.Name, Unit: p.Unit, Version: e.version}
		}
		v.Quality = q
		if secured && !a.Grants.Develop() {
			v.Raw = nil
		}
		if q != "good" {
			v.Value = nil
			v.Raw = nil
		}
		out[id] = v
	}
	return out
}

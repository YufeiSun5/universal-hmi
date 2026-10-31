package runtime

import (
	"context"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func (e *Engine) SnapshotFor(ctx context.Context) (map[string]any, error) {
	a, secured := authorization.FromContext(ctx)
	if !secured {
		return e.Snapshot(), nil
	}
	if !a.Active() {
		return nil, authorization.ErrDenied
	}
	data, err := e.SubscriptionSnapshot(ctx, nil)
	if err != nil {
		return nil, err
	}
	values := data["values"]
	if !a.Grants.Develop() {
		data = map[string]any{"version": data["version"], "sources": []any{}, "rules": []any{}, "source_states": map[string]any{}, "station_policies": map[string]any{}, "policy": map[string]any{}, "storage_error": "", "demo": false}
	}
	data["values"] = values
	return data, nil
}
func (e *Engine) SnapshotJSONFor(ctx context.Context) ([]byte, error) {
	v, err := e.SnapshotFor(ctx)
	if err != nil {
		return nil, err
	}
	return json.Marshal(v)
}

func (e *Engine) RequireIdentity() { e.mu.Lock(); defer e.mu.Unlock(); e.requireIdentity = true }
func (e *Engine) WriteFor(ctx context.Context, w Write) (Result, error) {
	if a, ok := authorization.FromContext(ctx); ok {
		w.Actor = &a
	}
	return e.Write(w)
}
func (e *Engine) CommandFor(ctx context.Context, id string) (Result, error) {
	r, err := e.Command(id)
	if a, ok := authorization.FromContext(ctx); ok {
		if !a.Active() || !a.Grants.Control || r.UserID != a.ID {
			return Result{}, authorization.ErrDenied
		}
	}
	return r, err
}
func (e *Engine) CapabilityFor(ctx context.Context, id string) (WriteCapability, error) {
	if a, ok := authorization.FromContext(ctx); ok {
		e.mu.Lock()
		p, exists := e.pointIndex[id]
		e.mu.Unlock()
		if !exists || !a.Active() || !a.Grants.Control || !a.Station(p.Station) {
			return WriteCapability{}, authorization.ErrDenied
		}
	}
	c := e.WriteCapability(id)
	if a, ok := authorization.FromContext(ctx); ok && !a.Grants.Develop() {
		c.SourceID = ""
		c.Protocol = ""
	}
	return c, nil
}

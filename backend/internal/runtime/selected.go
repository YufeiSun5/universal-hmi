package runtime

import (
	"context"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"time"
)

// ReadPointsFor returns at most 200 engineering values from one engine snapshot.
// Dependencies must also be authorized, fresh and connected. No raw values escape.
func (e *Engine) ReadPointsFor(ctx context.Context, ids []string) (map[string]storage.Sample, error) {
	if len(ids) > 200 {
		return nil, fmt.Errorf("point selection limit")
	}
	a, secured := authorization.FromContext(ctx)
	e.mu.Lock()
	defer e.mu.Unlock()
	if (e.requireIdentity && !secured) || secured && !a.Active() {
		return nil, authorization.ErrDenied
	}
	out := e.selectedLocked(a, secured, ids, time.Now())
	for id, v := range out {
		v.Raw = nil
		out[id] = v
	}
	return out, nil
}

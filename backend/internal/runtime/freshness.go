package runtime

import (
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func (e *Engine) freshLocked(p points.Definition, v storage.Sample, now time.Time) bool {
	confirmed := e.confirmationLocked(p, v)
	return !confirmed.IsZero() && now.Sub(confirmed) <= time.Duration(p.StaleMS)*time.Millisecond
}

// KIO timestamps describe last value change, not when a constant value was
// confirmed. Only a non-retained observation of this exact tag refreshes it.
// Broker connectivity or a successful query publish never confirms tag quality.
func (e *Engine) confirmationLocked(p points.Definition, v storage.Sample) time.Time {
	if confirmed, ok := e.confirmed[p.ID]; ok {
		return confirmed
	}
	if e.kingIOLocked(p) {
		return time.Time{}
	}
	return v.SourceTime
}

func (e *Engine) kingIOLocked(p points.Definition) bool {
	if p.SourceType != "mqtt" {
		return false
	}
	for _, s := range e.sources {
		if s.ID == p.SourceID {
			return s.Protocol == "kingio"
		}
	}
	return false
}

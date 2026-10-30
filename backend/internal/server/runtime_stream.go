package server

import (
	"context"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"net/http"
	"sync"
	"time"

	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
)

// The callback rechecks a long-lived request without renewing its session.
type streamAccessKey struct{}

func withStreamAccess(r *http.Request, valid func() bool) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), streamAccessKey{}, valid))
}

func runtimeStream(e *rt.Engine) http.HandlerFunc {
	slots := make(chan struct{}, 32)
	delta := runtimeDeltaStream(e)
	var mu sync.Mutex
	var cached []byte
	var sampled time.Time
	snapshot := func() ([]byte, error) {
		mu.Lock()
		defer mu.Unlock()
		if time.Since(sampled) >= 250*time.Millisecond || cached == nil {
			data, err := e.SnapshotJSON()
			if err != nil {
				return nil, err
			}
			cached, sampled = data, time.Now()
		}
		return cached, nil
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("protocol") == "delta" {
			delta(w, r)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			writeError(w, 503, "stream_limit", "实时订阅已满，请稍后重连")
			return
		}
		if _, ok := w.(http.Flusher); !ok {
			writeError(w, 500, "stream_unavailable", "实时通道不可用")
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Accel-Buffering", "no")
		controller := http.NewResponseController(w)
		defer controller.SetWriteDeadline(time.Time{})
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			if valid, ok := r.Context().Value(streamAccessKey{}).(func() bool); ok && !valid() {
				_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
				_, _ = fmt.Fprint(w, "event: session-expired\ndata: {}\n\n")
				_ = controller.Flush()
				return
			}
			var data []byte
			var err error
			if _, managed := authorization.FromContext(r.Context()); managed {
				data, err = e.SnapshotJSONFor(r.Context())
			} else {
				data, err = snapshot()
			}
			if err != nil {
				return
			}
			// One complete latest-state frame; no unbounded per-client queue or
			// historical replay. Slow clients are disconnected, then resnapshot.
			_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err = fmt.Fprintf(w, "event: runtime\ndata: %s\n\n", data); err != nil {
				return
			}
			if controller.Flush() != nil {
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
			}
		}
	}
}

package server

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

// Each connection keeps only the last selected state. This is latest-state
// delivery, not an event journal; reconnects always start with a complete reset.
// The legacy protocol retains its separate 32-slot bound during migration.
const maxDeltaStreams = 128

type streamValue struct {
	PointID      string    `json:"point_id"`
	Value        any       `json:"value"`
	Raw          any       `json:"raw"`
	Quality      string    `json:"quality"`
	SourceTime   time.Time `json:"source_time"`
	ReceivedTime time.Time `json:"received_time"`
}

func subscriptionIDs(r *http.Request) ([]string, error) {
	query := r.URL.Query()
	if !query.Has("ids") {
		return nil, nil // Explicit all-authorized fallback for catalog views.
	}
	text := query.Get("ids")
	if len(text) > rt.MaxSubscriptionPoints*129 {
		return nil, fmt.Errorf("subscription too large")
	}
	ids := []string{}
	seen := map[string]bool{}
	if text == "" {
		return ids, nil
	}
	parts := strings.Split(text, ",")
	if len(parts) > rt.MaxSubscriptionPoints {
		return nil, fmt.Errorf("point subscription limit")
	}
	for _, id := range parts {
		if id == "" || len(id) > 128 || strings.TrimSpace(id) != id || strings.ContainsAny(id, "\x00\r\n") {
			return nil, fmt.Errorf("invalid point ID")
		}
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	return ids, nil
}

func runtimeDeltaStream(e *rt.Engine) http.HandlerFunc {
	slots := make(chan struct{}, maxDeltaStreams)
	return func(w http.ResponseWriter, r *http.Request) {
		ids, err := subscriptionIDs(r)
		if err != nil {
			writeError(w, 400, "invalid_subscription", err.Error())
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
		var nonce [16]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			writeError(w, 500, "stream_unavailable", "实时通道不可用")
			return
		}
		epoch := hex.EncodeToString(nonce[:])
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Accel-Buffering", "no")
		controller := http.NewResponseController(w)
		defer controller.SetWriteDeadline(time.Time{})
		write := func(event string, data []byte) bool {
			_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
			_, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
			return err == nil && controller.Flush() == nil
		}
		valid := func() bool {
			check, ok := r.Context().Value(streamAccessKey{}).(func() bool)
			return !ok || check()
		}
		previous := map[string][]byte{}
		var previousMeta []byte
		version := ""
		sequence := uint64(0)
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			if !valid() {
				write("session-expired", []byte("{}"))
				return
			}
			current, err := e.SubscriptionSnapshot(r.Context(), ids)
			if err != nil {
				write("session-expired", []byte("{}"))
				return
			}
			values := current["values"].([]storage.Sample)
			delete(current, "values")
			currentVersion := current["version"].(string)
			reset := sequence == 0 || version != currentVersion
			meta, err := json.Marshal(current)
			if err != nil {
				return
			}
			next := make(map[string][]byte, len(values))
			changed := make([]json.RawMessage, 0)
			for _, v := range values {
				b, err := json.Marshal(streamValue{v.PointID, v.Value, v.Raw, v.Quality, v.SourceTime, v.ReceivedTime})
				if err != nil {
					return
				}
				next[v.PointID] = b
				if !bytes.Equal(previous[v.PointID], b) {
					changed = append(changed, b)
				}
			}
			removed := make([]string, 0)
			for id := range previous {
				if _, exists := next[id]; !exists {
					removed = append(removed, id)
				}
			}
			sequence++
			frame := map[string]any{"epoch": epoch, "sequence": sequence, "version": currentVersion, "kind": "delta", "values": changed, "removed": removed}
			if reset {
				frame["kind"] = "reset"
				frame["values"] = values
			}
			if reset || !bytes.Equal(previousMeta, meta) {
				frame["meta"] = json.RawMessage(meta)
			}
			b, err := json.Marshal(frame)
			if err != nil {
				return
			}
			// Recheck after preparing the frame as well, so an expired/revoked
			// session cannot continue emitting while snapshots are being built.
			if !valid() {
				write("session-expired", []byte("{}"))
				return
			}
			if !write("runtime-delta", b) {
				return
			}
			previous, previousMeta, version = next, meta, currentVersion
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
			}
		}
	}
}

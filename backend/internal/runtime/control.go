package runtime

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

type WriteCapability struct {
	PointID  string   `json:"point_id"`
	Writable bool     `json:"writable"`
	DataType string   `json:"data_type"`
	Min      *float64 `json:"min"`
	Max      *float64 `json:"max"`
	Version  string   `json:"version"`
	Reason   string   `json:"reason"`
	SourceID string   `json:"source_id"`
	Protocol string   `json:"protocol"`
}
type writeTask struct {
	Request    Write
	Target     points.Definition
	Source     acquisition.Source
	Connection *acquisition.Connection
	Raw        float64
}
type pendingWrite struct {
	Result             Result
	Target             points.Definition
	ReadbackAt         time.Time
	ReadbackSourceTime time.Time
	Deadline           time.Time
}

func (e *Engine) capabilityLocked(id string) WriteCapability {
	p, ok := e.pointIndex[id]
	c := WriteCapability{PointID: id, DataType: p.DataType, Min: p.Min, Max: p.Max, Version: e.version, SourceID: p.WriteSourceID}
	if c.SourceID == "" {
		c.SourceID = p.SourceID
	}
	switch {
	case !ok:
		c.Reason = "point_not_applied"
		return c
	case !p.Writable:
		c.Reason = "point_read_only"
		return c
	case p.SourceType == "virtual":
		c.Reason = "virtual_read_only"
		return c
	case p.DataType == "STRING":
		c.Reason = "string_write_unsupported"
		return c
	case p.DataType == "BOOL" && (p.ScaleFactor != 1 || p.Offset != 0):
		c.Reason = "invalid_bool_conversion"
		return c
	}
	if p.SourceType == "manual" || p.SourceType == "simulator" {
		c.Writable = true
		return c
	}
	var source acquisition.Source
	for _, s := range e.sources {
		if s.ID == c.SourceID {
			source = s
		}
	}
	c.Protocol = source.Protocol
	switch {
	case source.ID == "":
		c.Reason = "write_source_missing"
	case source.Protocol != "generic" && source.Protocol != "kingio":
		c.Reason = "protocol_write_unsupported"
	case source.Protocol == "kingio" && p.RWMode != "W" && p.RWMode != "RW":
		c.Reason = "rw_mode_read_only"
	case source.Protocol == "kingio" && (source.ClientID == "" || source.Writer == ""):
		c.Reason = "kio_writer_not_configured"
	case source.Protocol == "generic" && p.WriteTopic == "":
		c.Reason = "write_topic_missing"
	case e.connections[c.SourceID] == nil || e.connections[c.SourceID].Client == nil || !e.connections[c.SourceID].Client.IsConnectionOpen():
		c.Reason = "write_source_offline"
	default:
		c.Writable = true
	}
	return c
}
func (e *Engine) WriteCapability(id string) WriteCapability {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.capabilityLocked(id)
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
	old, err := e.commandLocked(w.CommandID)
	if err != nil {
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
	cap := e.capabilityLocked(w.PointID)
	if !cap.Writable {
		return result, fmt.Errorf("%s", cap.Reason)
	}
	target := e.pointIndex[w.PointID]
	if target.Min != nil && w.Value < *target.Min || target.Max != nil && w.Value > *target.Max {
		return result, fmt.Errorf("outside engineering range")
	}
	raw := (w.Value - target.Offset) / target.ScaleFactor
	if target.DataType == "INT" {
		rounded := math.Round(raw)
		if math.Abs(raw-rounded) <= 1e-9 {
			raw = rounded
		}
	}
	if math.IsNaN(raw) || math.IsInf(raw, 0) || target.DataType == "INT" && (math.Trunc(raw) != raw || math.Abs(raw) > 9007199254740991) || target.DataType == "BOOL" && raw != 0 && raw != 1 {
		return result, fmt.Errorf("value cannot be encoded")
	}
	if target.SourceType == "manual" || target.SourceType == "simulator" {
		result.State = "unknown"
		result.Message = "intent persisted; outcome requires reconciliation"
		if err := e.Store.SaveConfig("command:"+w.CommandID, result); err != nil {
			return result, err
		}
		e.ingest(target, raw, "good", result.At, result.At)
		result.State = "readback_confirmed"
		result.PublishState = "not_required"
		result.ACKState = "not_required"
		result.ReadbackState = "confirmed"
		result.Message = "local point updated"
		at := result.At
		result.ReadbackAt = &at
		return result, e.persistResultLocked(result)
	}
	if len(e.pending) >= 64 || len(e.writeQueue) >= capChannel(e.writeQueue) {
		return result, fmt.Errorf("write queue full")
	}
	var source acquisition.Source
	for _, s := range e.sources {
		if s.ID == cap.SourceID {
			source = s
		}
	}
	result.State = "accepted"
	result.PublishState = "queued"
	result.ACKState = "pending"
	result.ReadbackState = "pending"
	if source.Protocol == "generic" {
		result.ACKState = "unsupported"
		result.ReadbackState = "unsupported"
	}
	result.Message = "intent persisted; queued for publish"
	if err := e.Store.SaveConfig("command:"+w.CommandID, result); err != nil {
		return result, err
	}
	e.pending[w.CommandID] = &pendingWrite{Result: result, Target: target, Deadline: result.At.Add(60 * time.Second)}
	e.writeQueue <- writeTask{w, target, source, e.connections[cap.SourceID], raw}
	return result, nil
}
func capChannel[T any](c chan T) int { return cap(c) }
func (e *Engine) persistResultLocked(r Result) error {
	if err := e.Store.SaveConfig("command:"+r.CommandID, r); err != nil {
		return err
	}
	return e.Store.Log(map[string]any{"type": "write", "at": time.Now().UTC(), "result": r})
}
func (e *Engine) commandLocked(id string) (Result, error) {
	var result Result
	if p := e.pending[id]; p != nil {
		return p.Result, nil
	}
	if err := e.Store.LoadConfig("command:"+id, &result); err != nil {
		return result, err
	}
	if result.State == "accepted" || result.PublishState == "publishing" || result.State == "sent" && result.ProtocolIsKIO() {
		if result.PublishState == "queued" {
			result.State = "failed"
			result.PublishState = "not_sent"
			result.Message = "restart before publication; command was not sent"
		} else {
			result.State = "unknown"
			result.PublishState = "unknown"
			result.ACKState = "unknown"
			result.Message = "interrupted command; reconcile physical state, never replay automatically"
		}
		if err := e.Store.SaveConfig("command:"+id, result); err != nil {
			return result, err
		}
	}

	if result.State == "acknowledged" && result.ReadbackState == "pending" {
		result.ReadbackState = "unconfirmed"
		result.Message = "device ACK persisted; fresh readback was not confirmed before restart"
		if err := e.Store.SaveConfig("command:"+id, result); err != nil {
			return result, err
		}
	}
	return result, nil
}
func (r Result) ProtocolIsKIO() bool { return r.QID != 0 }
func (e *Engine) Command(id string) (Result, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	r, err := e.commandLocked(id)
	if err == nil && r.CommandID == "" {
		err = fmt.Errorf("command not found")
	}
	return r, err
}
func (e *Engine) writeLoop() {
	defer e.writeWorkers.Done()
	for {
		select {
		case <-e.stop:
			return
		case task := <-e.writeQueue:
			select {
			case <-e.stop:
				return
			default:
			}
			e.executeWrite(task)
		}
	}
}
func (e *Engine) executeWrite(task writeTask) {
	id := task.Request.CommandID
	e.mu.Lock()
	pending := e.pending[id]
	if pending == nil {
		e.mu.Unlock()
		return
	}
	capability := e.capabilityLocked(task.Request.PointID)
	if task.Request.Version != e.version || !capability.Writable || e.connections[capability.SourceID] != task.Connection {
		r := pending.Result
		r.State = "failed"
		r.PublishState = "not_sent"
		r.Message = "configuration or source changed before publication"
		r.ACKState = "not_requested"
		r.ReadbackState = "not_requested"
		delete(e.pending, id)
		if err := e.persistResultLocked(r); err != nil {
			e.storageError = err.Error()
		}
		e.mu.Unlock()
		return
	}
	pending.Result.PublishState = "publishing"
	if err := e.Store.SaveConfig("command:"+id, pending.Result); err != nil {
		r := pending.Result
		r.State = "failed"
		r.PublishState = "not_sent"
		r.Message = "could not persist publishing intent"
		delete(e.pending, id)
		e.storageError = err.Error()
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	path := task.Target.WritePath
	if path == "" {
		path = task.Target.SourcePath
	}
	if task.Source.Protocol == "kingio" {
		result, err := task.Connection.PublishKIO(path, task.Raw, func(published acquisition.KIOWriteResult) {
			e.mu.Lock()
			defer e.mu.Unlock()
			pending := e.pending[id]
			if pending == nil {
				return
			}
			r := pending.Result
			r.State = "sent"
			r.PublishState = "sent"
			r.ACKState = "pending"
			r.Message = "broker received command; waiting for device ACK"
			r.QID = published.QID
			at := published.PublishedAt.UTC()
			r.PublishedAt = &at
			pending.Result = r
			if !pending.ReadbackAt.After(at) || !pending.ReadbackSourceTime.After(at) {
				pending.ReadbackAt = time.Time{}
				pending.ReadbackSourceTime = time.Time{}
			}
			if err := e.persistResultLocked(r); err != nil {
				e.storageError = err.Error()
			}
		})
		e.mu.Lock()
		defer e.mu.Unlock()
		pending := e.pending[id]
		if pending == nil {
			return
		}
		r := pending.Result
		r.QID = result.QID
		r.PublishState = result.PublishState
		r.ACKState = result.ACKState
		if !result.PublishedAt.IsZero() {
			at := result.PublishedAt.UTC()
			r.PublishedAt = &at
		}
		if result.ACKState == "acknowledged" {
			r.State = "acknowledged"
			r.Message = "device ACK received; waiting for fresh physical readback"
			at := time.Now().UTC()
			r.AcknowledgedAt = &at
			pending.Deadline = at.Add(30 * time.Second)
			if r.PublishedAt != nil && pending.ReadbackAt.After(*r.PublishedAt) && pending.ReadbackSourceTime.After(*r.PublishedAt) {
				r.State = "readback_confirmed"
				r.ReadbackState = "confirmed"
				r.Message = "device ACK and fresh physical readback confirmed"
				readback := pending.ReadbackAt
				r.ReadbackAt = &readback
			}
		} else if result.PublishState == "failed" || result.ACKState == "failed" {
			r.State = "failed"
			r.ReadbackState = "unconfirmed"
			r.Message = "physical command failed"
		} else {
			r.State = "unknown"
			r.ReadbackState = "unconfirmed"
			r.Message = "device outcome unknown; no automatic replay"
		}
		if err != nil {
			r.Message = err.Error()
		}
		pending.Result = r
		if r.State != "acknowledged" {
			delete(e.pending, id)
		}
		if err := e.persistResultLocked(r); err != nil {
			e.storageError = err.Error()
		}
		return
	}
	started := time.Now().UTC()
	state, err := task.Connection.Publish(task.Target.WriteTopic, map[string]any{"command_id": id, "path": path, "value": task.Raw})
	e.mu.Lock()
	defer e.mu.Unlock()
	pending = e.pending[id]
	if pending == nil {
		return
	}
	r := pending.Result
	r.State = state
	r.PublishState = state
	r.PublishedAt = &started
	r.Message = "broker received command; device confirmation unavailable"
	if err != nil {
		r.Message = err.Error()
	}
	delete(e.pending, id)
	if err := e.persistResultLocked(r); err != nil {
		e.storageError = err.Error()
	}
}
func (e *Engine) observeReadbackLocked(p points.Definition, raw acquisition.Raw, received time.Time) {
	if raw.Retained || raw.Quality != "good" || raw.Time.After(received.Add(5*time.Second)) {
		return
	}
	n, ok := numeric(raw.Value)
	if !ok {
		return
	}
	if p.DataType == "BOOL" && n != 0 && n != 1 || p.DataType == "INT" && math.Trunc(n) != n {
		return
	}
	engineering := n*p.ScaleFactor + p.Offset
	for id, pending := range e.pending {
		r := pending.Result
		if r.PointID != p.ID || r.Version != e.version || pending.Target.SourceID != raw.SourceID || pending.Target.SourcePath != raw.Path || pending.Target.Topic != "" && pending.Target.Topic != raw.Topic || !received.After(r.At) || !raw.Time.After(r.At) || math.Abs(engineering-r.Value) > 1e-9*math.Max(1, math.Abs(r.Value)) {
			continue
		}
		if r.PublishedAt != nil && (!received.After(*r.PublishedAt) || !raw.Time.After(*r.PublishedAt)) {
			continue
		}
		pending.ReadbackAt = received
		pending.ReadbackSourceTime = raw.Time
		if r.State == "acknowledged" {
			r.State = "readback_confirmed"
			r.ReadbackState = "confirmed"
			r.Message = "device ACK and fresh physical readback confirmed"
			at := received.UTC()
			r.ReadbackAt = &at
			pending.Result = r
			delete(e.pending, id)
			if err := e.persistResultLocked(r); err != nil {
				e.storageError = err.Error()
			}
		}
	}
}
func (e *Engine) expireReadbacksLocked(now time.Time) {
	for id, p := range e.pending {
		if p.Result.State == "acknowledged" && now.After(p.Deadline) {
			r := p.Result
			r.Message = "device ACK received; fresh physical readback not confirmed before deadline"
			r.ReadbackState = "unconfirmed"
			if err := e.persistResultLocked(r); err != nil {
				e.storageError = err.Error()
			}
			delete(e.pending, id)
		}
	}
}

// Missing writes must not become zero-valued physical actions through JSON defaults.
func (a *Action) UnmarshalJSON(data []byte) error {
	var value struct {
		Type    string   `json:"type"`
		PointID string   `json:"point_id"`
		Value   *float64 `json:"value"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	if value.Type == "write" && value.Value == nil {
		return fmt.Errorf("write action value required")
	}
	a.Type = value.Type
	a.PointID = value.PointID
	if value.Value != nil {
		a.Value = *value.Value
	}
	return nil
}

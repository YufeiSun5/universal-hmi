package acquisition

// Wire field and topic names follow the public SPT KIO protocol reference:
// backend/internal/protocol/kio/kio.go, blob 6585639e1c81437ee337016ece88ffcf58155661.
// This adapter does not import SPT application logic or gateway credentials.
import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

func KIODataTopic(clientID string) string    { return "datachange_" + clientID }
func KIOSetDataTopic(clientID string) string { return "setdata_" + clientID }
func KIOResultTopic(clientID, writer string) string {
	return "setdata_result_" + clientID + "_" + writer
}
func KIOQueryAllTopic(clientID string) string { return "Query_AllKIOTags_" + clientID }

// PublishState describes MQTT broker receipt; ACKState separately describes
// the gateway's terminal response. Neither field promises physical readback.
type KIOWriteResult struct {
	QID          int64     `json:"qid"`
	PublishState string    `json:"publish_state"`
	ACKState     string    `json:"ack_state"`
	PublishedAt  time.Time `json:"published_at"`
	SentAt       time.Time `json:"sent_at,omitempty"`
}

type kioAck struct {
	qid     int64
	step    int64
	success bool
}
type pendingKIOWrite struct {
	after  time.Time
	until  time.Time
	result chan kioAck
}

var nextQID atomic.Int64

func newQID() int64 {
	for {
		previous := nextQID.Load()
		candidate := time.Now().UnixMilli() * 1000
		if candidate <= previous {
			candidate = previous + 1
		}
		if nextQID.CompareAndSwap(previous, candidate) {
			return candidate
		}
	}
}

// PublishKIO never retries a physical write. The caller may run it in a bounded
// worker; no engine lock is needed while waiting. The pending Qid is installed
// before publish so even an ACK arriving before PUBACK cannot be lost.
func (c *Connection) PublishKIO(path string, value any, onPublished func(KIOWriteResult)) (KIOWriteResult, error) {
	result := KIOWriteResult{PublishState: "failed"}
	if !isKIO(c.source.Protocol) {
		return result, fmt.Errorf("source does not use KIO")
	}
	if c.source.ClientID == "" || c.source.Writer == "" {
		return result, fmt.Errorf("KIO client_id and writer required")
	}
	if strings.TrimSpace(path) == "" {
		return result, fmt.Errorf("KIO write path required")
	}
	select {
	case <-c.stop:
		return result, fmt.Errorf("source closed")
	default:
	}
	if c.Client == nil || !c.Client.IsConnectionOpen() {
		return result, fmt.Errorf("source offline")
	}
	result.QID = newQID()
	payload, err := buildKIOWrite(c.source.Writer, result.QID, path, value, c.auth, time.Now().UTC())
	if err != nil {
		return result, err
	}
	pending := &pendingKIOWrite{result: make(chan kioAck, 1)}
	timeout := time.Duration(c.source.ACKTimeoutMS) * time.Millisecond
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	c.pendingMu.Lock()
	if len(c.pending) >= maxPendingKIOWrites {
		c.pendingMu.Unlock()
		return result, fmt.Errorf("KIO pending write limit reached")
	}
	result.PublishedAt = time.Now().UTC()
	pending.after = result.PublishedAt
	pending.until = result.PublishedAt.Add(timeout)
	c.pending[result.QID] = pending
	c.pendingMu.Unlock()
	defer func() { c.pendingMu.Lock(); delete(c.pending, result.QID); c.pendingMu.Unlock() }()
	deadline := pending.until
	result.PublishState, err = c.publishBytes(KIOSetDataTopic(c.source.ClientID), payload)
	if err != nil {
		if result.PublishState == "unknown" {
			result.ACKState = "unknown"
		}
		return result, err
	}
	result.SentAt = time.Now().UTC()
	result.ACKState = "pending"
	if onPublished != nil {
		onPublished(result)
	}
	// Prefer an already received terminal ACK even if publishing or persisting
	// the sent state used the remaining timeout budget.
	select {
	case ack := <-pending.result:
		return finishKIOAck(result, ack)
	default:
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		result.ACKState = "unknown"
		return result, fmt.Errorf("KIO ACK timeout; do not retry automatically")
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case ack := <-pending.result:
		return finishKIOAck(result, ack)
	case <-timer.C:
		result.ACKState = "unknown"
		return result, fmt.Errorf("KIO ACK timeout; do not retry automatically")
	case <-c.stop:
		result.ACKState = "unknown"
		return result, fmt.Errorf("source closed before KIO ACK; do not retry automatically")
	}
}

func finishKIOAck(result KIOWriteResult, ack kioAck) (KIOWriteResult, error) {
	if ack.success {
		result.ACKState = "acknowledged"
		return result, nil
	}
	result.ACKState = "failed"
	return result, fmt.Errorf("KIO gateway reported terminal write failure")
}

func buildKIOWrite(writer string, qid int64, path string, value any, auth KIOAuth, at time.Time) ([]byte, error) {
	if value == nil {
		return nil, fmt.Errorf("KIO write value required")
	}
	// The V property uses numeric 0/1 for discrete writes; business code keeps
	// booleans and this protocol adapter owns their wire conversion.
	if b, ok := value.(bool); ok {
		value = 0
		if b {
			value = 1
		}
	}
	writeTime := at.Format("2006-01-02 15:04:05.000 -0700")
	payload := struct {
		Writer    string            `json:"Writer"`
		WriteTime string            `json:"WriteTime"`
		Username  string            `json:"Username,omitempty"`
		Password  string            `json:"Password,omitempty"`
		QID       int64             `json:"Qid"`
		PNs       map[string]string `json:"PNs"`
		PVs       map[string]any    `json:"PVs"`
		Objs      []map[string]any  `json:"Objs"`
	}{Writer: writer, WriteTime: writeTime, Username: auth.Username, Password: auth.Password, QID: qid,
		PNs: map[string]string{"1": "V", "2": "T", "3": "Q", "4": "F", "5": "S"},
		PVs: map[string]any{"1": 0, "2": writeTime, "3": 0}, Objs: []map[string]any{{"N": path, "1": value}}}
	b, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("invalid KIO write value")
	}
	return b, nil
}

func (c *Connection) handleKIOAck(message rawMessage) error {
	// Retained ACKs describe an earlier publication and cannot acknowledge a
	// newly issued physical command, even if an identifier happens to match.
	if message.retained {
		return nil
	}
	ack, present, err := parseKIOAck(message.payload)
	if err != nil || !present || ack.step != 100 {
		return err
	}
	c.pendingMu.Lock()
	defer c.pendingMu.Unlock()
	pending := c.pending[ack.qid]
	if pending == nil || message.receivedTime.Before(pending.after) || message.receivedTime.After(pending.until) {
		return nil
	}
	select {
	case pending.result <- ack:
	default:
	}
	return nil
}

func parseKIOAck(payload []byte) (kioAck, bool, error) {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(payload, &doc); err != nil {
		return kioAck{}, false, fmt.Errorf("invalid KIO ACK")
	}
	qidValue, present := doc["Qid"]
	if !present {
		qidValue, present = doc["qid"]
	}
	if !present {
		return kioAck{}, false, nil
	}
	qid, ok := jsonInteger(qidValue)
	if !ok || qid <= 0 {
		return kioAck{}, false, fmt.Errorf("invalid KIO ACK Qid")
	}
	step, ok := jsonInteger(doc["ProcessStep"])
	if !ok {
		return kioAck{}, false, fmt.Errorf("invalid KIO ACK ProcessStep")
	}
	ack := kioAck{qid: qid, step: step}
	if step != 100 {
		return ack, true, nil
	}
	result, present := doc["Result"]
	if !present {
		result, present = doc["result"]
	}
	var text string
	if !present || json.Unmarshal(result, &text) != nil {
		return kioAck{}, false, fmt.Errorf("invalid terminal KIO ACK Result")
	}
	ack.success = strings.EqualFold(strings.TrimSpace(text), "OK")
	return ack, true, nil
}

func jsonInteger(value json.RawMessage) (int64, bool) {
	text := strings.TrimSpace(string(value))
	if len(text) > 0 && text[0] == '"' {
		if json.Unmarshal(value, &text) != nil {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(text, 10, 64)
	return n, err == nil
}

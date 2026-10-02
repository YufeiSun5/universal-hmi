package acquisition

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

const (
	maxPayloadBytes      = 1024 * 1024
	defaultQueueCapacity = 128
	maxPendingKIOWrites  = 32
)

// ClientID is the KIO gateway identity used in its protocol topics. It is
// deliberately separate from the MQTT connection's own client identifier.
type Source struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Broker       string `json:"broker"`
	Topic        string `json:"topic"`
	Protocol     string `json:"protocol"`
	ClientID     string `json:"client_id,omitempty"`
	Writer       string `json:"writer,omitempty"`
	ACKTimeoutMS int    `json:"ack_timeout_ms,omitempty"`
}

type Raw struct {
	SourceID     string
	Topic        string
	Path         string
	Value        any
	Quality      string
	Time         time.Time
	ReceivedTime time.Time
	Retained     bool
}

// KIOAuth is ephemeral connection configuration, never a persisted Source or
// status field. Leave it empty for an unauthenticated local test gateway.
type KIOAuth struct {
	Username string `json:"-"`
	Password string `json:"-"`
}

type ConnectionOptions struct {
	QueueCapacity int     `json:"-"`
	KIOAuth       KIOAuth `json:"-"`
}

// All queue counters count MQTT messages, including ACKs, not samples.
// Accepted = Processed + Queued + InFlight. Received = Accepted + Dropped.
// Samples counts successfully decoded data rows delivered to the consumer.
type QueueStats struct {
	Received     uint64 `json:"received"`
	Accepted     uint64 `json:"accepted"`
	Processed    uint64 `json:"processed"`
	Dropped      uint64 `json:"dropped"`
	DecodeErrors uint64 `json:"decode_errors"`
	Queued       uint64 `json:"queued"`
	InFlight     uint64 `json:"in_flight"`
	Samples      uint64 `json:"samples"`
	Capacity     int    `json:"capacity"`
}

type rawMessage struct {
	topic        string
	payload      []byte
	receivedTime time.Time
	retained     bool
}

type Connection struct {
	Client    mqtt.Client `json:"-"`
	source    Source
	auth      KIOAuth
	submit    func([]Raw)
	state     func(string)
	queue     chan rawMessage
	queueMu   sync.Mutex
	stats     QueueStats
	closed    bool
	done      chan struct{}
	stop      chan struct{}
	closeOnce sync.Once
	pendingMu sync.Mutex
	pending   map[int64]*pendingKIOWrite
}

func newConnection(s Source, options ConnectionOptions, submit func([]Raw), state func(string)) (*Connection, error) {
	capacity := options.QueueCapacity
	if capacity == 0 {
		capacity = defaultQueueCapacity
	}
	if capacity < 1 || capacity > 4096 {
		return nil, fmt.Errorf("MQTT queue capacity must be between 1 and 4096")
	}
	if s.ACKTimeoutMS < 0 || s.ACKTimeoutMS > 30000 {
		return nil, fmt.Errorf("ACK timeout must be between 0 and 30000 milliseconds")
	}
	if submit == nil {
		submit = func([]Raw) {}
	}
	if state == nil {
		state = func(string) {}
	}
	c := &Connection{source: s, auth: options.KIOAuth, submit: submit, state: state, queue: make(chan rawMessage, capacity), done: make(chan struct{}), stop: make(chan struct{}), pending: make(map[int64]*pendingKIOWrite)}
	c.stats.Capacity = capacity
	go c.decodeLoop()
	return c, nil
}

func Connect(s Source, submit func([]Raw), state func(string)) (*Connection, error) {
	return ConnectWithOptions(s, ConnectionOptions{}, submit, state)
}

func ConnectWithOptions(s Source, options ConnectionOptions, submit func([]Raw), state func(string)) (*Connection, error) {
	c, err := newConnection(s, options, submit, state)
	if err != nil {
		return nil, err
	}
	topic := s.Topic
	if topic == "" && isKIO(s.Protocol) && s.ClientID != "" {
		topic = KIODataTopic(s.ClientID)
	}
	if topic == "" {
		c.Close()
		return nil, fmt.Errorf("subscription topic required")
	}
	opts := mqtt.NewClientOptions().AddBroker(s.Broker).SetClientID("hmi-" + s.ID).
		SetConnectTimeout(5 * time.Second).SetWriteTimeout(3 * time.Second).
		SetAutoReconnect(false).SetConnectRetry(false).SetCleanSession(true).
		SetOrderMatters(true)
	opts.OnConnectionLost = func(_ mqtt.Client, _ error) { c.state("offline: connection lost") }
	c.Client = mqtt.NewClient(opts)
	token := c.Client.Connect()
	if !token.WaitTimeout(6 * time.Second) {
		c.Close()
		return nil, fmt.Errorf("connect timeout")
	}
	if token.Error() != nil {
		c.Close()
		return nil, fmt.Errorf("MQTT connection failed")
	}
	topics := map[string]byte{topic: 0}
	if isKIO(s.Protocol) && s.ClientID != "" && s.Writer != "" {
		topics[KIOResultTopic(s.ClientID, s.Writer)] = 1
	}
	token = c.Client.SubscribeMultiple(topics, func(_ mqtt.Client, m mqtt.Message) {
		// The Paho callback only copies a bounded payload and enqueues it. A
		// single consumer owns JSON decoding and preserves arrival order.
		c.enqueue(m.Topic(), m.Payload(), m.Retained(), time.Now().UTC())
	})
	if !token.WaitTimeout(5 * time.Second) {
		c.Close()
		return nil, fmt.Errorf("subscribe timeout")
	}
	if token.Error() != nil {
		c.Close()
		return nil, fmt.Errorf("MQTT subscription failed")
	}
	c.state("connected")
	return c, nil
}

func (c *Connection) enqueue(topic string, payload []byte, retained bool, received time.Time) bool {
	c.queueMu.Lock()
	defer c.queueMu.Unlock()
	c.stats.Received++
	if c.closed || len(payload) > maxPayloadBytes || c.stats.Queued >= uint64(cap(c.queue)) {
		c.stats.Dropped++
		return false
	}
	message := rawMessage{topic: topic, payload: append([]byte(nil), payload...), retained: retained, receivedTime: received}
	c.queue <- message
	c.stats.Accepted++
	c.stats.Queued++
	return true
}

func (c *Connection) decodeLoop() {
	defer close(c.done)
	for message := range c.queue {
		c.queueMu.Lock()
		c.stats.Queued--
		c.stats.InFlight++
		c.queueMu.Unlock()
		var err error
		var count uint64
		if isKIO(c.source.Protocol) && message.topic == KIOResultTopic(c.source.ClientID, c.source.Writer) {
			err = c.handleKIOAck(message)
		} else {
			var rows []Raw
			rows, err = Decode(c.source.ID, message.topic, c.source.Protocol, message.payload)
			if err == nil && len(rows) > 0 {
				for i := range rows {
					rows[i].Retained = message.retained
					rows[i].ReceivedTime = message.receivedTime
				}
				c.submit(rows)
				count = uint64(len(rows))
			}
		}
		c.queueMu.Lock()
		c.stats.InFlight--
		c.stats.Processed++
		c.stats.Samples += count
		if err != nil {
			c.stats.DecodeErrors++
		}
		c.queueMu.Unlock()
		if err != nil {
			c.state("payload error: invalid protocol message")
		}
	}
}

func (c *Connection) Stats() QueueStats {
	c.queueMu.Lock()
	defer c.queueMu.Unlock()
	return c.stats
}

func (c *Connection) Close() {
	c.closeOnce.Do(func() {
		close(c.stop)
		if c.Client != nil {
			c.Client.Disconnect(100)
		}
		c.queueMu.Lock()
		c.closed = true
		close(c.queue)
		c.queueMu.Unlock()
		<-c.done
	})
}

func (c *Connection) Publish(topic string, value any) (string, error) {
	b, err := json.Marshal(value)
	if err != nil {
		return "failed", fmt.Errorf("invalid write value")
	}
	return c.publishBytes(topic, b)
}

func (c *Connection) publishBytes(topic string, payload []byte) (string, error) {
	if c.Client == nil || !c.Client.IsConnectionOpen() {
		return "failed", fmt.Errorf("source offline")
	}
	token := c.Client.Publish(topic, 1, false, payload)
	if !token.WaitTimeout(3 * time.Second) {
		return "unknown", fmt.Errorf("publish confirmation timeout; do not retry automatically")
	}
	if token.Error() != nil {
		return "failed", fmt.Errorf("MQTT publish failed")
	}
	return "sent", nil // PUBACK confirms broker receipt only, never PLC execution.
}

package acquisition

import (
	"encoding/json"
	"errors"
	"fmt"
	mqtt "github.com/eclipse/paho.mqtt.golang"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestKIODefaultsOnlyForPresentObjects(t *testing.T) {
	payload := `{"Objs":[{"N":"s1.temp","1":25.3,"2":150},{"N":"s2.temp","2":0},{"N":"s3.status","1":false,"2":-100,"3":0},{"N":"null","1":null},{"N":"null.quality","1":7,"3":null}],"PVs":{"1":12,"2":"2026-06-08 10:30:00.000 +0800","3":192}}`
	rows, err := Decode("source-a", "topic", "kingio", []byte(payload))
	if err != nil || len(rows) != 4 {
		t.Fatalf("rows=%+v error=%v", rows, err)
	}
	base := time.Date(2026, 6, 8, 2, 30, 0, 0, time.UTC)
	if rows[0].Path != "s1.temp" || rows[0].Value != 25.3 || rows[0].Quality != "good" || !rows[0].Time.Equal(base.Add(150*time.Millisecond)) {
		t.Fatalf("explicit: %+v", rows[0])
	}
	if rows[1].Value != float64(12) || !rows[1].Time.Equal(base) || rows[1].Quality != "good" {
		t.Fatalf("defaults: %+v", rows[1])
	}
	if rows[2].Value != false || rows[2].Quality != "bad" || !rows[2].Time.Equal(base.Add(-100*time.Millisecond)) || rows[3].Quality != "bad" {
		t.Fatalf("explicit false/bad/null: %+v", rows)
	}
	for _, r := range rows {
		if r.SourceID != "source-a" || r.Topic != "topic" {
			t.Fatalf("identity lost: %+v", r)
		}
	}
	for _, p := range []string{`{"PVs":{"1":2}}`, `{"Objs":[],"PVs":{"1":2}}`, `{"Objs":[{"N":"only","1":null}],"PVs":{"1":2}}`} {
		rows, err := Decode("s", "t", "kingio", []byte(p))
		if err != nil || len(rows) != 0 {
			t.Fatalf("fabricated rows: %s %+v %v", p, rows, err)
		}
	}
}

func TestKIOMalformedBaseNeverTreatsOffsetAsEpoch(t *testing.T) {
	for _, base := range []string{`"bad"`, `null`, `-1`, `0`, `{}`} {
		p := fmt.Sprintf(`{"Objs":[{"N":"p","1":1,"2":150,"3":192}],"PVs":{"2":%s}}`, base)
		if rows, err := Decode("s", "t", "kingio", []byte(p)); err == nil {
			t.Fatalf("base %s became epoch: %+v", base, rows)
		}
	}
	rows, err := Decode("s", "t", "kingio", []byte(`{"Objs":[{"N":"p","1":1,"2":150}],"PVs":{"2":"bad"},"WriteTime":"2026-06-08T02:30:00Z"}`))
	if err != nil || len(rows) != 1 || rows[0].Time.Year() != 2026 || rows[0].Quality != "bad" {
		t.Fatalf("fallback: %+v %v", rows, err)
	}
}

func TestKIOAbsoluteTimeAndQuality(t *testing.T) {
	rows, err := Decode("s", "t", "kingio", []byte(`{"Objs":[{"N":"seconds","1":1,"2":1700000000,"3":192},{"N":"milliseconds","1":2,"2":1700000000000,"3":"192"},{"N":"text","1":3,"2":"2026-06-08T02:30:00.150Z","3":191},{"N":"missing","1":4,"2":"2026-06-08T02:30:00Z"}]}`))
	if err != nil || len(rows) != 4 {
		t.Fatalf("%+v %v", rows, err)
	}
	if !rows[0].Time.Equal(rows[1].Time) || rows[0].Quality != "good" || rows[1].Quality != "good" || rows[2].Quality != "bad" || rows[3].Quality != "bad" {
		t.Fatalf("%+v", rows)
	}
}

func TestKIOWriteShapeAndEphemeralAuth(t *testing.T) {
	auth := KIOAuth{Username: "local-test-user", Password: "ephemeral-test-password"}
	b, err := buildKIOWrite("test-writer", 123, "s1.SP", true, auth, time.Date(2026, 6, 8, 2, 30, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if err = json.Unmarshal(b, &wire); err != nil {
		t.Fatal(err)
	}
	obj := wire["Objs"].([]any)[0].(map[string]any)
	if wire["Qid"] != float64(123) || wire["Writer"] != "test-writer" || obj["N"] != "s1.SP" || obj["1"] != float64(1) || wire["WriteTime"] != "2026-06-08 02:30:00.000 +0000" {
		t.Fatal("incorrect wire contract")
	}
	if wire["Username"] != auth.Username || wire["Password"] != auth.Password || wire["PNs"].(map[string]any)["1"] != "V" {
		t.Fatal("ephemeral auth/PNs missing")
	}
	b, err = json.Marshal(ConnectionOptions{KIOAuth: auth})
	if err != nil || strings.Contains(string(b), auth.Username) || strings.Contains(string(b), auth.Password) {
		t.Fatal("authentication serialized")
	}
	b, err = json.Marshal(Source{ClientID: "g", Writer: "w"})
	if err != nil || strings.Contains(string(b), "password") || strings.Contains(string(b), "username") {
		t.Fatal("Source contains authentication")
	}
	if KIODataTopic("g") != "datachange_g" || KIOSetDataTopic("g") != "setdata_g" || KIOResultTopic("g", "w") != "setdata_result_g_w" || KIOQueryAllTopic("g") != "Query_AllKIOTags_g" {
		t.Fatal("incorrect topics")
	}
}

type testToken struct {
	mqtt.Token
	confirmed bool
	err       error
}

func (t testToken) WaitTimeout(time.Duration) bool { return t.confirmed }
func (t testToken) Error() error                   { return t.err }

type testClient struct {
	mqtt.Client
	publish   func(string, byte, bool, interface{}) mqtt.Token
	mu        sync.Mutex
	open      bool
	publishes int
}

func (c *testClient) IsConnectionOpen() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.open }
func (c *testClient) Disconnect(uint)        { c.mu.Lock(); c.open = false; c.mu.Unlock() }
func (c *testClient) Publish(topic string, qos byte, retained bool, payload interface{}) mqtt.Token {
	c.mu.Lock()
	c.publishes++
	c.mu.Unlock()
	if c.publish != nil {
		return c.publish(topic, qos, retained, payload)
	}
	return testToken{confirmed: true}
}
func (c *testClient) count() int { c.mu.Lock(); defer c.mu.Unlock(); return c.publishes }
func newTestKIO(t *testing.T, timeout int) (*Connection, *testClient) {
	t.Helper()
	c, err := newConnection(Source{ID: "s", Protocol: "kingio", ClientID: "gateway", Writer: "writer", ACKTimeoutMS: timeout}, ConnectionOptions{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	client := &testClient{open: true}
	c.Client = client
	t.Cleanup(c.Close)
	return c, client
}
func enqueueAck(c *Connection, qid int64, step int, result string, retained bool, at time.Time) {
	c.enqueue(KIOResultTopic("gateway", "writer"), []byte(fmt.Sprintf(`{"Qid":%d,"ProcessStep":%d,"Result":%q}`, qid, step, result)), retained, at)
}
func waitForProcessed(t *testing.T, c *Connection, count uint64) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if c.Stats().Processed >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("not processed: %+v", c.Stats())
}

func TestKIOAckMatchesOnlyFreshNonRetainedTerminalQid(t *testing.T) {
	c, client := newTestKIO(t, 1000)
	sent := make(chan KIOWriteResult, 1)
	done := make(chan KIOWriteResult, 1)
	errs := make(chan error, 1)
	go func() { r, e := c.PublishKIO("s.SP", 1, func(r KIOWriteResult) { sent <- r }); done <- r; errs <- e }()
	p := <-sent
	if p.PublishState != "sent" || p.ACKState != "pending" || p.PublishedAt.IsZero() || p.SentAt.Before(p.PublishedAt) {
		t.Fatalf("sent stage: %+v", p)
	}
	enqueueAck(c, p.QID+1, 100, "OK", false, time.Now())
	enqueueAck(c, p.QID, 50, "OK", false, time.Now())
	enqueueAck(c, p.QID, 100, "OK", true, time.Now())
	enqueueAck(c, p.QID, 100, "OK", false, p.PublishedAt.Add(-time.Millisecond))
	waitForProcessed(t, c, 4)
	select {
	case r := <-done:
		t.Fatalf("unrelated/intermediate/stale response accepted: %+v", r)
	default:
	}
	enqueueAck(c, p.QID, 100, " oK ", false, time.Now())
	r := <-done
	if e := <-errs; e != nil || r.ACKState != "acknowledged" || r.PublishState != "sent" {
		t.Fatalf("%+v %v", r, e)
	}
	if client.count() != 1 {
		t.Fatal("write retried")
	}
	c.pendingMu.Lock()
	remaining := len(c.pending)
	c.pendingMu.Unlock()
	if remaining != 0 {
		t.Fatal("pending leak")
	}
}

func TestKIOAckBeforePUBACKIsNotLost(t *testing.T) {
	c, client := newTestKIO(t, 1000)
	client.publish = func(topic string, qos byte, retained bool, payload interface{}) mqtt.Token {
		if topic != "setdata_gateway" || qos != 1 || retained {
			t.Errorf("incorrect publish options: %s %d %v", topic, qos, retained)
		}
		var wire struct {
			QID int64 `json:"Qid"`
		}
		if e := json.Unmarshal(payload.([]byte), &wire); e != nil {
			t.Error(e)
		}
		enqueueAck(c, wire.QID, 100, "OK", false, time.Now())
		waitForProcessed(t, c, 1)
		return testToken{confirmed: true}
	}
	r, e := c.PublishKIO("p", 1, nil)
	if e != nil || r.ACKState != "acknowledged" {
		t.Fatalf("%+v %v", r, e)
	}
}

func TestKIOFailureTimeoutAndPublishStates(t *testing.T) {
	for _, tt := range []struct {
		name                   string
		ack, confirmed         bool
		brokerError            error
		publishState, ackState string
	}{
		{name: "terminal failure", ack: true, confirmed: true, publishState: "sent", ackState: "failed"},
		{name: "ACK timeout", confirmed: true, publishState: "sent", ackState: "unknown"},
		{name: "PUBACK timeout", publishState: "unknown", ackState: "unknown"},
		{name: "broker failure", confirmed: true, brokerError: errors.New("private broker details"), publishState: "failed"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			c, client := newTestKIO(t, 25)
			client.publish = func(_ string, _ byte, _ bool, payload interface{}) mqtt.Token {
				if tt.ack {
					var wire struct {
						QID int64 `json:"Qid"`
					}
					json.Unmarshal(payload.([]byte), &wire)
					enqueueAck(c, wire.QID, 100, "FAILED", false, time.Now())
				}
				return testToken{confirmed: tt.confirmed, err: tt.brokerError}
			}
			callbacks := 0
			r, e := c.PublishKIO("p", 1, func(KIOWriteResult) { callbacks++ })
			if e == nil || r.PublishState != tt.publishState || r.ACKState != tt.ackState {
				t.Fatalf("%+v %v", r, e)
			}
			if strings.Contains(e.Error(), "private broker") {
				t.Fatal("unfiltered error")
			}
			if (callbacks == 1) != (tt.publishState == "sent") || client.count() != 1 {
				t.Fatalf("callbacks=%d publishes=%d", callbacks, client.count())
			}
		})
	}
}

func TestKIOPendingBoundAndClose(t *testing.T) {
	c, client := newTestKIO(t, 1000)
	c.pendingMu.Lock()
	for i := int64(1); i <= maxPendingKIOWrites; i++ {
		c.pending[i] = &pendingKIOWrite{}
	}
	c.pendingMu.Unlock()
	r, e := c.PublishKIO("p", 1, nil)
	if e == nil || r.PublishState != "failed" || client.count() != 0 {
		t.Fatal("pending bound not enforced")
	}
	c.pendingMu.Lock()
	clear(c.pending)
	c.pendingMu.Unlock()
	sent := make(chan struct{})
	done := make(chan KIOWriteResult)
	go func() { r, _ := c.PublishKIO("p", 1, func(KIOWriteResult) { close(sent) }); done <- r }()
	<-sent
	c.Close()
	if r = <-done; r.ACKState != "unknown" || r.PublishState != "sent" {
		t.Fatalf("closed: %+v", r)
	}
}

func TestKIOAckRejectsLooseSuccessAliases(t *testing.T) {
	for _, p := range []string{`{"Qid":1,"ProcessStep":100,"Success":true}`, `{"Qid":1,"ProcessStep":100,"Result":true}`, `{"Qid":1.5,"ProcessStep":100,"Result":"OK"}`} {
		if _, _, e := parseKIOAck([]byte(p)); e == nil {
			t.Fatalf("malformed ACK accepted: %s", p)
		}
	}
	a, p, e := parseKIOAck([]byte(`{"qid":"123","ProcessStep":100,"result":"oK"}`))
	if e != nil || !p || !a.success || a.qid != 123 {
		t.Fatalf("%+v %v %v", a, p, e)
	}
}

func TestKIOConcurrentWritesCorrelateReversedAcknowledgements(t *testing.T) {
	c, client := newTestKIO(t, 1000)
	sent := make(chan KIOWriteResult, 2)
	results := make(chan KIOWriteResult, 2)
	var callers sync.WaitGroup
	for i := 0; i < 2; i++ {
		callers.Add(1)
		go func(value int) {
			defer callers.Done()
			r, _ := c.PublishKIO(fmt.Sprintf("station%d.SP", value), value, func(r KIOWriteResult) { sent <- r })
			results <- r
		}(i)
	}
	first, second := <-sent, <-sent
	if first.QID == second.QID {
		t.Fatal("Qid collision")
	}
	enqueueAck(c, second.QID, 100, "FAILED", false, time.Now())
	enqueueAck(c, first.QID, 100, "OK", false, time.Now())
	callers.Wait()
	received := map[int64]string{}
	for i := 0; i < 2; i++ {
		r := <-results
		received[r.QID] = r.ACKState
	}
	if received[first.QID] != "acknowledged" || received[second.QID] != "failed" || client.count() != 2 {
		t.Fatalf("cross-correlated writes: %+v", received)
	}
}

func TestKIOLateAckCannotWinAfterDeadline(t *testing.T) {
	c, _ := newTestKIO(t, 20)
	r, e := c.PublishKIO("p", 1, func(p KIOWriteResult) {
		enqueueAck(c, p.QID, 100, "OK", false, p.PublishedAt.Add(time.Second))
		waitForProcessed(t, c, 1)
	})
	if e == nil || r.ACKState != "unknown" {
		t.Fatalf("late ACK confirmed: %+v %v", r, e)
	}
}

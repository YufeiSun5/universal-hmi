package acquisition

import (
	"encoding/json"
	"testing"
	"time"
)

func TestMQTTQueueBoundedOrderedCopiesPayloadAndCountsMessages(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	rows := make(chan []Raw, 2)
	c, e := newConnection(Source{ID: "s", Protocol: "generic"}, ConnectionOptions{QueueCapacity: 1}, func(batch []Raw) {
		rows <- batch
		if batch[0].Path == "first" {
			close(entered)
			<-release
		}
	}, nil)
	if e != nil {
		t.Fatal(e)
	}
	at := time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)
	first := []byte(`{"points":[{"path":"first","value":1,"quality":"good","timestamp":"2026-10-02T00:00:00Z"}]}`)
	second := []byte(`{"points":[{"path":"second","value":2,"quality":"good","timestamp":"2026-10-02T00:00:00Z"},{"path":"third","value":3,"quality":"good","timestamp":"2026-10-02T00:00:00Z"}]}`)
	if !c.enqueue("data", first, true, at) {
		t.Fatal("first rejected")
	}
	<-entered
	if !c.enqueue("data", second, false, at.Add(time.Second)) {
		t.Fatal("second rejected")
	}
	for i := range second {
		second[i] = 'x'
	}
	if c.enqueue("data", first, false, at) || c.enqueue("data", make([]byte, maxPayloadBytes+1), false, at) {
		t.Fatal("bounds ignored")
	}
	s := c.Stats()
	if s.Received != 4 || s.Accepted != 2 || s.Processed != 0 || s.InFlight != 1 || s.Queued != 1 || s.Dropped != 2 {
		t.Fatalf("active counters: %+v", s)
	}
	close(release)
	c.Close()
	a, b := <-rows, <-rows
	if !a[0].Retained || !a[0].ReceivedTime.Equal(at) || b[0].Retained || b[0].Path != "second" || len(b) != 2 {
		t.Fatalf("metadata/order/copy lost: %+v %+v", a, b)
	}
	s = c.Stats()
	if s.Accepted != 2 || s.Processed != 2 || s.Samples != 3 || s.Queued != 0 || s.InFlight != 0 || s.DecodeErrors != 0 {
		t.Fatalf("message/sample counters: %+v", s)
	}
	if c.enqueue("data", first, false, at) {
		t.Fatal("closed queue accepted")
	}
}

func TestMQTTDecodeErrorsAndEmptyDeltasAreProcessedMessages(t *testing.T) {
	c, e := newConnection(Source{ID: "s", Protocol: "kingio"}, ConnectionOptions{}, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	c.enqueue("data", []byte(`{"Objs":broken}`), false, time.Now())
	c.enqueue("data", []byte(`{"PVs":{"1":7}}`), false, time.Now())
	c.Close()
	s := c.Stats()
	if s.Accepted != 2 || s.Processed != 2 || s.DecodeErrors != 1 || s.Samples != 0 || s.Queued != 0 || s.InFlight != 0 {
		t.Fatalf("%+v", s)
	}
	b, e := json.Marshal(s)
	if e != nil {
		t.Fatal(e)
	}
	var doc map[string]any
	json.Unmarshal(b, &doc)
	for _, k := range []string{"accepted", "processed", "dropped", "decode_errors", "queued", "in_flight", "samples"} {
		if _, ok := doc[k]; !ok {
			t.Fatalf("missing counter %s", k)
		}
	}
}

func TestMQTTPayloadErrorsDoNotChangeTransportState(t *testing.T) {
	for _, transportState := range []string{"connected", "offline: connection lost"} {
		t.Run(transportState, func(t *testing.T) {
			state := transportState
			var rows []Raw
			c, err := newConnection(Source{ID: "s", Protocol: "kingio", ClientID: "gateway", Writer: "writer"}, ConnectionOptions{}, func(batch []Raw) {
				rows = append(rows, batch...)
			}, func(next string) { state = next })
			if err != nil {
				t.Fatal(err)
			}
			at := time.Now().UTC()
			// Retention deletion and malformed data/ACK are packet errors,
			// not transport failures. Later valid rows must still be delivered.
			for _, packet := range []struct{ topic, payload string }{
				{"data", ""},
				{"data", `{"Objs":broken}`},
				{KIOResultTopic("gateway", "writer"), "{"},
				{"data", `{"Objs":[{"N":"good","1":42,"2":1700000000000,"3":192},{"N":"bad","1":7,"2":1700000000000,"3":0}]}`},
			} {
				if !c.enqueue(packet.topic, []byte(packet.payload), false, at) {
					t.Fatal("packet rejected")
				}
			}
			c.Close() // Drain the worker before inspecting callback-owned data.
			if state != transportState {
				t.Fatalf("payload changed transport state: got %q, want %q", state, transportState)
			}
			if len(rows) != 2 || rows[0].Quality != "good" || rows[1].Quality != "bad" || rows[0].Value != float64(42) {
				t.Fatalf("valid data or its quality was changed: %+v", rows)
			}
			s := c.Stats()
			if s.Received != 4 || s.Accepted != 4 || s.Processed != 4 || s.DecodeErrors != 3 || s.Samples != 2 || s.Dropped != 0 || s.Queued != 0 || s.InFlight != 0 {
				t.Fatalf("packet error evidence lost: %+v", s)
			}
		})
	}
}

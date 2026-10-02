package runtime

import (
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	mqtt "github.com/eclipse/paho.mqtt.golang"
)

func localBroker(t *testing.T) string {
	t.Helper()
	binary, err := exec.LookPath("mosquitto")
	if err != nil {
		t.Skip("mosquitto required for local MQTT integration")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	cmd := exec.Command(binary, "-p", fmt.Sprint(port))
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 50*time.Millisecond)
		if err == nil {
			c.Close()
			return fmt.Sprintf("tcp://127.0.0.1:%d", port)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("local MQTT broker did not start")
	return ""
}
func waitCommand(t *testing.T, e *Engine, id string, state string) Result {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r, err := e.Command(id)
		if err == nil && r.State == state {
			return r
		}
		time.Sleep(5 * time.Millisecond)
	}
	r, _ := e.Command(id)
	t.Fatalf("command wanted %s got %+v", state, r)
	return r
}
func mqttPublish(t *testing.T, c mqtt.Client, topic string, value any) {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	token := c.Publish(topic, 1, false, payload)
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatalf("publish %s: %v", topic, token.Error())
	}
}
func receiveWrite(t *testing.T, ch <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(2 * time.Second):
		t.Fatal("physical write not published")
		return nil
	}
}

func TestLocalKIOWriteACKReadbackDedupeAndAcquisitionDuringWait(t *testing.T) {
	broker := localBroker(t)
	e, ps := setup(t)
	source := acquisition.Source{ID: "kio", Name: "local fixture", Protocol: "kingio", Broker: broker, Topic: "datachange_fixture", ClientID: "fixture", Writer: "hmi", ACKTimeoutMS: 1000}
	if err := e.Sources([]acquisition.Source{source}); err != nil {
		t.Fatal(err)
	}
	if err := e.Connect(source.ID); err != nil {
		t.Fatal(err)
	}
	client := mqtt.NewClient(mqtt.NewClientOptions().AddBroker(broker).SetClientID("fixture-device"))
	token := client.Connect()
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("fixture connect failed")
	}
	defer client.Disconnect(10)
	writes := make(chan map[string]any, 16)
	var published atomic.Int64
	token = client.Subscribe("setdata_fixture", 1, func(_ mqtt.Client, m mqtt.Message) {
		var value map[string]any
		if json.Unmarshal(m.Payload(), &value) == nil {
			published.Add(1)
			writes <- value
		}
	})
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("fixture subscribe failed")
	}
	scale := 2.0
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "float", DataType: "FLOAT", SourceType: "mqtt", SourceID: "kio", SourcePath: "read.float", Topic: source.Topic, ScaleFactor: &scale, Offset: 10, Writable: true, RWMode: "RW", WritePath: "write.float"})
	if err != nil {
		t.Fatal(err)
	}
	version, _ := e.Apply()
	w := Write{CommandID: "physical-float", PointID: p.ID, Value: 50, Version: version}
	started := time.Now()
	result, err := e.Write(w)
	if err != nil || result.State != "accepted" || time.Since(started) > 200*time.Millisecond {
		t.Fatalf("write waited for ACK %+v %v", result, err)
	}
	wire := receiveWrite(t, writes)
	object := wire["Objs"].([]any)[0].(map[string]any)
	if object["N"] != "write.float" || object["1"] != 20.0 {
		t.Fatalf("inverse/write path %+v", wire)
	}
	qid := int64(wire["Qid"].(float64))
	waitCommand(t, e, w.CommandID, "sent")
	publishData := func(value float64, at time.Time) {
		mqttPublish(t, client, source.Topic, map[string]any{"PVs": map[string]any{"2": at.Format(time.RFC3339Nano), "3": 192}, "Objs": []any{map[string]any{"N": "read.float", "1": value}}})
	}
	// Sampling continues while no ACK has arrived; a wrong value cannot confirm.
	publishData(1, time.Now())
	deadline := time.Now().Add(300 * time.Millisecond)
	observed := false
	for time.Now().Before(deadline) {
		e.mu.Lock()
		sample := e.live[p.ID]
		e.mu.Unlock()
		if sample.Raw == 1.0 {
			observed = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !observed {
		t.Fatal("ACK wait blocked acquisition")
	}
	ack := func(q int64, step int, text string) {
		mqttPublish(t, client, "setdata_result_fixture_hmi", map[string]any{"Qid": q, "ProcessStep": step, "Result": text})
	}
	ack(qid+1, 100, "OK")
	ack(qid, 50, "OK")
	time.Sleep(20 * time.Millisecond)
	r, _ := e.Command(w.CommandID)
	if r.State != "sent" {
		t.Fatalf("nonterminal/mismatched ACK accepted %+v", r)
	}
	ack(qid, 100, "oK")
	waitCommand(t, e, w.CommandID, "acknowledged")
	publishData(20, started.Add(-time.Minute))
	time.Sleep(20 * time.Millisecond)
	r, _ = e.Command(w.CommandID)
	if r.State != "acknowledged" {
		t.Fatal("predating sample confirmed command")
	}
	publishData(20, time.Now())
	r = waitCommand(t, e, w.CommandID, "readback_confirmed")
	if r.PublishState != "sent" || r.ACKState != "acknowledged" || r.ReadbackState != "confirmed" || r.ReadbackAt == nil {
		t.Fatalf("stages not separate %+v", r)
	}
	if _, err = e.Write(w); err != nil {
		t.Fatal(err)
	}
	conflict := w
	conflict.Value = 51
	if _, err = e.Write(conflict); err == nil {
		t.Fatal("same ID different payload accepted")
	}
	if published.Load() != 1 {
		t.Fatal("duplicate physical publication")
	}
	// Timeout stays unknown and durable; repeating exactly the request never replays.
	timeout := Write{CommandID: "physical-timeout", PointID: p.ID, Value: 52, Version: version}
	e.Write(timeout)
	receiveWrite(t, writes)
	waitCommand(t, e, timeout.CommandID, "unknown")
	e.Write(timeout)
	time.Sleep(20 * time.Millisecond)
	if published.Load() != 2 {
		t.Fatal("unknown command automatically replayed")
	}
	// Numeric codecs: BOOL 0/1 and fractional engineering values for scaled INT.
	for _, spec := range []struct {
		name, kind         string
		scale, value, want float64
	}{{"bool", "BOOL", 1, 1, 1}, {"int", "INT", .1, 1.2, 12}} {
		factor := spec.scale
		point, err := ps.Create(points.CreateInput{Station: "A", Name: spec.name, DataType: spec.kind, SourceType: "mqtt", SourceID: "kio", SourcePath: "read." + spec.name, Topic: source.Topic, ScaleFactor: &factor, Writable: true, RWMode: "W"})
		if err != nil {
			t.Fatal(err)
		}
		version, _ = e.Apply()
		if !e.WriteCapability(point.ID).Writable {
			t.Fatal("valid codec unavailable")
		}
		command := Write{CommandID: "physical-" + spec.name, PointID: point.ID, Value: spec.value, Version: version}
		if _, err = e.Write(command); err != nil {
			t.Fatal(err)
		}
		wire = receiveWrite(t, writes)
		object = wire["Objs"].([]any)[0].(map[string]any)
		if object["1"] != spec.want {
			t.Fatalf("%s codec %+v", spec.kind, object)
		}
		ack(int64(wire["Qid"].(float64)), 100, "OK")
		waitCommand(t, e, command.CommandID, "acknowledged")
	}
	// Four pending ACK waits saturate workers. A queued command must be revalidated
	// after the active configuration changes, without any fifth publication.
	blockers := make([]int64, 0, 4)
	for i := 0; i < 4; i++ {
		command := Write{CommandID: fmt.Sprintf("queue-blocker-%d", i), PointID: p.ID, Value: 50, Version: version}
		if _, err = e.Write(command); err != nil {
			t.Fatal(err)
		}
		wire = receiveWrite(t, writes)
		blockers = append(blockers, int64(wire["Qid"].(float64)))
	}
	before := published.Load()
	queued := Write{CommandID: "queued-stale-config", PointID: p.ID, Value: 60, Version: version}
	if r, err := e.Write(queued); err != nil || r.State != "accepted" {
		t.Fatalf("queue admission %+v %v", r, err)
	}
	_, err = ps.Create(points.CreateInput{Station: "A", Name: "changed configuration", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	e.Apply()
	for _, q := range blockers {
		ack(q, 100, "OK")
	}
	r = waitCommand(t, e, queued.CommandID, "failed")
	if r.PublishState != "not_sent" || published.Load() != before {
		t.Fatalf("stale queued command published %+v count=%d/%d", r, published.Load(), before)
	}

}

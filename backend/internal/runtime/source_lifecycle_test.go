package runtime

import (
	"encoding/json"
	"github.com/eclipse/paho.mqtt.golang/packets"
	"net"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	mqtt "github.com/eclipse/paho.mqtt.golang"
)

func TestStartupAndRedundantKingIO(t *testing.T) {
	primary := startLocalBroker(t, 0)
	backup := localBroker(t)
	original, ps := setup(t)
	source := acquisition.Source{ID: "line", Protocol: "kingio", Broker: primary.url, Topic: "datachange_main", ClientID: "main", Writer: "hmi", Standby: &acquisition.StandbyEndpoint{Broker: backup, ClientID: "spare"}}
	manual := source
	manual.ID = "manual"
	manual.ManualStart = true
	if err := original.Sources([]acquisition.Source{source, manual}); err != nil {
		t.Fatal(err)
	}
	p, err := ps.Create(points.CreateInput{Station: "west", Name: "pressure", DataType: "FLOAT", SourceType: "mqtt", SourceID: "line", SourcePath: "P", Topic: source.Topic, Writable: true, RWMode: "RW"})
	if err != nil {
		t.Fatal(err)
	}
	original.Close()
	e, err := New(ps, original.Store)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	publish := func(broker, topic string, v int) {
		client := mqtt.NewClient(mqtt.NewClientOptions().AddBroker(broker).SetClientID("fixture"))
		token := client.Connect()
		if !token.WaitTimeout(2*time.Second) || token.Error() != nil {
			t.Fatal("fixture publisher unavailable")
		}
		defer client.Disconnect(10)
		data, _ := json.Marshal(map[string]any{"PVs": map[string]any{"2": time.Now().UTC().Format(time.RFC3339Nano), "3": 192}, "Objs": []any{map[string]any{"N": "P", "1": v}}})
		token = client.Publish(topic, 1, true, data)
		if !token.WaitTimeout(2*time.Second) || token.Error() != nil {
			t.Fatal("fixture publish failed")
		}
	}
	wait := func(value float64, standby bool) {
		t.Helper()
		for deadline := time.Now().Add(18 * time.Second); time.Now().Before(deadline); {
			e.mu.Lock()
			sample := e.live[p.ID]
			ok := sample.Value == value && e.standbyActive[source.ID] == standby && e.sourceState[source.ID] == "connected" && e.sourceRuns["manual"] == nil
			e.mu.Unlock()
			if ok {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("point %s did not receive %v (standby=%t)", p.ID, value, standby)
	}
	publish(primary.url, source.Topic, 11)
	publish(backup, "datachange_spare", 22)
	e.StartSavedSources()
	e.StartSavedSources()
	wait(11, false)
	primary.stop()
	wait(22, true)
	device := mqtt.NewClient(mqtt.NewClientOptions().AddBroker(backup).SetClientID("standby-device"))
	token := device.Connect()
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("standby device unavailable")
	}
	defer device.Disconnect(10)
	writes := make(chan map[string]any, 4)
	token = device.Subscribe("setdata_spare", 1, func(_ mqtt.Client, m mqtt.Message) {
		var v map[string]any
		if json.Unmarshal(m.Payload(), &v) == nil {
			writes <- v
		}
	})
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("write monitor unavailable")
	}
	command := Write{CommandID: "standby-command", PointID: p.ID, Value: 24, Version: e.WriteCapability(p.ID).Version}
	if _, err = e.Write(command); err != nil {
		t.Fatal(err)
	}
	wire := receiveWrite(t, writes)
	obj := wire["Objs"].([]any)[0].(map[string]any)
	if obj["N"] != "P" || obj["1"] != 24.0 {
		t.Fatalf("standby received unexpected write %+v", obj)
	}
	waitCommand(t, e, command.CommandID, "sent")
	mqttPublish(t, device, "setdata_result_spare_hmi", map[string]any{"Qid": wire["Qid"], "ProcessStep": 100, "Result": "OK"})
	waitCommand(t, e, command.CommandID, "acknowledged")
	publish(backup, "datachange_spare", 24)
	waitCommand(t, e, command.CommandID, "readback_confirmed")
	primary = startLocalBroker(t, primary.port)
	publish(primary.url, source.Topic, 33)
	wait(33, false)
	if result, err := e.Write(command); err != nil || result.State != "readback_confirmed" {
		t.Fatalf("previous command not deduplicated: %+v %v", result, err)
	}
	e.Disconnect(source.ID)
	if page, err := e.Discovery(source.ID, "", 0, 10); err != nil || page.Connected || page.State != "disconnected" {
		t.Fatalf("manual disconnect: %+v %v", page, err)
	}
}

func TestStandbyTopicMapping(t *testing.T) {
	for _, tt := range []struct{ primary, standby, topic, want string }{
		{"main/+/value/#", "backup/site/+/data/#", "backup/site/one/data/a/b", "main/one/value/a/b"},
		{"p/#", "b/#", "b", "p"}, {"p/#", "b/#", "b/", "p/"}, {"primary", "secondary", "secondary", "primary"},
	} {
		if got := logicalTopic(tt.primary, tt.standby, tt.topic); got != tt.want {
			t.Errorf("%q != %q", got, tt.want)
		}
	}
}

// The TCP connection succeeds, but the primary explicitly denies its subscription.
func TestRejectedPrimarySubscriptionSelectsStandby(t *testing.T) {
	backup := localBroker(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	denied := make(chan error, 1)
	go func() {
		c, err := listener.Accept()
		if err != nil {
			denied <- err
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err = packets.ReadPacket(c); err == nil {
			err = packets.NewControlPacket(packets.Connack).Write(c)
		}
		if err == nil {
			var packet packets.ControlPacket
			packet, err = packets.ReadPacket(c)
			if sub, ok := packet.(*packets.SubscribePacket); ok {
				ack := packets.NewControlPacket(packets.Suback).(*packets.SubackPacket)
				ack.MessageID = sub.MessageID
				ack.ReturnCodes = []byte{0x80}
				err = ack.Write(c)
			}
		}
		denied <- err
		packets.ReadPacket(c) // Keep the transport open until the client rejects the SUBACK.
	}()
	e, _ := setup(t)
	s := acquisition.Source{ID: "denied", Broker: "tcp://" + listener.Addr().String(), Topic: "data", Protocol: "generic", Standby: &acquisition.StandbyEndpoint{Broker: backup}}
	if err = e.Sources([]acquisition.Source{s}); err != nil {
		t.Fatal(err)
	}
	if err = e.Connect(s.ID); err != nil {
		t.Fatal(err)
	}
	if err = <-denied; err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	active := e.standbyActive[s.ID]
	e.mu.Unlock()
	if !active {
		t.Fatal("primary subscription rejection reported as connected")
	}
}

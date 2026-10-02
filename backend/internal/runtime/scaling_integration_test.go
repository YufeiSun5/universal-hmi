package runtime

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	mqtt "github.com/eclipse/paho.mqtt.golang"
)

func TestLocalKIOScalingOffsetWireAndReadback(t *testing.T) {
	broker := localBroker(t)
	e, ps := setup(t)
	source := acquisition.Source{ID: "scaling", Name: "isolated scaling fixture", Protocol: "kingio", Broker: broker, Topic: "datachange_scaling", ClientID: "scaling", Writer: "hmi", ACKTimeoutMS: 1000}
	if err := e.Sources([]acquisition.Source{source}); err != nil {
		t.Fatal(err)
	}
	if err := e.Connect(source.ID); err != nil {
		t.Fatal(err)
	}
	client := mqtt.NewClient(mqtt.NewClientOptions().AddBroker(broker).SetClientID("scaling-device"))
	token := client.Connect()
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("scaling device failed to connect")
	}
	defer client.Disconnect(10)
	writes := make(chan map[string]any, 8)
	token = client.Subscribe("setdata_scaling", 1, func(_ mqtt.Client, message mqtt.Message) {
		var wire map[string]any
		if json.Unmarshal(message.Payload(), &wire) == nil {
			writes <- wire
		}
	})
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("scaling device failed to subscribe")
	}

	tests := []struct {
		name, kind                      string
		scale, offset, engineering, raw float64
		point                           points.Definition
	}{
		{name: "negative-float", kind: "FLOAT", scale: -.25, offset: 10, engineering: 9.25, raw: 3},
		{name: "decimal-integer", kind: "INT", scale: .1, offset: -.5, engineering: .7, raw: 12},
		{name: "negative-integer", kind: "INT", scale: -.1, offset: 10, engineering: 9.7, raw: 3},
		{name: "large-offset", kind: "INT", scale: 1, offset: 1e12, engineering: 1e12 + 1, raw: 1},
	}
	for i := range tests {
		tt := &tests[i]
		var err error
		tt.point, err = ps.Create(points.CreateInput{Station: "A", Name: tt.name, DataType: tt.kind, SourceType: "mqtt", SourceID: source.ID, SourcePath: "read." + tt.name, Topic: source.Topic, WritePath: "write." + tt.name, Writable: true, RWMode: "RW", ScaleFactor: &tt.scale, Offset: tt.offset})
		if err != nil {
			t.Fatal(err)
		}
	}
	version, err := e.Apply()
	if err != nil {
		t.Fatal(err)
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			command := Write{CommandID: "wire-scaling-" + tt.name, PointID: tt.point.ID, Version: version, Value: tt.engineering}
			result, err := e.Write(command)
			if err != nil || result.State != "accepted" {
				t.Fatalf("write=%+v error=%v", result, err)
			}
			wire := receiveWrite(t, writes)
			object := wire["Objs"].([]any)[0].(map[string]any)
			if object["1"] != tt.raw || object["N"] != "write."+tt.name {
				t.Fatalf("unexpected physical payload: %+v", wire)
			}
			mqttPublish(t, client, "setdata_result_scaling_hmi", map[string]any{"Qid": wire["Qid"], "ProcessStep": 100, "Result": "OK"})
			waitCommand(t, e, command.CommandID, "acknowledged")
			publishReadback := func(raw float64) {
				at := time.Now().UTC()
				mqttPublish(t, client, source.Topic, map[string]any{"PVs": map[string]any{"2": at.Format(time.RFC3339Nano), "3": 192}, "Objs": []any{map[string]any{"N": "read." + tt.name, "1": raw}}})
				deadline := time.Now().Add(2 * time.Second)
				for time.Now().Before(deadline) {
					e.mu.Lock()
					sample := e.live[tt.point.ID]
					e.mu.Unlock()
					if sample.Raw == raw && sample.SourceTime.Equal(at) {
						return
					}
					time.Sleep(time.Millisecond)
				}
				t.Fatalf("physical sample %g was not consumed", raw)
			}
			publishReadback(tt.raw + 1)
			result, err = e.Command(command.CommandID)
			if err != nil || result.State != "acknowledged" {
				t.Fatalf("wrong raw value confirmed command: %+v %v", result, err)
			}
			publishReadback(tt.raw)
			result = waitCommand(t, e, command.CommandID, "readback_confirmed")
			if result.PublishState != "sent" || result.ACKState != "acknowledged" || result.ReadbackState != "confirmed" {
				t.Fatalf("physical stages lost: %+v", result)
			}
			e.mu.Lock()
			sample := e.live[tt.point.ID]
			e.mu.Unlock()
			value, ok := sample.Value.(float64)
			if !ok || !sameEncodedFloat(value, tt.engineering) || sample.Quality != "good" {
				t.Fatalf("wire round trip differs: %+v", sample)
			}
		})
	}
}

package runtime

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	mqtt "github.com/eclipse/paho.mqtt.golang"
)

func discoverySource(id string) acquisition.Source {
	return acquisition.Source{ID: id, Name: id, Broker: "tcp://127.0.0.1:1883", Topic: "data/#", Protocol: "generic"}
}

func TestDiscoveryWildcardAndStableSelectionRevision(t *testing.T) {
	e, ps := policyFixture(t)
	if err := e.Sources([]acquisition.Source{discoverySource("a")}); err != nil {
		t.Fatal(err)
	}
	rows := []acquisition.Raw{
		{SourceID: "a", Topic: "data/heat", Path: "Heat.Temp[1]", Value: 1.0},
		{SourceID: "a", Topic: "data/heat", Path: "Heat.Run", Value: true},
		{SourceID: "a", Topic: "data/other", Path: "Other.Temp", Value: 2.0},
	}
	e.observeDiscoveryLocked("a", rows)
	for query, count := range map[string]int{"*": 3, "HEAT.*": 2, "*temp*": 2, "*Temp[1]": 1, "Heat.T?mp*": 1, "data/*": 3, "temp": 2, "*Run,*Temp[1]": 2, "run，Other": 2, "run\nOther": 2, " , ": 0, "Heat.(Run|Temp)": 0} {
		page, err := e.Discovery("a", query, 0, 1)
		if err != nil || page.Total != count {
			t.Fatalf("%q: %+v %v", query, page, err)
		}
	}
	first, _ := e.Discovery("a", "*", 0, 1)
	second, _ := e.Discovery("a", "*", 1, 1)
	if first.Revision == "" || first.Revision != second.Revision {
		t.Fatal("revision differs across pages")
	}
	rows[0].Value = 20.0
	e.observeDiscoveryLocked("a", rows[:1])
	updated, _ := e.Discovery("a", "*", 0, 1)
	if updated.Revision != first.Revision {
		t.Fatal("live sample changed selection revision")
	}
	_, err := ps.Create(points.CreateInput{Station: "A", Name: "existing", SourceType: "mqtt", SourceID: "a", SourcePath: "Heat.Run", DataType: "BOOL"})
	if err != nil {
		t.Fatal(err)
	}
	updated, _ = e.Discovery("a", "*", 0, 1)
	if updated.Revision == first.Revision {
		t.Fatal("saved mapping did not invalidate revision")
	}
	rows[0].Value = true
	e.observeDiscoveryLocked("a", rows[:1])
	conflict, _ := e.Discovery("a", "*", 0, 1)
	if conflict.Revision == updated.Revision {
		t.Fatal("type conflict did not invalidate revision")
	}
}

func TestDiscoveryQuestionMatchesSingleUnicodeCharacter(t *testing.T) {
	matches := discoveryMatcher("泵?运行")
	if !matches("泵一运行") || !matches("泵1运行") || matches("泵12运行") || matches("泵运行") {
		t.Fatal("question wildcard must match exactly one Unicode character")
	}
}

func TestDiscoveryTypesFilteringDuplicateMappingsAndGenerations(t *testing.T) {
	e, ps := policyFixture(t)
	if err := e.Sources([]acquisition.Source{discoverySource("a"), discoverySource("b")}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	rows, err := acquisition.Decode("a", "data/station", "generic", []byte(fmt.Sprintf(`{"points":[
		{"path":"Station.Temp","value":100,"quality":"good","timestamp":%q},
		{"path":"Station.Run","value":false,"quality":"good","timestamp":%q},
		{"path":"Station.Code","value":"001","quality":"bad","timestamp":%q},
		{"path":"Station.Null","value":null,"quality":"bad","timestamp":%q}]}`, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano))))
	if err != nil {
		t.Fatal(err)
	}
	e.observeDiscoveryLocked("a", rows)
	if len(ps.List()) != 0 || len(e.live) != 0 {
		t.Fatal("discovery created configuration or fabricated live points")
	}
	_, err = ps.Create(points.CreateInput{Station: "Other", Name: "existing", SourceType: "mqtt", SourceID: "a", SourcePath: "Station.Temp", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	page, err := e.Discovery("a", "STATION.", 0, 2)
	if err != nil || page.Total != 4 || len(page.Items) != 2 || page.Items[0].DataType != "STRING" || page.Items[0].Preview != `"001"` || page.Items[1].TypeStatus != "unknown" {
		t.Fatalf("types/filter/page: %+v %v", page, err)
	}
	page, _ = e.Discovery("a", "station.", 2, 2)
	if page.Items[0].DataType != "BOOL" || page.Items[0].Preview != "false" || page.Items[1].DataType != "FLOAT" || page.Items[1].ExistingID == "" || page.Items[1].ExistingStation != "Other" {
		t.Fatalf("numeric conservatism or wildcard duplicate: %+v", page)
	}
	other, _ := e.Discovery("b", "", 0, 200)
	if other.Total != 0 {
		t.Fatal("cross-source results leaked")
	}
	rows[0].Value = true
	e.observeDiscoveryLocked("a", rows[:1])
	rows[0].Value = 12.5
	e.observeDiscoveryLocked("a", rows[:1])
	page, _ = e.Discovery("a", "temp", 0, 200)
	if page.Items[0].DataType != "" || page.Items[0].TypeStatus != "conflict" {
		t.Fatal("conflicting type was silently trusted")
	}
	e.connectionGeneration["a"] = 2
	e.Disconnect("a")
	e.receiveSource("a", 2, rows)
	page, _ = e.Discovery("a", "", 0, 200)
	if page.Observed != 0 {
		t.Fatal("old decoder repopulated disconnected source")
	}
	for _, args := range []struct{ offset, limit int }{{-1, 1}, {0, 0}, {0, 501}} {
		if _, err := e.Discovery("a", "", args.offset, args.limit); err == nil {
			t.Fatal("invalid pagination accepted")
		}
	}
	if _, err := e.Discovery("missing", "", 0, 1); err == nil {
		t.Fatal("unknown source accepted")
	}
}

func TestDiscoveryCapacityAndPreviewAreBounded(t *testing.T) {
	e, _ := policyFixture(t)
	if err := e.Sources([]acquisition.Source{discoverySource("a")}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i <= MaxDiscoveredPoints; i++ {
		e.observeDiscoveryLocked("a", []acquisition.Raw{{SourceID: "a", Topic: "t", Path: fmt.Sprintf("p%05d", i), Value: strings.Repeat("汉", 300)}})
	}
	page, _ := e.Discovery("a", "", 0, 1)
	if page.Observed != MaxDiscoveredPoints || page.OmittedSamples != 1 || len(page.Items[0].Preview) > 256 {
		t.Fatalf("bounds: %+v", page)
	}
	e.observeDiscoveryLocked("a", []acquisition.Raw{{SourceID: "a", Topic: "t", Path: "p00000", Value: "new"}})
	page, _ = e.Discovery("a", "p00000", 0, 1)
	if page.Items[0].Preview != `"new"` {
		t.Fatal("full catalogue stopped updating existing entries")
	}
	e.observeDiscoveryLocked("a", []acquisition.Raw{{SourceID: "a", Topic: "t", Path: " leading", Value: 1.0}})
	page, _ = e.Discovery("a", "", 0, 1)
	if page.OmittedSamples != 2 {
		t.Fatal("unrepresentable source identity not reported")
	}
}

func TestLocalMQTTDiscoveryBeforeAnyPointsAreConfigured(t *testing.T) {
	broker := localBroker(t)
	e, ps := setup(t)
	source := discoverySource("discovery")
	source.Broker = broker
	source.Protocol = "kingio"
	if err := e.Sources([]acquisition.Source{source}); err != nil {
		t.Fatal(err)
	}
	client := mqtt.NewClient(mqtt.NewClientOptions().AddBroker(broker).SetClientID("discovery-test-publisher"))
	token := client.Connect()
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("fixture connection failed")
	}
	defer client.Disconnect(10)
	payload, _ := json.Marshal(kingIOInitialBundle())
	token = client.Publish("data/first", 1, true, payload)
	if !token.WaitTimeout(time.Second) || token.Error() != nil {
		t.Fatal("initial retained bundle publication failed")
	}
	if err := e.Connect(source.ID); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		page, err := e.Discovery(source.ID, "heat", 0, 200)
		if err != nil {
			t.Fatal(err)
		}
		if page.Total == 250 {
			if !page.Connected || len(page.Items) != 200 || len(ps.List()) != 0 {
				t.Fatalf("unexpected discovery side effect: %+v", page)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("unconfigured MQTT tag was not discovered")
}

func kingIOInitialBundle() map[string]any {
	rows := make([]any, 250)
	for i := range rows {
		var value any = float64(i)
		if i%3 == 1 {
			value = false
		}
		if i%3 == 2 {
			value = "001"
		}
		rows[i] = map[string]any{"N": fmt.Sprintf("Heat.Tag%03d", i), "1": value}
	}
	return map[string]any{"PVs": map[string]any{"2": time.Now().UTC().Format(time.RFC3339Nano), "3": 192}, "Objs": rows}
}

func TestKingIOInitialFullBundleWithoutConfiguredPoints(t *testing.T) {
	e, ps := policyFixture(t)
	source := discoverySource("kingio")
	source.Protocol = "kingio"
	if err := e.Sources([]acquisition.Source{source}); err != nil {
		t.Fatal(err)
	}
	payload, _ := json.Marshal(kingIOInitialBundle())
	rows, err := acquisition.Decode(source.ID, "data/first", source.Protocol, payload)
	if err != nil {
		t.Fatal(err)
	}
	e.receiveSource(source.ID, e.connectionGeneration[source.ID], rows)
	page, err := e.Discovery(source.ID, "heat", 0, 500)
	if err != nil || page.Total != 250 || len(ps.List()) != 0 {
		t.Fatalf("initial full bundle: %+v %v", page, err)
	}
	for i, row := range page.Items {
		if row.DataType != []string{"FLOAT", "BOOL", "STRING"}[i%3] {
			t.Fatalf("unexpected type: %+v", row)
		}
	}
}

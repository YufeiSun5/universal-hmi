package points

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestOwnershipFileRecoveryBeforeFailedSaveAndRetry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "points.json")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	scale := 2.5
	p, err := s.Create(CreateInput{Station: "IO-01", Name: "MQTT identity", SourceType: "mqtt", SourceID: "source", Topic: "datachange_fixture", SourcePath: "Exact.Path", DataType: "FLOAT", ScaleFactor: &scale, Offset: 3, Unit: "kW", RWMode: "R", StaleMS: 60000})
	if err != nil {
		t.Fatal(err)
	}
	target := []StationTarget{{ID: p.ID, Revision: Revision(p), Station: "A"}}
	// A destination directory makes the final atomic rename fail, after recovery succeeds.
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	check := func(id string) func([]Definition) (string, []byte, error) {
		return func([]Definition) (string, []byte, error) { return id, []byte(`{"recovery":true}`), nil }
	}
	if err = s.ReassignStations(target, check("first")); err == nil {
		t.Fatal("save unexpectedly succeeded")
	}
	if !reflect.DeepEqual(s.List()[0], p) {
		t.Fatal("failed save changed memory")
	}
	if _, err = os.Stat(filepath.Join(filepath.Dir(path), "ownership-backups", "first.json")); err != nil {
		t.Fatal("missing prewrite recovery", err)
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = s.ReassignStations(target, check("retry-unique")); err != nil {
		t.Fatal(err)
	}
	expected := p
	expected.Station = "A"
	if !reflect.DeepEqual(expected, s.List()[0]) {
		t.Fatal("modified preserved MQTT fields")
	}
	reopened, err := Open(path)
	if err != nil || !reflect.DeepEqual(expected, reopened.List()[0]) {
		t.Fatal("durable fields differ", err)
	}
}

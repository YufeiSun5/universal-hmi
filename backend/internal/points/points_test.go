package points

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestConfigurationPersistsAndKeepsStationIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "points.json")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.Create(CreateInput{Station: "A", Name: "Temperature", DataType: "FLOAT", SourceType: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	q, err := s.Create(CreateInput{Station: "B", Name: "Temperature", DataType: "FLOAT", SourceType: "manual"})
	if err != nil || p.ID == q.ID {
		t.Fatalf("distinct station identities: %v", err)
	}
	restarted, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if rows := restarted.List(); len(rows) != 2 || rows[0].ID != p.ID || rows[0].ScaleFactor != 1 {
		t.Fatalf("restart lost configuration: %+v", rows)
	}
	if _, err := restarted.Create(CreateInput{Station: "A", Name: "Temperature", DataType: "FLOAT", SourceType: "manual"}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("duplicate station/name must fail: %v", err)
	}
}

func TestInvalidOrUnsavedPointDoesNotEnterRuntimeList(t *testing.T) {
	path := filepath.Join(t.TempDir(), "points.json")
	s, _ := Open(path)
	if _, err := s.Create(CreateInput{Station: "A", Name: "T", DataType: "FLOAT", SourceType: "mqtt"}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing source identity must fail: %v", err)
	}
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, []byte("block"), 0600); err != nil {
		t.Fatal(err)
	}
	s.path = filepath.Join(blocker, "points.json")
	if _, err := s.Create(CreateInput{Station: "A", Name: "T", DataType: "FLOAT", SourceType: "virtual"}); err == nil {
		t.Fatal("failed persistence reported as success")
	}
	if len(s.List()) != 0 {
		t.Fatal("failed save changed published configuration")
	}
}

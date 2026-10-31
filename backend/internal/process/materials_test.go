package process

import (
	"bytes"
	"encoding/base64"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func transparentMaterial(t *testing.T) Material {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	picture.SetNRGBA(0, 0, color.NRGBA{255, 0, 0, 0})
	picture.SetNRGBA(1, 0, color.NRGBA{0, 255, 0, 128})
	var b bytes.Buffer
	if err := png.Encode(&b, picture); err != nil {
		t.Fatal(err)
	}
	return Material{SchemaVersion: 1, ID: "pump", Name: "透明泵", Category: "设备", Width: 999, Height: 999,
		Asset: Asset{Name: "pump.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(b.Bytes())}}
}

func TestMaterialsPreserveAlphaRestartAndIndependentScreens(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	original := transparentMaterial(t)
	m, err := s.SaveMaterial(original)
	if err != nil || m.Width != 2 || m.Height != 2 || m.Revision != 1 {
		t.Fatalf("decoded dimensions: %+v %v", m, err)
	}
	if _, err := s.SaveMaterial(original); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale upload: %v", err)
	}
	for _, station := range []string{"A", "B"} {
		d := document()
		d.ID = "screen-" + station
		d.Station = station
		n := element("image", "image")
		n.Image = "embedded"
		d.Nodes = []Node{n}
		d.Assets["embedded"] = m.Asset
		if _, err := s.Save(d); err != nil {
			t.Fatal(err)
		}
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	items, err := s.ListMaterials()
	if err != nil || len(items) != 1 || items[0].ID != m.ID {
		t.Fatalf("global library: %v %v", items, err)
	}
	got, err := s.GetMaterial(m.ID)
	if err != nil || got.Asset.Data != original.Asset.Data {
		t.Fatalf("PNG bytes changed: %v", err)
	}
	b, _ := base64.StdEncoding.DecodeString(got.Asset.Data)
	decoded, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, alpha := decoded.At(0, 0).RGBA()
	if alpha != 0 {
		t.Fatal("transparent pixel flattened")
	}
	_, _, _, alpha = decoded.At(1, 0).RGBA()
	if alpha != 128*257 {
		t.Fatal("partial transparency changed")
	}
	if err := s.DeleteMaterial(m.ID, 0); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale deletion: %v", err)
	}
	if err := s.DeleteMaterial(m.ID, m.Revision); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	items, _ = s.ListMaterials()
	if len(items) != 0 {
		t.Fatal("deleted library item returned")
	}
	for _, station := range []string{"A", "B"} {
		d, err := s.Get("screen-" + station)
		if err != nil || d.Assets["embedded"].Data != original.Asset.Data {
			t.Fatalf("library deletion changed screen %s: %v", station, err)
		}
	}
}

func TestMaterialValidationAndCorruptStartup(t *testing.T) {
	for _, mutate := range []func(*Material){
		func(m *Material) { m.ID = "../escape" },
		func(m *Material) { m.Name = "" },
		func(m *Material) { m.Asset.MIME = "image/jpeg" },
		func(m *Material) { m.Asset.Data = "not-base64" },
		func(m *Material) {
			b, _ := base64.StdEncoding.DecodeString(m.Asset.Data)
			m.Asset.Data = base64.StdEncoding.EncodeToString(b[:len(b)/2])
		},
	} {
		s, _ := Open(t.TempDir())
		m := transparentMaterial(t)
		mutate(&m)
		if _, err := s.SaveMaterial(m); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid material accepted: %v", err)
		}
	}
	dir := t.TempDir()
	s, _ := Open(dir)
	m, err := s.SaveMaterial(transparentMaterial(t))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "materials", m.ID+".json"), []byte(`{"schema_version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(dir); err == nil {
		t.Fatal("corrupt persisted material accepted")
	}
}

func TestConcurrentMaterialSaveOnlyOneWins(t *testing.T) {
	s, _ := Open(t.TempDir())
	m := transparentMaterial(t)
	var wg sync.WaitGroup
	results := make(chan error, 8)
	for range 8 {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := s.SaveMaterial(m); results <- err }()
	}
	wg.Wait()
	close(results)
	wins := 0
	for err := range results {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrConflict) {
			t.Fatal(err)
		}
	}
	if wins != 1 {
		t.Fatalf("concurrent creation winners: %d", wins)
	}
}

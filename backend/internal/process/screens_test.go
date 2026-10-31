package process

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestGISOnlySavesInPublicScopeAndPreservesLegacyOwnership(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	d := document()
	d.ID = "public-gis"
	d.Kind = "gis"
	d.Station = ""
	d.Nodes = []Node{}
	d.Assets = map[string]Asset{}
	saved, err := s.Save(d)
	if err != nil {
		t.Fatal(err)
	}
	copy := d
	copy.ID = "station-gis"
	copy.Station = "A"
	if _, err = s.Save(copy); !errors.Is(err, ErrInvalid) {
		t.Fatalf("station GIS accepted: %v", err)
	}
	// Preserve older files and their authorization scope; never promote them
	// to public merely by loading a project from a previous release.
	copy.Revision = 1
	legacy, _ := json.Marshal(copy)
	if err = os.WriteFile(filepath.Join(dir, copy.ID+".json"), legacy, 0600); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	public, _ := s.List("")
	station, _ := s.List("A")
	all, _ := s.ListAll()
	if len(public) != 1 || len(station) != 1 || len(all) != 2 || public[0].Kind != "gis" {
		t.Fatalf("wrong scopes: %v %v", public, station)
	}
	if _, err = s.Save(copy); !errors.Is(err, ErrInvalid) {
		t.Fatalf("legacy station GIS update accepted: %v", err)
	}
	saved.Kind = "process"
	if _, err = s.Save(saved); !errors.Is(err, ErrConflict) {
		t.Fatalf("kind changed in place: %v", err)
	}
	copy.Nodes = []Node{element("bad", "symbol")}
	if err = Validate(copy); !errors.Is(err, ErrInvalid) {
		t.Fatalf("GIS accepted process bindings: %v", err)
	}
}

func TestVariableLabelAndFourPortConnectionsSurviveRestart(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	d := document()
	hx := element("hx", "symbol")
	hx.Symbol = "example_plate_hx"
	value := element("value", "value")
	value.Label = "一次供水温度"
	value.UnitOverride = "°C"
	value.Decimals = 3
	pipe := element("pipe", "pipe")
	pipe.Points = []Position{{20, 40}, {300, 40}}
	pipe.StartNode = hx.ID
	pipe.StartPort = "left_top"
	d.Nodes = []Node{hx, value, pipe}
	if _, err = s.Save(d); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(d.ID)
	if err != nil || got.Nodes[1].Label != value.Label || got.Nodes[1].Decimals != 3 || got.Nodes[2].StartPort != "left_top" {
		t.Fatalf("lost label/precision/port: %+v %v", got, err)
	}
	got.Nodes[1].Label = strings.Repeat("温", 86)
	if err := Validate(got); !errors.Is(err, ErrInvalid) {
		t.Fatalf("unbounded UTF-8 label: %v", err)
	}
	got.Nodes[1].Label = ""
	if err := Validate(got); err != nil {
		t.Fatalf("legacy unlabeled document rejected: %v", err)
	}
}

func document() Document {
	return Document{SchemaVersion: 1, ID: "screen-a", Name: "工艺 A", Station: "A", Width: 1600, Height: 900, Nodes: []Node{}, Assets: map[string]Asset{}}
}
func element(id, kind string) Node {
	return Node{ID: id, Kind: kind, X: 20, Y: 20, Width: 100, Height: 100, Color: "#2563eb", Fill: "none", StrokeWidth: 4, FontSize: 20}
}
func embedded(t *testing.T) Asset {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	return Asset{Name: "sample.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(b.Bytes())}
}

func TestDocumentRoundTripRestartScopeAndConflict(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	d := document()
	pump := element("pump", "symbol")
	pump.Symbol = "fuxa_pump"
	photo := element("photo", "image")
	photo.Image = "embedded"
	pipe := element("pipe", "pipe")
	pipe.Points = []Position{{120, 70}, {300, 70}}
	pipe.StartNode = "pump"
	pipe.StartPort = "right"
	pipe.Orthogonal = true
	d.Nodes = []Node{pump, photo, pipe}
	d.Assets["embedded"] = embedded(t)
	saved, err := s.Save(d)
	if err != nil || saved.Revision != 1 {
		t.Fatalf("save: %+v %v", saved, err)
	}
	if _, err := s.Save(d); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale creation accepted: %v", err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(d.ID)
	if err != nil || got.Assets["embedded"].Data != d.Assets["embedded"].Data || got.Nodes[2].StartNode != "pump" {
		t.Fatalf("restart lost image/connection: %v", err)
	}
	for _, scope := range []string{"", "B", "*"} {
		items, err := s.List(scope)
		if err != nil || len(items) != 0 {
			t.Fatalf("scope leak %q: %v %v", scope, items, err)
		}
	}
	items, _ := s.List("A")
	if len(items) != 1 {
		t.Fatalf("missing scoped screen: %v", items)
	}
	got.Station = "B"
	if _, err := s.Save(got); !errors.Is(err, ErrConflict) {
		t.Fatalf("station reassignment accepted: %v", err)
	}
	if err := s.Delete(d.ID, 2); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale delete accepted: %v", err)
	}
	if err := s.Delete(d.ID, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(d.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}

func TestConcurrentRevisionOnlyOneWriterWins(t *testing.T) {
	s, _ := Open(t.TempDir())
	d, _ := s.Save(document())
	var wg sync.WaitGroup
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := s.Save(d); results <- err }()
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
		t.Fatalf("%d successful writers", wins)
	}
	got, _ := s.Get(d.ID)
	if got.Revision != 2 {
		t.Fatal(got.Revision)
	}
}

func TestMultipleScreensPerStationKeepGraphicsBindingsAndImagesIndependent(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []string{"A", "B"} {
		for _, id := range []string{"one", "two"} {
			d := document()
			d.ID, d.Name, d.Station = scope+"-"+id, scope+" "+id, scope
			value := element("value", "value")
			value.PointID, value.UnitOverride, value.Decimals = scope+"-"+id, "MPa", 3
			photo := element("photo", "image")
			photo.Image = "reference"
			d.Nodes = []Node{value, photo}
			d.Assets["reference"] = embedded(t)
			if _, err := s.Save(d); err != nil {
				t.Fatal(err)
			}
		}
	}
	a, _ := s.Get("A-one")
	a.Nodes[0].PointID, a.Nodes[0].X = "A-new", 300
	a.Assets["reference"] = Asset{Name: "new-reference.png", MIME: "image/png", Data: embedded(t).Data}
	if _, err := s.Save(a); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []string{"A", "B"} {
		items, err := s.List(scope)
		if err != nil || len(items) != 2 {
			t.Fatalf("%s: %+v %v", scope, items, err)
		}
		for _, item := range items {
			got, err := s.Get(item.ID)
			if err != nil || got.Station != scope {
				t.Fatalf("scope leak: %+v %v", got, err)
			}
			if item.ID != "A-one" && (got.Nodes[0].PointID != item.ID || got.Nodes[0].X != 20 || got.Revision != 1 || got.Assets["reference"].Name != "sample.png") {
				t.Fatalf("editing one screen changed another: %+v", got)
			}
		}
	}
}

func TestInvalidWritesPreserveSavedDocument(t *testing.T) {
	s, _ := Open(t.TempDir())
	saved, _ := s.Save(document())
	cases := map[string]func(*Document){
		"path traversal": func(d *Document) { d.ID = "../escape" },
		"schema":         func(d *Document) { d.SchemaVersion = 2 },
		"canvas":         func(d *Document) { d.Width = 319 },
		"outside":        func(d *Document) { n := element("n", "text"); n.X = 1590; d.Nodes = []Node{n} },
		"duplicate":      func(d *Document) { n := element("n", "text"); d.Nodes = []Node{n, n} },
		"remote image": func(d *Document) {
			n := element("n", "image")
			n.Image = "a"
			d.Nodes = []Node{n}
			d.Assets = map[string]Asset{"a": {MIME: "image/png", Data: "https://example.com/a.png"}}
		},
		"unused image": func(d *Document) { d.Assets = map[string]Asset{"a": embedded(t)} },
		"corrupt image": func(d *Document) {
			n := element("n", "image")
			n.Image = "a"
			d.Nodes = []Node{n}
			a := embedded(t)
			data, _ := base64.StdEncoding.DecodeString(a.Data)
			a.Data = base64.StdEncoding.EncodeToString(data[:40])
			d.Assets = map[string]Asset{"a": a}
		},
		"missing endpoint": func(d *Document) {
			n := element("n", "pipe")
			n.Points = []Position{{0, 0}, {10, 10}}
			n.EndNode = "missing"
			n.EndPort = "left"
			d.Nodes = []Node{n}
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			d := saved
			change(&d)
			if _, err := s.Save(d); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid accepted: %v", err)
			}
			got, _ := s.Get(saved.ID)
			if got.Revision != 1 || got.Name != saved.Name {
				t.Fatalf("failed save changed original: %+v", got)
			}
		})
	}
}

func TestStartupRejectsCorruptionAndTrailingJSON(t *testing.T) {
	for _, suffix := range []string{" {}", "garbage"} {
		t.Run(suffix, func(t *testing.T) {
			dir := t.TempDir()
			d := document()
			d.Revision = 1
			data, _ := json.Marshal(d)
			if err := os.WriteFile(filepath.Join(dir, d.ID+".json"), append(data, []byte(suffix)...), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := Open(dir); err == nil {
				t.Fatal("corrupt document accepted")
			}
		})
	}
}

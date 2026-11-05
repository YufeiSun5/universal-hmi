package process

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func displayNumber(v float64) *float64 { return &v }
func displayDocument() Document {
	d := document()
	state := element("pump", "symbol")
	state.Symbol, state.PointID = "fuxa_pump", "run"
	state.StateDisplay = &StateDisplay{ActiveValue: displayNumber(1), InactiveValue: displayNumber(0), ActiveText: "运行", InactiveText: "停止", ActiveColor: "#16a34a", InactiveColor: "#dc2626"}
	state.StateDisplay.ActiveBlink = true
	level := element("level", "level")
	level.PointID = "liquid"
	level.LevelDisplay = &LevelDisplay{Minimum: displayNumber(-20), Maximum: displayNumber(80), Orientation: "vertical"}
	label := state
	label.ID, label.Kind = "state-lamp", "symbol"
	d.Nodes = []Node{state, level, label}
	return d
}

func TestDisplayValidationRejectsAmbiguousOrInvalidInputs(t *testing.T) {
	for name, change := range map[string]func(*Document){
		"same state values":   func(d *Document) { d.Nodes[0].StateDisplay.InactiveValue = displayNumber(1) },
		"missing state value": func(d *Document) { d.Nodes[0].StateDisplay.ActiveValue = nil },
		"NaN state":           func(d *Document) { d.Nodes[0].StateDisplay.ActiveValue = displayNumber(math.NaN()) },
		"blank label":         func(d *Document) { d.Nodes[0].StateDisplay.ActiveText = " " },
		"invalid color":       func(d *Document) { d.Nodes[0].StateDisplay.ActiveColor = "green" },
		"state on value":      func(d *Document) { d.Nodes[0].Kind = "value" },
		"zero span":           func(d *Document) { d.Nodes[1].LevelDisplay.Maximum = displayNumber(-20) },
		"reverse span":        func(d *Document) { d.Nodes[1].LevelDisplay.Maximum = displayNumber(-21) },
		"infinite span": func(d *Document) {
			d.Nodes[1].LevelDisplay.Minimum = displayNumber(-math.MaxFloat64)
			d.Nodes[1].LevelDisplay.Maximum = displayNumber(math.MaxFloat64)
		},
		"missing minimum":      func(d *Document) { d.Nodes[1].LevelDisplay.Minimum = nil },
		"wrong direction":      func(d *Document) { d.Nodes[1].LevelDisplay.Orientation = "auto" },
		"missing level config": func(d *Document) { d.Nodes[1].LevelDisplay = nil },
		"level on shape":       func(d *Document) { d.Nodes[1].Kind = "rect" },
	} {
		t.Run(name, func(t *testing.T) {
			d := displayDocument()
			change(&d)
			if err := Validate(d); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid display accepted: %v", err)
			}
		})
	}
	d := displayDocument()
	d.Nodes[1].LevelDisplay.Orientation = "horizontal"
	if err := Validate(d); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(d)
	var fields map[string]any
	_ = json.Unmarshal(raw, &fields)
	fields["nodes"].([]any)[0].(map[string]any)["state_display"].(map[string]any)["execute"] = "start"
	raw, _ = json.Marshal(fields)
	var decoded Document
	if err := json.Unmarshal(raw, &decoded); err == nil {
		t.Fatal("unknown nested display field accepted")
	}
}

func TestDisplaySaveRestartAuthorizationAndTemplateBindings(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	d := displayDocument()
	lookup := func(id string) (string, bool) { return "Other station", id == "run" || id == "liquid" }
	if _, err := s.SaveAuthorizedPoints(d, func(string) (string, bool) { return "", false }); !errors.Is(err, ErrInvalid) {
		t.Fatalf("denied binding accepted: %v", err)
	}
	saved, err := s.SaveAuthorizedPoints(d, lookup)
	if err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(saved.ID)
	if err != nil || !reflect.DeepEqual(got.Nodes, saved.Nodes) {
		t.Fatalf("display config lost on restart: %v", err)
	}
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, ScreenIDs: []string{d.ID}}, Valid: func() bool { return true }, StationID: func(s string) string { return s }})
	view, err := s.VisibleDocument(ctx, saved.ID, func(id string) bool { return id == "run" })
	if err != nil || view.Nodes[1].PointID != "" || view.Nodes[0].PointID != "run" || view.Nodes[2].PointID != "run" {
		t.Fatalf("display binding projection: %+v %v", view.Nodes, err)
	}
	if view.Nodes[1].LevelDisplay == nil {
		t.Fatal("unauthorized value removed the static level configuration")
	}
	template := displayDocument()
	template.ID, template.Station = "display-template", ""
	for i := range template.Nodes {
		template.Nodes[i].PointID = ""
	}
	template, err = s.Save(template)
	if err != nil {
		t.Fatal(err)
	}
	instance := document()
	instance.ID, instance.TemplateID, instance.TemplateRevision = "display-instance", template.ID, template.Revision
	instance.Nodes = nil
	instance.Bindings = map[string]ElementBinding{"pump": {PointID: "run"}, "level": {PointID: "liquid"}, "state-lamp": {PointID: "run"}}
	instance, err = s.SaveAuthorizedPoints(instance, lookup)
	if err != nil {
		t.Fatal(err)
	}
	if instance.Nodes[0].PointID != "run" || instance.Nodes[1].PointID != "liquid" || instance.Nodes[2].PointID != "run" || !reflect.DeepEqual(instance.Nodes[1].LevelDisplay, template.Nodes[1].LevelDisplay) {
		t.Fatal("template state/level configuration or instance point binding lost")
	}
}

func TestLegacyDisplayDefaultsToSteadyAndBlinkTypeIsStrict(t *testing.T) {
	raw := []byte(`{"active_value":1,"inactive_value":0,"active_text":"run","inactive_text":"stop","active_color":"#16a34a","inactive_color":"#dc2626"}`)
	var state StateDisplay
	if err := json.Unmarshal(raw, &state); err != nil || state.ActiveBlink || state.InactiveBlink {
		t.Fatalf("legacy blink changed: %v", err)
	}
	if err := json.Unmarshal([]byte(`{"active_blink":"true"}`), &state); err == nil {
		t.Fatal("string blink accepted")
	}
}

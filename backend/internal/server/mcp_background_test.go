package server

import (
	"encoding/json"
	"testing"
)

func TestMCPBackgroundSchema(t *testing.T) {
	var schema *mcpSchema
	for _, tool := range mcpTools() {
		if tool.Name == "screen_save" {
			schema = tool.schema.Properties["screen"].Properties["background"]
			break
		}
	}
	if schema == nil {
		t.Fatal("missing background schema")
	}
	for _, test := range []struct {
		value map[string]any
		valid bool
	}{
		{map[string]any{"type": "solid", "color": "#123456", "opacity": json.Number("1")}, true},
		{map[string]any{"type": "linear", "color": "#123456", "opacity": json.Number("0.5"), "end_color": "#abcdef", "angle": json.Number("90")}, true},
		{map[string]any{"type": "image", "color": "#123456", "opacity": json.Number("0.5"), "image": "pic", "fit": "cover"}, true},
		{map[string]any{"type": "solid", "color": "#123456", "opacity": json.Number("1"), "angle": json.Number("0")}, false},
		{map[string]any{"type": "linear", "color": "#123456", "opacity": json.Number("0.5"), "end_color": "#abcdef", "angle": json.Number("361")}, false},
	} {
		if (schema.validate(test.value, "background") == nil) != test.valid {
			t.Fatalf("unexpected schema result: %v", test.value)
		}
	}
}

package transfer

import (
	"context"
	"reflect"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func TestStateAndLevelJSONAndXLSXRoundTrip(t *testing.T) {
	source := setup(t)
	point, err := source.Points.Create(points.CreateInput{Station: "A", Name: "显示输入", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	d := screen()
	active, inactive, low, high := 1.0, 0.0, -10.0, 90.0
	state := d.Nodes[0]
	state.Kind, state.PointID, state.Symbol = "symbol", point.ID, "example_valve"
	state.StateDisplay = &process.StateDisplay{ActiveValue: &active, InactiveValue: &inactive, ActiveText: "开启", InactiveText: "关闭", ActiveColor: "#16a34a", InactiveColor: "#dc2626"}
	state.StateDisplay.ActiveBlink, state.StateDisplay.InactiveBlink = true, true
	level := d.Nodes[0]
	level.ID, level.Kind, level.PointID = "liquid-level", "level", point.ID
	level.LevelDisplay = &process.LevelDisplay{Minimum: &low, Maximum: &high, Orientation: "horizontal"}
	d.Nodes = []process.Node{state, level}
	d, err = source.Screens.Save(d)
	if err != nil {
		t.Fatal(err)
	}
	bundle, err := source.Export(context.Background(), ExportRequest{Kind: "bundle", ScreenIDs: []string{d.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle.Bindings) != 2 || len(bundle.Variables) != 1 {
		t.Fatal("display point bindings omitted or duplicated")
	}
	for _, format := range []string{"json", "xlsx"} {
		t.Run(format, func(t *testing.T) {
			encoded, err := Encode(bundle, format, "bundle")
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := Decode(encoded, format, "")
			if err != nil {
				t.Fatal(err)
			}
			target := setup(t)
			req := Request{Bundle: decoded, StationMap: map[string]string{"A": "B"}, ScreenTargets: map[string]Target{}, VariableTargets: map[string]Target{}}
			for _, row := range decoded.Screens {
				req.ScreenTargets[rowKey(row)] = Target{Mode: "create"}
			}
			for _, row := range decoded.Variables {
				req.VariableTargets[rowKey(row)] = Target{Mode: "create"}
			}
			preview, err := target.Preview(context.Background(), req)
			if err != nil || len(preview.Remaining) > 0 {
				t.Fatalf("preview: %v %+v", err, preview)
			}
			req.PreviewToken = preview.PreviewToken
			result, err := target.Commit(context.Background(), req)
			if err != nil || len(result.Remaining) > 0 {
				t.Fatalf("commit: %v %+v", err, result)
			}
			list, _ := target.Screens.ListAll()
			if len(list) != 1 {
				t.Fatal("expected one imported display screen")
			}
			got, err := target.Screens.Get(list[0].ID)
			if err != nil {
				t.Fatal(err)
			}
			mapped := target.Points.List()
			if len(mapped) != 1 || got.Nodes[0].PointID != mapped[0].ID || got.Nodes[1].PointID != mapped[0].ID {
				t.Fatal("point identity did not round trip")
			}
			if !reflect.DeepEqual(got.Nodes[0].StateDisplay, state.StateDisplay) || !reflect.DeepEqual(got.Nodes[1].LevelDisplay, level.LevelDisplay) {
				t.Fatal("display rules or limits lost")
			}
		})
	}
}

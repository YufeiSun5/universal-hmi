package transfer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"reflect"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

// Exercise the actual export codec and import services, not a hand-authored
// import bundle. A bundle is process data, not a backup of navigation/runtime.
func TestBundleRoundTripPreservesBindingsDependenciesAndArtwork(t *testing.T) {
	source := setup(t)
	scale := 2.0
	base, err := source.Points.Create(points.CreateInput{Station: "A", Name: "合成温度", SourceType: "manual", DataType: "FLOAT", Unit: "°C", ScaleFactor: &scale, Offset: 3})
	if err != nil {
		t.Fatal(err)
	}
	derived, err := source.Points.Create(points.CreateInput{Station: "A", Name: "合成派生", SourceType: "virtual", DataType: "FLOAT", Expression: "v[0]*2", Inputs: []string{base.ID}, Unit: "°C"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = source.Points.Create(points.CreateInput{Station: "A", Name: "不相关变量", SourceType: "manual", DataType: "BOOL"}); err != nil {
		t.Fatal(err)
	}
	var pixels bytes.Buffer
	if err = png.Encode(&pixels, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	asset := process.Asset{Name: "synthetic.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(pixels.Bytes())}
	threshold, opacity := 12.5, 0.35
	doc := screen()
	doc.Name = "合成工艺图"
	doc.Nodes[0].PointID = derived.ID
	doc.Nodes[0].Text = "派生温度"
	pipe := doc.Nodes[0]
	pipe.ID, pipe.Kind, pipe.PointID = "pipe", "pipe", ""
	pipe.Arrow, pipe.ArrowAnimate, pipe.Orthogonal = true, true, true
	pipe.Points = []process.Position{{X: 10, Y: 10}, {X: 110, Y: 10}}
	pipe.ArrowVisibleRule = &process.ArrowRule{Match: "all", Conditions: []process.ArrowCondition{{Slot: "visible", PointID: base.ID, Operator: ">", Value: &threshold}}}
	pipe.ArrowMotionRule = &process.ArrowRule{Match: "any", Conditions: []process.ArrowCondition{{Slot: "motion", PointID: derived.ID, Operator: ">=", Value: &threshold}}}
	picture := doc.Nodes[0]
	picture.ID, picture.Kind, picture.PointID, picture.Image = "photo", "image", "", "asset"
	doc.Nodes = append(doc.Nodes, pipe, picture)
	doc.Assets["asset"] = asset
	doc.Background = &process.Background{Type: "image", Color: "#ffffff", Opacity: &opacity, Image: "asset", Fit: "contain"}
	doc, err = source.Screens.Save(doc)
	if err != nil {
		t.Fatal(err)
	}
	beforeDoc, beforePoints := raw(doc), raw(source.Points.List())
	bundle, err := source.Export(context.Background(), ExportRequest{Kind: "bundle", ScreenIDs: []string{doc.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle.Screens) != 1 || len(bundle.Variables) != 2 || len(bundle.Bindings) != 3 {
		t.Fatalf("unexpected export scope: screens=%d variables=%d bindings=%d", len(bundle.Screens), len(bundle.Variables), len(bundle.Bindings))
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
			pre, err := target.Preview(context.Background(), req)
			if err != nil || len(pre.Remaining) > 0 {
				t.Fatalf("preview: %v %+v", err, pre)
			}
			emptyScreens, err := target.Screens.ListAll()
			if err != nil || len(emptyScreens) != 0 || len(target.Points.List()) != 0 {
				t.Fatal("preview wrote target configuration")
			}
			req.PreviewToken = pre.PreviewToken
			result, err := target.Commit(context.Background(), req)
			if err != nil || len(result.Remaining) > 0 {
				t.Fatalf("commit: %v %+v", err, result)
			}
			imported := target.Points.List()
			if len(imported) != 2 {
				t.Fatalf("expected referenced variables only, got %d", len(imported))
			}
			byName := map[string]points.Definition{}
			for _, p := range imported {
				byName[p.Name] = p
				if p.Station != "B" {
					t.Fatalf("station mapping lost: %+v", p)
				}
			}
			mappedBase, mappedDerived := byName[base.Name], byName[derived.Name]
			if mappedBase.ID == "" || mappedDerived.ID == "" || mappedBase.ID == base.ID || mappedDerived.ID == derived.ID {
				t.Fatal("variables not explicitly recreated/remapped")
			}
			wantBase, wantDerived := input(base), input(derived)
			wantBase.Station, wantDerived.Station = "B", "B"
			wantDerived.Inputs = []string{mappedBase.ID}
			if !reflect.DeepEqual(input(mappedBase), wantBase) || !reflect.DeepEqual(input(mappedDerived), wantDerived) {
				t.Fatalf("variable definitions/dependency mapping changed: %+v %+v", mappedBase, mappedDerived)
			}
			screens, err := target.Screens.ListAll()
			if err != nil || len(screens) != 1 {
				t.Fatalf("screen count: %v %+v", err, screens)
			}
			got, err := target.Screens.Get(screens[0].ID)
			if err != nil {
				t.Fatal(err)
			}
			if got.ID == "" || got.ID == doc.ID || got.Revision <= 0 {
				t.Fatalf("import did not create a separately saved screen: id=%q revision=%d", got.ID, got.Revision)
			}
			var want process.Document
			if err = json.Unmarshal(beforeDoc, &want); err != nil {
				t.Fatal(err)
			}
			want.ID, want.Station, want.Revision = got.ID, "B", got.Revision
			want.Nodes[0].PointID = mappedDerived.ID
			want.Nodes[1].ArrowVisibleRule.Conditions[0].PointID = mappedBase.ID
			want.Nodes[1].ArrowMotionRule.Conditions[0].PointID = mappedDerived.ID
			if !bytes.Equal(raw(got), raw(want)) {
				t.Fatalf("layout/assets/background/bindings changed\nwant=%s\ngot=%s", raw(want), raw(got))
			}
			savedDoc, savedPoints := raw(got), raw(imported)
			pre, err = target.Preview(context.Background(), req)
			if err != nil || len(pre.Remaining) > 0 {
				t.Fatalf("repeat preview: %v %+v", err, pre)
			}
			req.PreviewToken = pre.PreviewToken
			repeated, err := target.Commit(context.Background(), req)
			if err != nil || len(repeated.Remaining) > 0 {
				t.Fatalf("repeat commit: %v %+v", err, repeated)
			}
			again, err := target.Screens.Get(got.ID)
			if err != nil || !bytes.Equal(raw(again), savedDoc) || !bytes.Equal(raw(target.Points.List()), savedPoints) {
				t.Fatalf("repeat import changed existing documents: %v", err)
			}
			screens, err = target.Screens.ListAll()
			if err != nil || len(screens) != 1 {
				t.Fatal("repeat import duplicated a screen")
			}
		})
	}
	after, err := source.Screens.Get(doc.ID)
	if err != nil || !bytes.Equal(beforeDoc, raw(after)) || !bytes.Equal(beforePoints, raw(source.Points.List())) {
		t.Fatalf("export/import mutated source: %v", err)
	}
}

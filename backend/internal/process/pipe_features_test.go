package process

import (
	"errors"
	"testing"
)

func pipeNode(id string) Node {
	n := element(id, "pipe")
	n.Points = []Position{{100, 100}, {500, 100}}
	return n
}

func TestPipeJunctionAndArrowRulesPersist(t *testing.T) {
	dir := t.TempDir()
	store, _ := Open(dir)
	root, branch := pipeNode("root"), pipeNode("branch")
	branch.PipeStyle = "cylinder"
	branch.PipeRounded, branch.PipeElbows = true, true
	radius := 32.0
	branch.PipeBendRadius = &radius
	branch.StartNode, branch.StartPort = root.ID, "path:0.500000000000"
	spacing, speed, count, threshold := 90.0, 55.0, 4, 12.5
	branch.ArrowMode, branch.ArrowSpacing, branch.ArrowCount = "segments", &spacing, &count
	branch.ArrowAnimate, branch.ArrowSpeed = true, &speed
	branch.ArrowReverse = true
	branch.ArrowVisibleRule = &ArrowRule{Match: "all", Conditions: []ArrowCondition{{Slot: "供水压力", Operator: ">", Value: &threshold}}}
	branch.ArrowMotionRule = &ArrowRule{Match: "any", Conditions: []ArrowCondition{{Slot: "运行点", PointID: "pump-run", Operator: "==", Value: &threshold}}}
	d := document()
	d.Nodes = []Node{root, branch}
	saved, err := store.Save(d)
	if err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := reopened.Get(saved.ID)
	if err != nil {
		t.Fatal(err)
	}
	n := got.Nodes[1]
	if n.ArrowMode != "count" || !n.ArrowReverse {
		t.Fatalf("whole pipe count/reverse not preserved: %+v", n)
	}
	if !n.PipeRounded || !n.PipeElbows || *n.PipeBendRadius != radius || n.PipeStyle != "cylinder" || n.StartPort != branch.StartPort || !n.ArrowAnimate || *n.ArrowSpacing != spacing || *n.ArrowCount != count || n.ArrowVisibleRule.Conditions[0].PointID != "" || n.ArrowMotionRule.Conditions[0].PointID != "pump-run" {
		t.Fatalf("lost pipe settings: %+v", n)
	}
}

func TestInvalidPipeGraphsAndArrowRulesPreserveDocument(t *testing.T) {
	store, _ := Open(t.TempDir())
	saved, _ := store.Save(document())
	for name, change := range map[string]func(*Node, *Node){
		"invalid radius":     func(a, b *Node) { n := 129.0; a.PipeBendRadius = &n },
		"invalid appearance": func(a, b *Node) { a.PipeStyle = "unknown" },
		"cycle":              func(a, b *Node) { a.StartNode, a.StartPort = b.ID, "path:0"; b.EndNode, b.EndPort = a.ID, "path:1" },
		"self":               func(a, b *Node) { a.StartNode, a.StartPort = a.ID, "path:0" },
		"range":              func(a, b *Node) { b.StartNode, b.StartPort = a.ID, "path:1.01" },
		"negative":           func(a, b *Node) { b.StartNode, b.StartPort = a.ID, "path:-0.1" },
		"wrong port type":    func(a, b *Node) { b.StartNode, b.StartPort = a.ID, "left" },
		"count limit":        func(a, b *Node) { n := 65; a.ArrowCount = &n },
		"spacing zero":       func(a, b *Node) { n := 0.0; a.ArrowSpacing = &n },
		"speed negative":     func(a, b *Node) { n := -1.0; a.ArrowSpeed = &n },
		"missing threshold": func(a, b *Node) {
			a.ArrowVisibleRule = &ArrowRule{Match: "all", Conditions: []ArrowCondition{{Operator: ">"}}}
		},
		"invalid operator": func(a, b *Node) {
			n := 1.0
			a.ArrowVisibleRule = &ArrowRule{Match: "all", Conditions: []ArrowCondition{{Operator: "eval", Value: &n}}}
		},
		"empty rule": func(a, b *Node) { a.ArrowVisibleRule = &ArrowRule{Match: "all"} },
	} {
		t.Run(name, func(t *testing.T) {
			d := saved
			a, b := pipeNode("a"), pipeNode("b")
			change(&a, &b)
			d.Nodes = []Node{a, b}
			if _, err := store.Save(d); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid accepted: %v", err)
			}
			got, _ := store.Get(saved.ID)
			if got.Revision != saved.Revision || len(got.Nodes) != len(saved.Nodes) {
				t.Fatal("invalid save changed document")
			}
		})
	}
}

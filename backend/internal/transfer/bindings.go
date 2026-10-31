package transfer

import (
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func cloneRule(r *process.ArrowRule) *process.ArrowRule {
	if r == nil {
		return nil
	}
	raw, _ := json.Marshal(r)
	var v process.ArrowRule
	_ = json.Unmarshal(raw, &v)
	return &v
}
func sameRuleSemantics(a, b *process.ArrowRule) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if a.Match != b.Match || len(a.Conditions) != len(b.Conditions) {
		return false
	}
	for _, c := range a.Conditions {
		found := false
		for _, d := range b.Conditions {
			if c.Slot == d.Slot && c.Operator == d.Operator && c.Value != nil && d.Value != nil && *c.Value == *d.Value {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}
func stripBindings(d *process.Document) {
	d.Bindings = nil
	for i := range d.Nodes {
		n := &d.Nodes[i]
		n.PointID = ""
		for _, r := range []*process.ArrowRule{n.ArrowVisibleRule, n.ArrowMotionRule} {
			if r != nil {
				for j := range r.Conditions {
					r.Conditions[j].PointID = ""
				}
			}
		}
	}
}
func preserveBindings(d *process.Document, old process.Document) {
	for i := range d.Nodes {
		n := &d.Nodes[i]
		for _, prev := range old.Nodes {
			if prev.ID != n.ID || prev.Kind != n.Kind {
				continue
			}
			n.PointID = prev.PointID
			if sameRuleSemantics(n.ArrowVisibleRule, prev.ArrowVisibleRule) {
				n.ArrowVisibleRule = cloneRule(prev.ArrowVisibleRule)
			}
			if sameRuleSemantics(n.ArrowMotionRule, prev.ArrowMotionRule) {
				n.ArrowMotionRule = cloneRule(prev.ArrowMotionRule)
			}
		}
	}
}
func instanceBindings(d process.Document) map[string]process.ElementBinding {
	out := map[string]process.ElementBinding{}
	for _, n := range d.Nodes {
		if n.Kind == "text" || n.Kind == "image" {
			continue
		}
		b := process.ElementBinding{PointID: n.PointID}
		if n.ArrowVisibleRule != nil {
			b.Visible = n.ArrowVisibleRule.Conditions
		}
		if n.ArrowMotionRule != nil {
			b.Motion = n.ArrowMotionRule.Conditions
		}
		if b.PointID != "" || len(b.Visible) > 0 || len(b.Motion) > 0 {
			out[n.ID] = b
		}
	}
	return out
}

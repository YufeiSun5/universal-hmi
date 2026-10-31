package process

import "fmt"

// Conditions are matched by slot AND comparison, never by their list position.
// Reordering a public rule preserves bindings; changing its meaning unbinds it.
type ElementBinding struct {
	PointID string           `json:"point_id,omitempty"`
	Visible []ArrowCondition `json:"visible,omitempty"`
	Motion  []ArrowCondition `json:"motion,omitempty"`
}

func sameCondition(a, b ArrowCondition) bool {
	return a.Slot == b.Slot && a.Operator == b.Operator && a.Value != nil && b.Value != nil && *a.Value == *b.Value
}
func boundRule(rule *ArrowRule, bindings []ArrowCondition) *ArrowRule {
	if rule == nil {
		return nil
	}
	out := &ArrowRule{Match: rule.Match, Conditions: append([]ArrowCondition{}, rule.Conditions...)}
	for i := range out.Conditions {
		out.Conditions[i].PointID = ""
		for _, b := range bindings {
			if sameCondition(out.Conditions[i], b) {
				out.Conditions[i].PointID = b.PointID
				break
			}
		}
	}
	return out
}
func (s *Service) resolve(d Document) (Document, error) {
	if d.TemplateID == "" {
		return d, nil
	}
	t, err := s.read(d.TemplateID)
	if err != nil {
		return Document{}, err
	}
	if t.Station != "" || t.TemplateID != "" || t.Kind == "gis" {
		return Document{}, fmt.Errorf("%w: 公共画面关联无效", ErrInvalid)
	}
	d.TemplateRevision, d.Width, d.Height = t.Revision, t.Width, t.Height
	d.Assets = t.Assets
	d.Background = t.Background
	d.Nodes = append([]Node{}, t.Nodes...)
	for i := range d.Nodes {
		n := &d.Nodes[i]
		b := d.Bindings[n.ID]
		n.PointID = b.PointID
		n.ArrowVisibleRule = boundRule(n.ArrowVisibleRule, b.Visible)
		n.ArrowMotionRule = boundRule(n.ArrowMotionRule, b.Motion)
	}
	return d, nil
}

func validateInstanceBindings(d, t Document, lookup func(string) (string, bool), cross bool) error {
	nodes := map[string]Node{}
	for _, n := range t.Nodes {
		nodes[n.ID] = n
	}
	check := func(id string) error {
		if id == "" {
			return nil
		}
		if !idPattern.MatchString(id) {
			return fmt.Errorf("%w: 变量身份无效", ErrInvalid)
		}
		if lookup != nil {
			station, ok := lookup(id)
			if !ok || (!cross && station != d.Station) {
				return fmt.Errorf("%w: 绑定变量必须属于目标站点 %s", ErrInvalid, d.Station)
			}
		}
		return nil
	}
	for id, b := range d.Bindings {
		n, ok := nodes[id]
		if !ok || n.Kind == "text" || n.Kind == "image" {
			return fmt.Errorf("%w: 绑定元素不存在或不可绑定，请刷新公共布局", ErrInvalid)
		}
		if err := check(b.PointID); err != nil {
			return err
		}
		for _, pair := range []struct {
			rule     *ArrowRule
			bindings []ArrowCondition
		}{{n.ArrowVisibleRule, b.Visible}, {n.ArrowMotionRule, b.Motion}} {
			if len(pair.bindings) > 8 {
				return fmt.Errorf("%w: 条件绑定过多", ErrInvalid)
			}
			for i, c := range pair.bindings {
				found := false
				if pair.rule != nil {
					for _, original := range pair.rule.Conditions {
						if sameCondition(c, original) {
							found = true
							break
						}
					}
				}
				for _, previous := range pair.bindings[:i] {
					if sameCondition(c, previous) {
						return fmt.Errorf("%w: 重复的条件绑定", ErrInvalid)
					}
				}
				if !found {
					return fmt.Errorf("%w: 公共条件已变化，请刷新后重新绑定", ErrInvalid)
				}
				if err := check(c.PointID); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

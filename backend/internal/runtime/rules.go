package runtime

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"slices"
)

func sameRule(a, b Rule) bool {
	// The display name does not change execution semantics or re-arm an edge.
	return a.Station == b.Station && a.ID == b.ID && a.Enabled == b.Enabled && a.Logic == b.Logic && a.HoldMS == b.HoldMS && a.CooldownMS == b.CooldownMS && a.Trigger == b.Trigger && slices.Equal(a.Conditions, b.Conditions) && slices.Equal(a.Actions, b.Actions)
}

func (e *Engine) validateRulesLocked(rules []Rule) error {
	if len(rules) > 200 {
		return fmt.Errorf("rule limit")
	}
	ids := make(map[string]bool, len(rules))
	for _, r := range rules {
		if r.ID == "" || ids[r.ID] || r.Name == "" || len(r.Conditions) == 0 || len(r.Conditions) > 32 || len(r.Actions) == 0 || len(r.Actions) > 16 || r.HoldMS < 0 || r.HoldMS > 3600000 || r.CooldownMS < 200 || r.CooldownMS > 86400000 || (r.Logic != "and" && r.Logic != "or") || (r.Trigger != "rising" && r.Trigger != "periodic" && r.Trigger != "recovery") {
			return fmt.Errorf("invalid rule")
		}
		ids[r.ID] = true
		if len(r.Station) > 128 || !e.ruleInScope(r) {
			return fmt.Errorf("rule references must belong to its station")
		}
		for _, c := range r.Conditions {
			if e.pointIndex[c.PointID].ID == "" || !slices.Contains([]string{">", ">=", "<", "<=", "==", "!="}, c.Op) || math.IsNaN(c.Value) || math.IsInf(c.Value, 0) {
				return fmt.Errorf("invalid condition")
			}
		}
		for _, a := range r.Actions {
			switch a.Type {
			case "write":
				if !e.pointIndex[a.PointID].Writable {
					return fmt.Errorf("action target is not writable")
				}
				if math.IsNaN(a.Value) || math.IsInf(a.Value, 0) {
					return fmt.Errorf("finite action value required")
				}
			case "snapshot", "storage_start", "storage_stop":
			default:
				return fmt.Errorf("invalid action")
			}
		}
	}
	return nil
}

// An omitted threshold must not turn into a real zero-valued condition that can
// trigger an enabled rule. Explicit zero remains valid.
func (c *Condition) UnmarshalJSON(data []byte) error {
	var value struct {
		PointID string   `json:"point_id"`
		Op      string   `json:"op"`
		Value   *float64 `json:"value"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	if value.Value == nil {
		return fmt.Errorf("condition value required")
	}
	*c = Condition{PointID: value.PointID, Op: value.Op, Value: *value.Value}
	return nil
}

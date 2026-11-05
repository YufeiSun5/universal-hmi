package process

import (
	"fmt"
	"math"
	"strings"
)

// Display settings interpret the node's existing PointID; they never issue
// commands, derive stored points, or change the input point's engineering unit.
type StateDisplay struct {
	ActiveValue   *float64 `json:"active_value"`
	InactiveValue *float64 `json:"inactive_value"`
	ActiveText    string   `json:"active_text"`
	InactiveText  string   `json:"inactive_text"`
	ActiveColor   string   `json:"active_color"`
	InactiveColor string   `json:"inactive_color"`
}

type LevelDisplay struct {
	Minimum     *float64 `json:"minimum"`
	Maximum     *float64 `json:"maximum"`
	Orientation string   `json:"orientation"`
}

func finiteDisplayValue(v *float64) bool {
	return v != nil && !math.IsNaN(*v) && !math.IsInf(*v, 0)
}

func validateDisplay(n Node) error {
	invalid := func(message string) error { return fmt.Errorf("%w: %s", ErrInvalid, message) }
	if s := n.StateDisplay; s != nil {
		if n.Kind != "symbol" {
			return invalid("state lamp requires an equipment symbol")
		}
		if !finiteDisplayValue(s.ActiveValue) || !finiteDisplayValue(s.InactiveValue) || *s.ActiveValue == *s.InactiveValue {
			return invalid("state values must be finite and distinct")
		}
		if strings.TrimSpace(s.ActiveText) == "" || strings.TrimSpace(s.InactiveText) == "" || len(s.ActiveText) > 96 || len(s.InactiveText) > 96 || !colorPattern.MatchString(s.ActiveColor) || !colorPattern.MatchString(s.InactiveColor) {
			return invalid("invalid state labels or colors")
		}
	}
	if l := n.LevelDisplay; l != nil {
		if n.Kind != "level" || !finiteDisplayValue(l.Minimum) || !finiteDisplayValue(l.Maximum) || *l.Maximum <= *l.Minimum || math.IsInf(*l.Maximum-*l.Minimum, 0) {
			return invalid("level limits require finite maximum greater than minimum")
		}
		if l.Orientation != "vertical" && l.Orientation != "horizontal" {
			return invalid("invalid level orientation")
		}
	} else if n.Kind == "level" {
		return invalid("level display limits required")
	}
	return nil
}

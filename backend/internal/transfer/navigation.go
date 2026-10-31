package transfer

import (
	"context"
	"fmt"
	"reflect"

	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

// Navigation uses portable screen keys; physical station keys remain unchanged.
type Navigation struct {
	Enabled bool             `json:"enabled"`
	Nodes   []NavigationNode `json:"nodes"`
}
type NavigationNode struct {
	ID        string           `json:"id"`
	Label     string           `json:"label"`
	ScreenKey string           `json:"screen_key,omitempty"`
	Children  []NavigationNode `json:"children,omitempty"`
}
type NavigationTarget struct {
	Mode     string `json:"mode"`
	Revision int64  `json:"revision"`
}

func (s *Service) planNavigation(ctx context.Context, r Request, out *Result, docs map[string]process.Document, commit bool) error {
	if r.Bundle.Navigation == nil {
		return nil
	}
	add := func(status, msg string, before, after any) {
		it := Item{Kind: "navigation", Key: "page_navigation", Status: status, Message: msg, Before: before, After: after}
		out.Items = append(out.Items, it)
		if status == "error" || status == "unresolved" || status == "failed" {
			out.Remaining = append(out.Remaining, it)
		}
	}
	if s.Navigation == nil {
		add("error", "navigation service unavailable", nil, nil)
		return nil
	}
	old, err := s.Navigation.Get()
	if err != nil {
		return err
	}
	if r.NavigationTarget == nil || r.NavigationTarget.Mode == "" {
		add("unresolved", "explicit create/replace/skip navigation choice required", old, nil)
		return nil
	}
	if r.NavigationTarget.Mode == "skip" {
		add("skipped", "navigation explicitly skipped", old, nil)
		return nil
	}
	statuses := map[string]string{}
	for _, it := range out.Items {
		if it.Kind == "screen" {
			statuses[it.Key] = it.Status
		}
	}
	count := 0
	var resolve func([]NavigationNode, int) ([]navigation.Node, error)
	resolve = func(nodes []NavigationNode, depth int) ([]navigation.Node, error) {
		result := make([]navigation.Node, 0, len(nodes))
		for _, node := range nodes {
			count++
			if count > 256 || depth > 4 {
				return nil, fmt.Errorf("navigation exceeds 4 levels or 256 nodes")
			}
			n := navigation.Node{ID: node.ID, Label: node.Label}
			if node.ScreenKey != "" {
				if len(node.Children) > 0 {
					return nil, fmt.Errorf("navigation leaf cannot have children")
				}
				d, ok := docs[node.ScreenKey]
				status := statuses[node.ScreenKey]
				if !ok || (status != "ready" && status != "saved" && status != "unchanged") {
					return nil, fmt.Errorf("navigation screen key %s is missing or not ready", node.ScreenKey)
				}
				if !stationAllowed(ctx, d.Station) {
					return nil, fmt.Errorf("navigation screen permission denied")
				}
				n.ScreenID = d.ID
			} else {
				var e error
				n.Children, e = resolve(node.Children, depth+1)
				if e != nil {
					return nil, e
				}
			}
			result = append(result, n)
		}
		return result, nil
	}
	nodes, err := resolve(r.Bundle.Navigation.Nodes, 1)
	if err != nil {
		add("error", err.Error(), old, nil)
		return nil
	}
	next := navigation.Config{Revision: old.Revision, Enabled: r.Bundle.Navigation.Enabled, Nodes: nodes}
	known := map[string]bool{}
	for _, d := range docs {
		known[d.ID] = true
	}
	if err := navigation.Validate(next, func(id string) error {
		if !known[id] {
			return fmt.Errorf("unknown imported screen")
		}
		return nil
	}); err != nil {
		add("error", err.Error(), old, next)
		return nil
	}
	if old.Enabled == next.Enabled && reflect.DeepEqual(old.Nodes, next.Nodes) {
		add("unchanged", "identical navigation", old, next)
		return nil
	}
	target := r.NavigationTarget
	if target.Mode != "create" && target.Mode != "replace" {
		add("error", "invalid navigation mode", old, next)
		return nil
	}
	if target.Revision != old.Revision {
		add("error", "navigation revision conflict", old, next)
		return nil
	}
	if target.Mode == "create" && (old.Enabled || len(old.Nodes) > 0) {
		add("error", "existing navigation requires explicit replace", old, next)
		return nil
	}
	status := "ready"
	if commit {
		if !allowed(ctx) {
			add("failed", "permission revoked", old, next)
			return nil
		}
		saved, err := s.Navigation.Save(next)
		if err != nil {
			add("failed", err.Error(), old, next)
			return nil
		}
		next = saved
		status = "saved"
	}
	add(status, "", old, next)
	return nil
}

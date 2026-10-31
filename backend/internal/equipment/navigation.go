package equipment

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

// Navigation is presentation only: references never change device ownership or
// prevent station deletion. Missing station targets are omitted on reads.
type NavigationNode struct {
	ID       string           `json:"id"`
	Label    string           `json:"label"`
	Station  string           `json:"station,omitempty"`
	Site     string           `json:"site,omitempty"`
	Children []NavigationNode `json:"children,omitempty"`
}
type Navigation struct {
	Revision int64            `json:"revision"`
	Nodes    []NavigationNode `json:"nodes"`
}

var navigationID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`)

func (s *Service) loadNavigation() (Navigation, error) {
	c := Navigation{Nodes: []NavigationNode{}}
	err := s.repo.LoadConfig("equipment_navigation", &c)
	return c, err
}

func (s *Service) Navigation(ctx context.Context) (Navigation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if a, ok := authorization.FromContext(ctx); ok && !a.Active() {
		return Navigation{}, authorization.ErrDenied
	}
	c, err := s.loadNavigation()
	if err != nil {
		return Navigation{}, err
	}
	names, err := s.stations()
	if err != nil {
		return Navigation{}, err
	}
	existing := map[string]bool{}
	for _, name := range names {
		existing[name] = true
	}
	var filter func([]NavigationNode) []NavigationNode
	filter = func(nodes []NavigationNode) []NavigationNode {
		out := []NavigationNode{}
		for _, n := range nodes {
			if n.Station != "" {
				if existing[n.Station] && allowed(ctx, n.Station, false) {
					n.Children = nil
					out = append(out, n)
				}
			} else {
				n.Children = filter(n.Children)
				if len(n.Children) > 0 {
					out = append(out, n)
				}
			}
		}
		return out
	}
	c.Nodes = filter(c.Nodes)
	return c, nil
}

func (s *Service) SaveNavigation(ctx context.Context, c Navigation) (Navigation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	canEdit := func() bool {
		a, managed := authorization.FromContext(ctx)
		return !managed || a.Active() && a.Grants.AllStations && a.Grants.Develop()
	}
	if !canEdit() {
		return Navigation{}, authorization.ErrDenied
	}
	old, err := s.loadNavigation()
	if err != nil {
		return Navigation{}, err
	}
	if c.Revision != old.Revision {
		return Navigation{}, ErrConflict
	}
	names, err := s.stations()
	if err != nil {
		return Navigation{}, err
	}
	existing := map[string]bool{}
	for _, name := range names {
		existing[name] = true
	}
	seen := map[string]bool{}
	count := 0
	validText := func(v string, limit int) bool { return len(v) <= limit && !strings.ContainsAny(v, "\x00\r\n") }
	var visit func([]NavigationNode, int) error
	visit = func(nodes []NavigationNode, depth int) error {
		for _, n := range nodes {
			count++
			if depth > 4 || count > 256 || !navigationID.MatchString(n.ID) || seen[n.ID] || strings.TrimSpace(n.Label) == "" || !validText(n.Label, 256) || !validText(n.Station, 256) || !validText(n.Site, 256) {
				return fmt.Errorf("设备菜单最多4层256项，名称不能为空或超长，ID不可重复")
			}
			seen[n.ID] = true
			if n.Station != "" {
				if len(n.Children) > 0 || !existing[n.Station] {
					return fmt.Errorf("设备菜单目标站区不存在或目标项包含子菜单")
				}
			} else if n.Site != "" || len(n.Children) == 0 {
				return fmt.Errorf("设备菜单分组须包含子项且不能指定分区")
			}
			if err := visit(n.Children, depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if err := visit(c.Nodes, 1); err != nil {
		return Navigation{}, err
	}
	if c.Nodes == nil {
		c.Nodes = []NavigationNode{}
	}
	c.Revision++
	if !canEdit() {
		return Navigation{}, authorization.ErrDenied
	}
	if err := s.repo.SaveConfig("equipment_navigation", c); err != nil {
		return Navigation{}, err
	}
	return c, nil
}

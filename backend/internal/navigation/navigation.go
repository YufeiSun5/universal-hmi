// Package navigation owns presentation menus, independently of station data.
package navigation

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
)

var ErrConflict = errors.New("navigation revision conflict")
var ErrInvalid = errors.New("invalid navigation")
var identity = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`)
var screenIdentity = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,96}$`)

type Node struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	ScreenID string `json:"screen_id,omitempty"`
	Children []Node `json:"children,omitempty"`
}
type Config struct {
	Revision int64  `json:"revision"`
	Enabled  bool   `json:"enabled"`
	Nodes    []Node `json:"nodes"`
}
type Store interface {
	LoadConfig(string, any) error
	SaveConfig(string, any) error
}
type Service struct {
	mu     sync.Mutex
	store  Store
	exists func(string) error
}

func New(store Store, exists func(string) error) *Service {
	return &Service{store: store, exists: exists}
}
func (s *Service) load() (Config, error) {
	c := Config{Nodes: []Node{}}
	err := s.store.LoadConfig("page_navigation", &c)
	return c, err
}
func (s *Service) Get() (Config, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.load() }
func (s *Service) Save(c Config) (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, err := s.load()
	if err != nil {
		return Config{}, err
	}
	if c.Revision != old.Revision {
		return Config{}, ErrConflict
	}
	if err := Validate(c, s.exists); err != nil {
		return Config{}, err
	}
	if c.Nodes == nil {
		c.Nodes = []Node{}
	}
	c.Revision++
	if err := s.store.SaveConfig("page_navigation", c); err != nil {
		return Config{}, err
	}
	return c, nil
}

// Validate checks a candidate without writing configuration.
func Validate(c Config, exists func(string) error) error {
	seen := map[string]bool{}
	count := 0
	var visit func([]Node, int) error
	visit = func(nodes []Node, depth int) error {
		for _, n := range nodes {
			count++
			if depth > 4 || count > 256 || !identity.MatchString(n.ID) || seen[n.ID] || strings.TrimSpace(n.Label) == "" || len(n.Label) > 256 {
				return fmt.Errorf("%w: 菜单最多4层256项，名称不能为空，ID不可重复", ErrInvalid)
			}
			seen[n.ID] = true
			if n.ScreenID != "" {
				if len(n.Children) > 0 || !screenIdentity.MatchString(n.ScreenID) {
					return fmt.Errorf("%w: 画面项不能包含子菜单", ErrInvalid)
				}
				if err := exists(n.ScreenID); err != nil {
					return fmt.Errorf("%w: 目标画面不可用 %s", ErrInvalid, n.ScreenID)
				}
			}
			if err := visit(n.Children, depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if err := visit(c.Nodes, 1); err != nil {
		return err
	}
	return nil
}

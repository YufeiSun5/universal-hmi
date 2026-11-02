// Package overview owns the presentation configuration of the live report.
// It never creates variables, computes engineering values or writes equipment.
package overview

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

const ConfigKey = "live_overview_v1"

var ErrConflict = errors.New("overview revision conflict")
var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,96}$`)

type Column struct {
	ID       string `json:"id"`
	Group    string `json:"group"`
	Name     string `json:"name"`
	Decimals int    `json:"decimals"`
}
type Row struct {
	ID       string            `json:"id"`
	Area     string            `json:"area"`
	Name     string            `json:"name"`
	Station  string            `json:"station"`
	Bindings map[string]string `json:"bindings"`
}
type Config struct {
	Revision int64    `json:"revision"`
	Columns  []Column `json:"columns"`
	Rows     []Row    `json:"rows"`
}
type Store interface {
	LoadConfig(string, any) error
	SaveConfig(string, any) error
}
type Service struct {
	mu    sync.Mutex
	store Store
}

func New(store Store) *Service { return &Service{store: store} }
func (s *Service) load() (Config, error) {
	c := Config{Columns: []Column{}, Rows: []Row{}}
	err := s.store.LoadConfig(ConfigKey, &c)
	return c, err
}

// Get filters both row scope and individual cross-station references. The caller
// supplies the existing authorized point catalog, not a client-selected scope.
func (s *Service) Get(ctx context.Context, visible map[string]bool) (Config, error) {
	a, managed := authorization.FromContext(ctx)
	if managed && !a.Active() {
		return Config{}, authorization.ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.load()
	if err != nil {
		return Config{}, err
	}
	if !managed || a.Grants.Develop() {
		return c, nil
	}
	rows := []Row{}
	for _, r := range c.Rows {
		if !a.Station(r.Station) {
			continue
		}
		bindings := map[string]string{}
		for col, id := range r.Bindings {
			if visible[id] {
				bindings[col] = id
			}
		}
		r.Bindings = bindings
		rows = append(rows, r)
	}
	c.Rows = rows
	return c, nil
}
func text(v string, optional bool) bool {
	return (optional || strings.TrimSpace(v) != "") && len(v) <= 256 && !strings.ContainsAny(v, "\x00\r\n")
}
func Validate(c Config, points map[string]bool, station func(string) error) error {
	if c.Revision < 0 || len(c.Columns) > 64 || len(c.Rows) > 256 || len(c.Columns)*len(c.Rows) > 8192 {
		return errors.New("总览最多64列、256行、8192个单元格")
	}
	cols, rows := map[string]bool{}, map[string]bool{}
	for _, v := range c.Columns {
		if !idPattern.MatchString(v.ID) || cols[v.ID] || !text(v.Group, false) || !text(v.Name, false) || v.Decimals < 0 || v.Decimals > 6 {
			return errors.New("列标识不可重复，分组和名称必填，小数位为0至6")
		}
		cols[v.ID] = true
	}
	for _, r := range c.Rows {
		if !idPattern.MatchString(r.ID) || rows[r.ID] || !text(r.Name, false) || !text(r.Area, true) || !text(r.Station, false) {
			return errors.New("行标识不可重复，名称和实际站点必填")
		}
		rows[r.ID] = true
		if err := station(r.Station); err != nil {
			return fmt.Errorf("站点不可用: %w", err)
		}
		for col, id := range r.Bindings {
			if !cols[col] || !points[id] {
				return errors.New("绑定列或变量不存在，请重新选择")
			}
		}
	}
	return nil
}
func (s *Service) Save(ctx context.Context, c Config, points map[string]bool, station func(string) error) (Config, error) {
	if a, ok := authorization.FromContext(ctx); ok && (!a.Active() || !a.Grants.Develop()) {
		return Config{}, authorization.ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	old, err := s.load()
	if err != nil {
		return Config{}, err
	}
	if old.Revision != c.Revision {
		return Config{}, ErrConflict
	}
	if err = Validate(c, points, station); err != nil {
		return Config{}, err
	}
	if c.Rows == nil {
		c.Rows = []Row{}
	}
	if c.Columns == nil {
		c.Columns = []Column{}
	}
	c.Revision++
	if err = s.store.SaveConfig(ConfigKey, c); err != nil {
		return Config{}, err
	}
	return c, nil
}

// Package stations owns the explicit station directory. Legacy station names
// remain immutable keys; creating a station never creates points or connections.
package stations

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

var ErrInvalid = errors.New("invalid station")
var ErrExists = errors.New("station already exists")

type Store interface {
	LoadConfig(string, any) error
	SaveConfig(string, any) error
}
type Station struct {
	Name string `json:"name"`
}
type Service struct {
	mu     sync.Mutex
	store  Store
	legacy func() ([]string, error)
}

func New(store Store, legacy func() ([]string, error)) *Service {
	return &Service{store: store, legacy: legacy}
}
func (s *Service) list() ([]Station, error) {
	names := []string{}
	if err := s.store.LoadConfig("station_directory", &names); err != nil {
		return nil, err
	}
	if s.legacy != nil {
		old, err := s.legacy()
		if err != nil {
			return nil, err
		}
		names = append(names, old...)
	}
	seen := map[string]bool{}
	for _, n := range names {
		if n != "" {
			seen[n] = true
		}
	}
	names = names[:0]
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]Station, 0, len(names))
	for _, n := range names {
		out = append(out, Station{Name: n})
	}
	return out, nil
}
func (s *Service) List() ([]Station, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.list() }

// CheckWritable preserves implicit first-time station creation (including MQTT
// archive groups), but an explicitly deleted name needs explicit recreation.
func (s *Service) CheckWritable(name string) error {
	if name == "" {
		return nil
	}
	var deleted, explicit []string
	if err := s.store.LoadConfig("station_directory_deleted", &deleted); err != nil {
		return err
	}
	for _, n := range deleted {
		if n != name {
			continue
		}
		if err := s.store.LoadConfig("station_directory", &explicit); err != nil {
			return err
		}
		for _, restored := range explicit {
			if restored == name {
				return nil
			}
		}
		return fmt.Errorf("%w: 站点已删除，请先显式重新创建同名站点", ErrInvalid)
	}
	return nil
}
func (s *Service) Create(name string) (Station, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 256 || !utf8.ValidString(name) || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return Station{}, fmt.Errorf("%w: 站点名称不能为空、含控制字符或超过256字节", ErrInvalid)
	}
	all, err := s.list()
	if err != nil {
		return Station{}, err
	}
	for _, st := range all {
		if st.Name == name {
			return Station{}, ErrExists
		}
	}
	if len(all) >= 1000 {
		return Station{}, fmt.Errorf("%w: 最多1000个站点", ErrInvalid)
	}
	// Persist discovered stations too, so removing their final point/screen does
	// not silently remove the station from the workspace.
	names := make([]string, 0, len(all)+1)
	for _, st := range all {
		names = append(names, st.Name)
	}
	names = append(names, name)
	var deleted []string
	if err := s.store.LoadConfig("station_directory_deleted", &deleted); err != nil {
		return Station{}, err
	}
	kept := []string{}
	for _, n := range deleted {
		if n != name {
			kept = append(kept, n)
		}
	}
	if batch, ok := s.store.(interface{ SaveConfigs(map[string]any) error }); ok {
		if err := batch.SaveConfigs(map[string]any{"station_directory": names, "station_directory_deleted": kept}); err != nil {
			return Station{}, err
		}
		return Station{Name: name}, nil
	}
	if err := s.store.SaveConfig("station_directory", names); err != nil {
		return Station{}, err
	}
	return Station{Name: name}, nil
}

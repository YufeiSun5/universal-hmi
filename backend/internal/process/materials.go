package process

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const MaxMaterials = 256
const MaxMaterialBytes = 3 * 1024 * 1024

// Materials are workspace-wide artwork. Placing one copies its original bytes
// into the screen document: deleting or changing the library cannot alter it.
type Material struct {
	SchemaVersion int    `json:"schema_version"`
	ID            string `json:"id"`
	Revision      int64  `json:"revision"`
	Name          string `json:"name"`
	Category      string `json:"category"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	Asset         Asset  `json:"asset"`
}

type MaterialSummary struct {
	ID       string `json:"id"`
	Revision int64  `json:"revision"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

func (s *Service) materialsDir() string { return filepath.Join(s.dir, "materials") }

func (s *Service) openMaterials() error {
	if err := os.MkdirAll(s.materialsDir(), 0700); err != nil {
		return err
	}
	s.materials = map[string]MaterialSummary{}
	entries, err := os.ReadDir(s.materialsDir())
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		m, err := s.readMaterial(strings.TrimSuffix(entry.Name(), ".json"))
		if err != nil {
			return err
		}
		validated, err := validateMaterial(m)
		if err != nil || validated.Width != m.Width || validated.Height != m.Height {
			return fmt.Errorf("invalid persisted material: %w", ErrInvalid)
		}
		s.materials[m.ID] = summarizeMaterial(m)
	}
	if len(s.materials) > MaxMaterials {
		return fmt.Errorf("material limit exceeded")
	}
	return nil
}

func validateMaterial(m Material) (Material, error) {
	if m.SchemaVersion != 1 || !idPattern.MatchString(m.ID) || m.Revision < 0 || m.Revision >= 9007199254740991 || strings.TrimSpace(m.Name) == "" || len(m.Name) > 256 || len(m.Category) > 256 {
		return Material{}, fmt.Errorf("%w: material identity/name/category", ErrInvalid)
	}
	config, err := validateAsset(m.Asset)
	if err != nil {
		return Material{}, err
	}
	// Dimensions are authoritative decoded metadata, not supplied client values.
	m.Width, m.Height = config.Width, config.Height
	return m, nil
}

func (s *Service) readMaterial(id string) (Material, error) {
	var m Material
	if !idPattern.MatchString(id) {
		return m, ErrInvalid
	}
	path := filepath.Join(s.materialsDir(), id+".json")
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return m, ErrNotFound
	}
	if err != nil {
		return m, err
	}
	if info.Size() > MaxMaterialBytes {
		return m, ErrInvalid
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return m, err
	}
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&m); err != nil {
		return m, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF || m.ID != id || m.Revision < 1 {
		return m, fmt.Errorf("invalid persisted material")
	}
	return m, nil
}

func summarizeMaterial(m Material) MaterialSummary {
	return MaterialSummary{m.ID, m.Revision, m.Name, m.Category, m.Width, m.Height}
}

func (s *Service) listMaterials() ([]MaterialSummary, error) {
	items := make([]MaterialSummary, 0)
	for _, m := range s.materials {
		items = append(items, m)
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Name == items[j].Name {
			return items[i].ID < items[j].ID
		}
		return items[i].Name < items[j].Name
	})
	return items, nil
}

func (s *Service) ListMaterials() ([]MaterialSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listMaterials()
}

func (s *Service) GetMaterial(id string) (Material, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readMaterial(id)
}

func (s *Service) SaveMaterial(m Material) (Material, error) {
	m, err := validateMaterial(m)
	if err != nil {
		return Material{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, err := s.readMaterial(m.ID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return Material{}, err
	}
	if errors.Is(err, ErrNotFound) {
		if m.Revision != 0 {
			return Material{}, ErrConflict
		}
		items, err := s.listMaterials()
		if err != nil {
			return Material{}, err
		}
		if len(items) >= MaxMaterials {
			return Material{}, fmt.Errorf("%w: at most %d materials", ErrInvalid, MaxMaterials)
		}
	} else if previous.Revision != m.Revision {
		return Material{}, ErrConflict
	}
	m.Revision++
	b, err := json.Marshal(m)
	if err != nil {
		return Material{}, err
	}
	if len(b) > MaxMaterialBytes {
		return Material{}, ErrInvalid
	}
	if err := writeAtomic(s.materialsDir(), m.ID, b); err != nil {
		return Material{}, err
	}
	s.materials[m.ID] = summarizeMaterial(m)
	return m, nil
}

func (s *Service) DeleteMaterial(id string, revision int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMaterial(id)
	if err != nil {
		return err
	}
	if revision != m.Revision {
		return ErrConflict
	}
	if err := os.Remove(filepath.Join(s.materialsDir(), id+".json")); err != nil {
		return err
	}
	delete(s.materials, id)
	return nil
}

package process

import (
	"os"
	"path/filepath"
	"strings"
)

// DocumentStore is a public persistence port. Validation stays in this module.
type DocumentStore interface {
	Load(kind, id string) ([]byte, error)
	Names(kind string) ([]string, error)
	Save(kind, id string, data []byte) error
	Delete(kind, id string) error
}

func (s *Service) kind(dir string) string {
	if dir == s.dir {
		return "screens"
	}
	return "materials"
}
func (s *Service) names(dir string) ([]string, error) {
	if s.documents != nil {
		return s.documents.Names(s.kind(dir))
	}
	entries, e := os.ReadDir(dir)
	if e != nil {
		return nil, e
	}
	names := []string{}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			names = append(names, strings.TrimSuffix(entry.Name(), ".json"))
		}
	}
	return names, nil
}
func (s *Service) bytes(dir, id string, max int) ([]byte, error) {
	var b []byte
	var e error
	if s.documents != nil {
		b, e = s.documents.Load(s.kind(dir), id)
	} else {
		path := filepath.Join(dir, id+".json")
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if info.Size() > int64(max) {
			return nil, ErrInvalid
		}
		b, e = os.ReadFile(path)
	}
	if len(b) > max {
		return nil, ErrInvalid
	}
	return b, e
}
func (s *Service) write(dir, id string, b []byte) error {
	if s.documents != nil {
		return s.documents.Save(s.kind(dir), id, b)
	}
	return writeAtomic(dir, id, b)
}
func (s *Service) remove(dir, id string) error {
	if s.documents != nil {
		return s.documents.Delete(s.kind(dir), id)
	}
	return os.Remove(filepath.Join(dir, id+".json"))
}

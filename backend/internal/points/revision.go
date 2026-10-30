package points

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

func Revision(p Definition) string {
	b, _ := json.Marshal(p)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// DeleteBatchRevisions validates the entire selection before one configuration
// write. It changes saved definitions only, never the active runtime version.
func (s *Service) DeleteBatchRevisions(targets map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(targets) == 0 {
		return fmt.Errorf("%w: empty delete selection", ErrInvalid)
	}
	found := 0
	next := make([]Definition, 0, len(s.rows))
	for _, p := range s.rows {
		if revision, ok := targets[p.ID]; ok {
			if revision == "" || Revision(p) != revision {
				return fmt.Errorf("%w: revision conflict", ErrInvalid)
			}
			found++
		} else {
			next = append(next, p)
		}
	}
	if found != len(targets) {
		return fmt.Errorf("%w: missing selected point", ErrInvalid)
	}
	if e := s.save(next); e != nil {
		return e
	}
	s.rows = next
	return nil
}
func Normalize(in CreateInput) (Definition, error) { return normalize(in) }

// UpdateRevision compares and writes under the same configuration lock.
func (s *Service) UpdateRevision(id, revision string, in CreateInput) (Definition, error) {
	p, e := normalize(in)
	if e != nil {
		return p, e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	index := -1
	for i, row := range s.rows {
		if row.ID == id {
			if Revision(row) != revision {
				return p, fmt.Errorf("%w: revision conflict", ErrInvalid)
			}
			if row.Station != p.Station {
				return p, fmt.Errorf("%w: ownership cannot change", ErrInvalid)
			}
			index = i
			continue
		}
		if row.Station == p.Station && row.Name == p.Name || p.SourceType == "mqtt" && row.SourceType == "mqtt" && row.SourceID == p.SourceID && row.Topic == p.Topic && row.SourcePath == p.SourcePath {
			return p, fmt.Errorf("%w: duplicate identity", ErrInvalid)
		}
	}
	if index < 0 {
		return p, fmt.Errorf("%w: point not found", ErrInvalid)
	}
	p.ID = id
	next := append([]Definition(nil), s.rows...)
	next[index] = p
	if e = s.save(next); e != nil {
		return Definition{}, e
	}
	s.rows = next
	return p, nil
}

// CreateIdentity creates a caller-owned stable import identity. It never matches
// by a display name and treats identical retries as successful no-ops.
func (s *Service) CreateIdentity(id string, in CreateInput) (Definition, bool, error) {
	p, e := normalize(in)
	if e != nil {
		return p, false, e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p.ID = id
	for _, row := range s.rows {
		if row.ID == id {
			if Revision(row) == Revision(p) {
				return row, true, nil
			}
			return p, false, fmt.Errorf("%w: import identity content conflict", ErrInvalid)
		}
		if row.Station == p.Station && row.Name == p.Name || p.SourceType == "mqtt" && row.SourceType == "mqtt" && row.SourceID == p.SourceID && row.Topic == p.Topic && row.SourcePath == p.SourcePath {
			return p, false, fmt.Errorf("%w: duplicate identity", ErrInvalid)
		}
	}
	if len(s.rows) >= MaxDefinitions {
		return p, false, fmt.Errorf("%w: point limit", ErrInvalid)
	}
	next := append(append([]Definition(nil), s.rows...), p)
	if e = s.save(next); e != nil {
		return Definition{}, false, e
	}
	s.rows = next
	return p, false, nil
}

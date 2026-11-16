package process

import (
	"encoding/json"
	"errors"
	"os"
)

// readSummary reads identity and ownership from the persisted document without
// opening image objects. Catalog/navigation reads do not need render payloads;
// Get and startup validation still hydrate and verify every referenced image.
func (s *Service) readSummary(id string) (Summary, error) {
	var d Summary
	if !idPattern.MatchString(id) {
		return d, ErrInvalid
	}
	b, err := s.storedBytes(s.dir, id, MaxDocumentBytes)
	if errors.Is(err, os.ErrNotExist) {
		return d, ErrNotFound
	}
	if err != nil {
		return d, err
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return d, err
	}
	if d.ID != id || d.Revision < 1 {
		return Summary{}, ErrInvalid
	}
	return d, nil
}

// GetSummary exposes saved identity/ownership for navigation authorization, not
// proof that the document's image payload is readable or ready for rendering.
func (s *Service) GetSummary(id string) (Summary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readSummary(id)
}

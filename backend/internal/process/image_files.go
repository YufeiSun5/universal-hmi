package process

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
)

// Only the persisted representation uses file references. The public API and
// portable imports/exports still carry self-contained image bytes; arbitrary
// client references cannot bypass image validation or existing screen permissions.
func (s *Service) imageData(data []byte, hydrate bool, limit int) ([]byte, error) {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	changed := false
	transform := func(raw json.RawMessage) (json.RawMessage, error) {
		var a map[string]json.RawMessage
		if err := json.Unmarshal(raw, &a); err != nil {
			return nil, err
		}
		var value string
		if err := json.Unmarshal(a["data"], &value); err != nil {
			return nil, err
		}
		if hydrate {
			if !objectstore.IsReference([]byte(value)) {
				return raw, nil
			}
			ref, err := objectstore.Parse([]byte(value))
			if err != nil {
				return nil, err
			}
			if ref.Size > MaxImageBytes {
				return nil, ErrInvalid
			}
			b, err := s.files.Get(context.Background(), []byte(value))
			if err != nil {
				return nil, err
			}
			value = base64.StdEncoding.EncodeToString(b)
		} else {
			if objectstore.IsReference([]byte(value)) {
				if _, err := s.files.Get(context.Background(), []byte(value)); err != nil {
					return nil, err
				}
				return raw, nil
			}
			b, err := base64.StdEncoding.Strict().DecodeString(value)
			if err != nil {
				return nil, err
			}
			if len(b) > MaxImageBytes {
				return nil, ErrInvalid
			}
			ref, err := s.files.Put(context.Background(), b)
			if err != nil {
				return nil, err
			}
			value = string(ref)
		}
		changed = true
		a["data"], _ = json.Marshal(value)
		return json.Marshal(a)
	}
	if raw, ok := doc["assets"]; ok && string(raw) != "null" {
		var assets map[string]json.RawMessage
		if err := json.Unmarshal(raw, &assets); err != nil {
			return nil, err
		}
		for id, a := range assets {
			v, err := transform(a)
			if err != nil {
				return nil, fmt.Errorf("image %s: %w", id, err)
			}
			assets[id] = v
		}
		doc["assets"], _ = json.Marshal(assets)
	}
	if a, ok := doc["asset"]; ok {
		v, err := transform(a)
		if err != nil {
			return nil, err
		}
		doc["asset"] = v
	}
	if !changed {
		return data, nil
	}
	out, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	if len(out) > limit {
		return nil, ErrInvalid
	}
	return out, nil
}

func (s *Service) migrateImageDocuments() error {
	for _, dir := range []string{s.dir, s.materialsDir()} {
		ids, err := s.names(dir)
		if err != nil {
			return err
		}
		for _, id := range ids {
			data, err := s.storedBytes(dir, id, MaxDocumentBytes)
			if err != nil {
				return err
			}
			stored, e := s.imageData(data, false, MaxDocumentBytes)
			if e != nil {
				return e
			}
			if bytes.Equal(data, stored) {
				continue
			}
			if err = s.writeStored(dir, id, stored); err != nil {
				return err
			}
		}
	}
	return nil
}

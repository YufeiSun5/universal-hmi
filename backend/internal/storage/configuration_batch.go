package storage

import (
	"context"
	"encoding/json"
)

// SaveConfigs persists a small coordinated configuration update atomically.
func (s *Store) SaveConfigs(values map[string]any) error {
	encoded := map[string]json.RawMessage{}
	for key, value := range values {
		b, err := json.Marshal(value)
		if err != nil {
			return err
		}
		encoded[key] = b
	}
	return s.MaintainConfiguration(context.Background(), true, func(snapshot *ConfigurationSnapshot) error {
		for key, value := range encoded {
			snapshot.Config[key] = value
		}
		return nil
	})
}

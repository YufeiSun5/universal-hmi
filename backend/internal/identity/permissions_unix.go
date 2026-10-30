//go:build !windows

package identity

import (
	"os"
	"path/filepath"
)

func protectStore(dir string) error {
	if err := os.Chmod(dir, 0700); err != nil {
		return err
	}
	for _, name := range []string{"identity.db", "identity.db-wal", "identity.db-shm", "mfa.key"} {
		if err := os.Chmod(filepath.Join(dir, name), 0600); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

//go:build !windows

package projectmigration

import "os"

func protectDirectory(dir string) error { return os.Chmod(dir, 0700) }

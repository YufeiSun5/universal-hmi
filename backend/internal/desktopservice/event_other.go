//go:build !windows

package desktopservice

import (
	"context"
	"errors"
)

func WatchShutdown(ctx context.Context, name string, cancel context.CancelFunc) error {
	if name != "" {
		return errors.New("shutdown events require Windows")
	}
	return nil
}

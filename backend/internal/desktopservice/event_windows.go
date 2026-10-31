package desktopservice

import (
	"context"
	"fmt"
	"golang.org/x/sys/windows"
)

// WatchShutdown opens an event created by this server's service host.
func WatchShutdown(ctx context.Context, name string, cancel context.CancelFunc) error {
	if name == "" {
		return nil
	}
	p, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	h, err := windows.OpenEvent(windows.SYNCHRONIZE, false, p)
	if err != nil {
		return fmt.Errorf("open shutdown event: %w", err)
	}
	go func() {
		defer windows.CloseHandle(h)
		for ctx.Err() == nil {
			r, e := windows.WaitForSingleObject(h, 500)
			if e != nil {
				return
			}
			if r == windows.WAIT_OBJECT_0 {
				cancel()
				return
			}
		}
	}()
	return nil
}

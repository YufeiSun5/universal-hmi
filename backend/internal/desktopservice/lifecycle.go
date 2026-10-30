// Package desktopservice owns only the processes started by an unattended host.
package desktopservice

import (
	"context"
	"errors"
	"fmt"
)

// Processes keeps lifecycle policy independent from Windows and real processes.
type Processes interface {
	Preflight() error
	StartDatabase() error
	StartBackend() error
	WaitBackend(context.Context) error
	StopBackend() error
	StopDatabase() error
}

// Run never stops a database when backend shutdown failed: it may still be using it.
func Run(ctx context.Context, p Processes) error {
	if err := p.Preflight(); err != nil {
		return err
	}
	if err := p.StartDatabase(); err != nil {
		return err
	}
	if err := p.StartBackend(); err != nil {
		return errors.Join(err, p.StopDatabase())
	}
	err := p.WaitBackend(ctx)
	if stopErr := p.StopBackend(); stopErr != nil {
		return errors.Join(err, fmt.Errorf("backend not stopped; database left running: %w", stopErr))
	}
	return errors.Join(err, p.StopDatabase())
}

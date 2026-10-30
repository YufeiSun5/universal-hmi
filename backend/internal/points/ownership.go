package points

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// StationTarget changes ownership only; all other definition fields are retained.
type StationTarget struct {
	ID       string `json:"id"`
	Revision string `json:"revision"`
	Station  string `json:"station"`
}

// ReassignStations checks every revision and the coordinated plan under the
// point configuration lock, then performs one atomic definition save. It does
// not activate runtime configuration or rewrite samples/history.
func (s *Service) ReassignStations(targets []StationTarget, check func([]Definition) (string, []byte, error)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(targets) == 0 || len(targets) > MaxDefinitions || check == nil {
		return fmt.Errorf("%w: invalid ownership selection", ErrInvalid)
	}
	selected := map[string]StationTarget{}
	for _, t := range targets {
		if t.ID == "" || t.Revision == "" || t.Station == "" || len(t.Station) > 128 || strings.TrimSpace(t.Station) != t.Station {
			return fmt.Errorf("%w: incomplete ownership target", ErrInvalid)
		}
		if _, ok := selected[t.ID]; ok {
			return fmt.Errorf("%w: duplicate ownership target", ErrInvalid)
		}
		selected[t.ID] = t
	}
	next := append([]Definition(nil), s.rows...)
	found := 0
	for i, p := range next {
		if t, ok := selected[p.ID]; ok {
			if Revision(p) != t.Revision {
				return fmt.Errorf("%w: ownership revision conflict", ErrInvalid)
			}
			next[i].Station = t.Station
			found++
		}
	}
	if found != len(selected) {
		return fmt.Errorf("%w: missing ownership target", ErrInvalid)
	}
	names := map[string]bool{}
	for _, p := range next {
		key := p.Station + "\x00" + p.Name
		if names[key] {
			return fmt.Errorf("%w: duplicate name in target station", ErrInvalid)
		}
		names[key] = true
	}
	backupID, backup, err := check(append([]Definition(nil), s.rows...))
	if err != nil {
		return err
	}
	if backupID == "" || filepath.Base(backupID) != backupID || len(backup) == 0 {
		return fmt.Errorf("%w: recovery record required", ErrInvalid)
	}
	if s.documents != nil {
		batch, ok := s.documents.(interface {
			SaveWithRecovery(string, string, []byte, string, string, []byte) error
		})
		if !ok {
			return fmt.Errorf("%w: atomic recovery persistence unavailable", ErrInvalid)
		}
		data, err := json.Marshal(next)
		if err != nil {
			return err
		}
		if err = batch.SaveWithRecovery("points", "definitions", data, "ownership_backups", backupID, backup); err != nil {
			return err
		}
	} else {
		dir := filepath.Join(filepath.Dir(s.path), "ownership-backups")
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
		f, err := os.OpenFile(filepath.Join(dir, backupID+".json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		_, err = f.Write(backup)
		if err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		if err := s.save(next); err != nil {
			return err
		}
	}
	s.rows = next
	return nil
}

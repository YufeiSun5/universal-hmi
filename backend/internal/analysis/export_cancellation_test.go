package analysis

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func cancellationFixture(t *testing.T) (*Service, Job) {
	t.Helper()
	dir := t.TempDir()
	db, e := storage.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	ps, e := points.Open(filepath.Join(dir, "points.json"))
	if e != nil {
		t.Fatal(e)
	}
	s, e := New(db, ps, filepath.Join(dir, "exports"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.Close)
	job := Job{ID: ID("export_"), Owner: "synthetic-owner", PermissionVersion: 1, State: "queued", Format: "csv", At: time.Now().UTC()}
	if e = s.update(job); e != nil {
		t.Fatal(e)
	}
	return s, job
}
func assertCancelledOrRemoved(t *testing.T, s *Service, job Job, removed bool) {
	t.Helper()
	s.mu.Lock()
	current, exists := s.jobs[job.ID]
	s.mu.Unlock()
	if removed && exists || !removed && (!exists || current.State != "cancelled") {
		t.Fatalf("terminal cancellation overwritten: exists=%t state=%s", exists, current.State)
	}
	if _, _, e := s.File(job.ID); e == nil {
		t.Fatal("cancelled export downloadable")
	}
	if _, e := os.Stat(filepath.Join(s.dir, job.ID+"."+job.Format)); !os.IsNotExist(e) {
		t.Fatal("cancelled export published artifact", e)
	}
	files, e := filepath.Glob(filepath.Join(s.dir, ".export-*"))
	if e != nil || len(files) != 0 {
		t.Fatal("temporary export leaked", files, e)
	}
	var saved []Job
	if e = s.store.LoadConfig("jobs", &saved); e != nil {
		t.Fatal(e)
	}
	for _, item := range saved {
		if item.ID == job.ID && (removed || item.State != "cancelled") {
			t.Fatal("persisted cancellation overwritten", item.State)
		}
	}
	restarted, e := New(s.store, s.points, s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer restarted.Close()
	restarted.mu.Lock()
	restored, exists := restarted.jobs[job.ID]
	restarted.mu.Unlock()
	if removed && exists || !removed && (!exists || restored.State != "cancelled") {
		t.Fatal("restart resurrected cancellation")
	}
}
func TestExportCancellationWinsInitialAuthorizationRace(t *testing.T) {
	for _, tc := range []struct {
		name               string
		remove, authorized bool
	}{{"cancel_before_running", false, true}, {"remove_before_running", true, true}, {"cancel_before_late_failure", false, false}, {"remove_before_late_failure", true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			s, job := cancellationFixture(t)
			entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var calls atomic.Int32
			actor := authorization.Actor{ID: job.Owner, Version: job.PermissionVersion, Grants: authorization.Grants{Export: true, AllStations: true}, Valid: func() bool {
				if calls.Add(1) == 1 {
					close(entered)
					<-release
				}
				return tc.authorized
			}}
			go func() {
				defer close(done)
				s.run(exportTask{Context: authorization.WithActor(context.Background(), actor), ID: job.ID, Format: job.Format})
			}()
			<-entered // run has already read queued state; no scheduler timing assumption.
			cancelErr := s.Cancel(job.ID)
			var removeErr error
			if cancelErr == nil && tc.remove {
				removeErr = s.Remove(job.ID)
			}
			close(release)
			<-done
			if cancelErr != nil || removeErr != nil {
				t.Fatal(cancelErr, removeErr)
			}
			assertCancelledOrRemoved(t, s, job, tc.remove)
		})
	}
}
func TestExportCancellationWinsFinalAuthorizationRace(t *testing.T) {
	for _, remove := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "cancel_remove"}[remove], func(t *testing.T) {
			s, job := cancellationFixture(t)
			var calls atomic.Int32
			actor := authorization.Actor{ID: job.Owner, Version: 1, Grants: authorization.Grants{Export: true, AllStations: true}, Valid: func() bool {
				// Empty query: initial authorization, loop, Query scope, final publication.
				if calls.Add(1) == 4 {
					if !s.mu.TryLock() {
						t.Error("authorization callback invoked while service mutex held")
						return false
					}
					s.mu.Unlock()
					if e := s.Cancel(job.ID); e != nil {
						t.Error(e)
						return false
					}
					if remove {
						if e := s.Remove(job.ID); e != nil {
							t.Error(e)
							return false
						}
					}
				}
				return true
			}}
			s.run(exportTask{Context: authorization.WithActor(context.Background(), actor), ID: job.ID, Format: job.Format})
			if calls.Load() != 4 {
				t.Fatalf("publication authorization not exercised: %d", calls.Load())
			}
			assertCancelledOrRemoved(t, s, job, remove)
		})
	}
}
func TestExportCancelRemoveAndListCallbacksOutsideMutex(t *testing.T) {
	s, job := cancellationFixture(t)
	actor := authorization.Actor{ID: job.Owner, Version: 1, Grants: authorization.Grants{Export: true}, Valid: func() bool {
		if !s.mu.TryLock() {
			t.Error("callback under service mutex")
			return false
		}
		s.mu.Unlock()
		return true
	}}
	ctx := authorization.WithActor(context.Background(), actor)
	if len(s.Jobs(ctx)) != 1 {
		t.Fatal("job not listed")
	}
	if e := s.Cancel(job.ID, ctx); e != nil {
		t.Fatal(e)
	}
	if e := s.Remove(job.ID, ctx); e != nil {
		t.Fatal(e)
	}
	assertCancelledOrRemoved(t, s, job, true)
}
func TestExportCancelPersistenceFailureIsNotSuccess(t *testing.T) {
	s, job := cancellationFixture(t)
	s.store.Close()
	if e := s.Cancel(job.ID); e == nil {
		t.Fatal("failed durable cancellation reported success")
	}
	s.mu.Lock()
	state := s.jobs[job.ID].State
	s.mu.Unlock()
	if state != "queued" {
		t.Fatal("failed cancellation changed state", state)
	}
}

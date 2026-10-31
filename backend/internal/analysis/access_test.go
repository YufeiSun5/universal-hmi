package analysis

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestExportScopeOwnerAndRevocation(t *testing.T) {
	dir := t.TempDir()
	db, e := storage.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	ps, _ := points.Open(filepath.Join(dir, "points.json"))
	s, e := New(db, ps, filepath.Join(dir, "exports"))
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	now := time.Now()
	db.Append(context.Background(), []storage.Sample{{PointID: "a", Station: "A", Name: "allowed", Value: 1.0, Quality: "good", SourceTime: now, ReceivedTime: now}, {PointID: "b", Station: "B", Name: "secret-B", Value: 2.0, Quality: "good", SourceTime: now, ReceivedTime: now}})
	var active atomic.Bool
	active.Store(true)
	a := authorization.Actor{ID: "reader", Version: 1, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}, Export: true}, StationNames: []string{"A"}, StationID: func(n string) string { return n }, Valid: active.Load}
	ctx := authorization.WithActor(context.Background(), a)
	job, e := s.Export(storage.Filter{}, "csv", ctx)
	if e != nil {
		t.Fatal(e)
	}
	deadline := time.Now().Add(3 * time.Second)
	var path string
	for time.Now().Before(deadline) {
		path, _, e = s.File(job.ID, ctx)
		if e == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e != nil {
		t.Fatal(e)
	}
	data, e := os.ReadFile(path)
	if e != nil || strings.Contains(string(data), "secret-B") || !strings.Contains(string(data), "allowed") {
		t.Fatal("export scope leak", e)
	}
	other := a
	other.ID = "another"
	if _, _, e = s.File(job.ID, authorization.WithActor(context.Background(), other)); e == nil {
		t.Fatal("another user's export downloaded")
	}
	active.Store(false)
	if _, _, e = s.File(job.ID, ctx); e == nil {
		t.Fatal("revoked export downloaded")
	}
	if len(s.Jobs(ctx)) != 0 {
		t.Fatal("revoked job metadata disclosed")
	}
	pending := Job{ID: "queued-fixture", Owner: a.ID, PermissionVersion: 1, State: "queued", Format: "csv"}
	if e = s.update(pending); e != nil {
		t.Fatal(e)
	}
	s.run(exportTask{ID: pending.ID, Context: ctx, Format: "csv"})
	s.mu.Lock()
	state := s.jobs[pending.ID].State
	s.mu.Unlock()
	if state != "failed" {
		t.Fatalf("revoked queued task ran: %s", state)
	}
}

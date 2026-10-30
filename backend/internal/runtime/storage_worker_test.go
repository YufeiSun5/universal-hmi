package runtime

import (
	"context"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestSlowStorageDoesNotHoldRuntimeAndOldCompletionDoesNotSeedNewVersion(t *testing.T) {
	e, ps := policyFixture(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "input", SourceType: "manual", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	if err = e.SetPolicy("", Policy{Enabled: true, IntervalMS: 1000, RetentionDays: 30, ChangedOnly: true}); err != nil {
		t.Fatal(err)
	}
	if err = e.Manual(p.ID, 1.0); err != nil {
		t.Fatal(err)
	}
	// Reserve SQLite's only connection: real SQL must wait, without a fake store.
	conn, err := e.Store.DB.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	e.mu.Lock()
	e.lastPrune = time.Now()
	e.storePoliciesLocked(time.Now())
	stats := e.storageStats
	e.mu.Unlock()
	if stats.PendingBatches != 1 || stats.CommittedSamples != 0 {
		t.Fatal("queued mistaken for committed", stats)
	}
	start := time.Now()
	if err = e.Manual(p.ID, 2.0); err != nil {
		t.Fatal(err)
	}
	if _, err = e.SubscriptionSnapshot(context.Background(), []string{p.ID}); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("database wait held runtime lock")
	}
	if _, err = ps.Create(points.CreateInput{Station: "A", Name: "second", SourceType: "manual", DataType: "FLOAT"}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	conn.Close()
	drainStorage(t, e)
	e.mu.Lock()
	baseline := len(e.lastValues)
	stats = e.storageStats
	e.mu.Unlock()
	if baseline != 0 || stats.CommittedSamples != 1 || stats.PendingSamples != 0 {
		t.Fatal("old completion polluted new runtime", baseline, stats)
	}
	rows, err := e.Store.Query(context.Background(), storage.Filter{})
	if err != nil || len(rows) != 1 || rows[0].Value != 1.0 {
		t.Fatal("frozen pending sample changed", rows, err)
	}
}

func TestStorageTimeoutIsVisibleAndRetryCanRecover(t *testing.T) {
	e, ps := policyFixture(t)
	p, err := ps.Create(points.CreateInput{Station: "A", Name: "input", SourceType: "manual", DataType: "FLOAT", StaleMS: 60000})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	if err = e.SetPolicy("", Policy{Enabled: true, IntervalMS: 1000, RetentionDays: 30, ChangedOnly: true}); err != nil {
		t.Fatal(err)
	}
	e.Manual(p.ID, 3.0)
	conn, err := e.Store.DB.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	e.mu.Lock()
	e.lastPrune = time.Now()
	e.storePoliciesLocked(time.Now())
	e.storePoliciesLocked(time.Now().Add(2 * time.Second))
	e.mu.Unlock()
	drainStorage(t, e)
	e.mu.Lock()
	stats := e.storageStats
	message := e.storageError
	baseline := len(e.lastValues)
	e.mu.Unlock()
	if stats.FailedSamples != 1 || stats.CommittedSamples != 0 || stats.DeferredScans == 0 || message == "" || baseline != 0 {
		t.Fatal("failure hidden or treated as committed", stats, message, baseline)
	}
	conn.Close()
	evaluateAndDrain(t, e, time.Now().Add(2*time.Second))
	e.mu.Lock()
	stats = e.storageStats
	message = e.storageError
	e.mu.Unlock()
	if stats.CommittedSamples != 1 || message != "" {
		t.Fatal("retry did not recover", stats, message)
	}
	e.mu.Lock()
	accepted := e.enqueueStorageLocked(storageTask{operation: "too-large", rows: make([]storage.Sample, 100001)})
	stats = e.storageStats
	e.mu.Unlock()
	if accepted || stats.RejectedSamples != 100001 {
		t.Fatal("unbounded sample queue", stats)
	}
}

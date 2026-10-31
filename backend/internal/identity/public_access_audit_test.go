package identity

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func testAccessEvent() PublicAccessEvent {
	return PublicAccessEvent{IP: "192.0.2.1", Channel: "public:web", Kind: "api_request", Route: "/health", Method: "GET", Status: 200, Decision: "allowed"}
}
func awaitAudit(t *testing.T, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("audit condition timeout")
}
func TestPublicAccessAuditRoundtripAndPagination(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	old, err := s.Audits(a)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.InitPublicAccessAudit(); err != nil {
		t.Fatal(err)
	}
	e := testAccessEvent()
	e.UserID = u.ID
	e.RuleID = "rule-1"
	e.OwnerLabel = "Manual snapshot"
	e.OwnerUserID = "different-owner"
	e.At = time.Unix(0, 0)
	e.Seq = 999
	for i := 0; i < 3; i++ {
		s.RecordPublicAccess(e)
	}
	awaitAudit(t, func() bool {
		var n int
		s.db.QueryRow("SELECT count(*) FROM public_access_events").Scan(&n)
		return n == 3
	})
	page, err := s.PublicAccessEvents(a, 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 2 || page.NextBefore == 0 || page.Items[0].UserID != u.ID || page.Items[0].OwnerUserID == u.ID || page.Items[0].Seq == 999 || page.Items[0].At.Year() == 1970 {
		t.Fatal(page)
	}
	next, err := s.PublicAccessEvents(a, page.NextBefore, 2)
	if err != nil || len(next.Items) != 1 || next.NextBefore != 0 {
		t.Fatal(next, err)
	}
	after, err := s.Audits(a)
	if err != nil || len(after) != len(old) {
		t.Fatal("old audit changed", err)
	}
	if _, err = s.PublicAccessEvents(authorization.Actor{}, 0, 10); !errors.Is(err, ErrDenied) {
		t.Fatal(err)
	}
	if _, err = s.PublicAccessEvents(a, 0, 201); err == nil {
		t.Fatal("unbounded list")
	}
	s.StopPublicAccessAudit()
	s.StopPublicAccessAudit()
	s.RecordPublicAccess(e)
	if s.PublicAccessAuditStatus().Enabled {
		t.Fatal("enabled after stop")
	}
}
func TestPublicAccessAuditSecretsRejectedAndQueueBounded(t *testing.T) {
	// No worker: deterministic saturated queue and no DB dependency on Record.
	s := &Service{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_ = ctx
	a := &publicAccessAudit{queue: make(chan PublicAccessEvent, 256), now: time.Now, status: PublicAccessAuditStatus{Enabled: true}}
	s.publicAudit = a
	mutations := []func(*PublicAccessEvent){func(e *PublicAccessEvent) { e.Route = "/health?token=secret" }, func(e *PublicAccessEvent) { e.Route = "/api/v1/screens/private-secret" }, func(e *PublicAccessEvent) { e.Decision = "password=secret" }, func(e *PublicAccessEvent) { e.UserID = "token secret" }, func(e *PublicAccessEvent) { e.IP = "192.0.2.1,password" }, func(e *PublicAccessEvent) { e.OwnerLabel = "secret\nheader" }, func(e *PublicAccessEvent) { e.Channel = "mobile" }, func(e *PublicAccessEvent) { e.Method = "GET secret" }}
	for _, mutate := range mutations {
		e := testAccessEvent()
		mutate(&e)
		s.RecordPublicAccess(e)
	}
	for i := 0; i < 300; i++ {
		s.RecordPublicAccess(testAccessEvent())
	}
	status := s.PublicAccessAuditStatus()
	if status.QueueDepth != 256 || status.Dropped != uint64(len(mutations)+44) {
		t.Fatal(status)
	}
}
func TestPublicAccessAuditPhysicalIdleRetentionAndCap(t *testing.T) {
	s, _ := fixture(t)
	var mu sync.Mutex
	now := time.Now().UTC()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	if err := s.initPublicAccessAudit(40, 10*time.Millisecond, clock); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		s.RecordPublicAccess(testAccessEvent())
	}
	awaitAudit(t, func() bool {
		return s.PublicAccessAuditStatus().LastWriteAt != nil && s.PublicAccessAuditStatus().QueueDepth == 0
	})
	var count int
	s.db.QueryRow("SELECT count(*) FROM public_access_events").Scan(&count)
	if count > 40 || count == 0 {
		t.Fatal(count)
	}
	mu.Lock()
	now = now.Add(15 * 24 * time.Hour)
	mu.Unlock()
	awaitAudit(t, func() bool {
		s.db.QueryRow("SELECT count(*) FROM public_access_events").Scan(&count)
		return count == 0
	})
}
func TestPublicAccessAuditCleanupFailureStopsGrowthThenRecovers(t *testing.T) {
	s, _ := fixture(t)
	if err := s.initPublicAccessAudit(40, time.Hour, time.Now); err != nil {
		t.Fatal(err)
	}
	s.RecordPublicAccess(testAccessEvent())
	awaitAudit(t, func() bool { return s.PublicAccessAuditStatus().LastWriteAt != nil })
	_, err := s.db.Exec("CREATE TRIGGER reject_access_cleanup BEFORE DELETE ON public_access_events BEGIN SELECT RAISE(ABORT,'synthetic secret'); END")
	if err != nil {
		t.Fatal(err)
	}
	// Fill precisely to cap, then every attempted excess insert must be discarded.
	for i := 0; i < 100; i++ {
		s.RecordPublicAccess(testAccessEvent())
	}
	awaitAudit(t, func() bool {
		return s.PublicAccessAuditStatus().WriteFailures > 0 && s.PublicAccessAuditStatus().QueueDepth == 0
	})
	var count int
	s.db.QueryRow("SELECT count(*) FROM public_access_events").Scan(&count)
	if count > 40 {
		t.Fatal("unbounded growth", count)
	}
	status := s.PublicAccessAuditStatus()
	if status.LastError != "cleanup_failed" || status.Dropped == 0 {
		t.Fatal(status)
	}
	if _, err = s.db.Exec("DROP TRIGGER reject_access_cleanup"); err != nil {
		t.Fatal(err)
	}
	s.RecordPublicAccess(testAccessEvent())
	awaitAudit(t, func() bool { return s.PublicAccessAuditStatus().LastError == "" })
}
func TestPublicAccessAuditWriteFailureAndClose(t *testing.T) {
	s, _ := fixture(t)
	if err := s.InitPublicAccessAudit(); err != nil {
		t.Fatal(err)
	}
	_, err := s.db.Exec("CREATE TRIGGER reject_access_insert BEFORE INSERT ON public_access_events BEGIN SELECT RAISE(ABORT,'synthetic password'); END")
	if err != nil {
		t.Fatal(err)
	}
	s.RecordPublicAccess(testAccessEvent())
	awaitAudit(t, func() bool { return s.PublicAccessAuditStatus().LastError == "write_failed" })
	if _, err = s.db.Exec("DROP TRIGGER reject_access_insert"); err != nil {
		t.Fatal(err)
	}
	s.RecordPublicAccess(testAccessEvent())
	awaitAudit(t, func() bool { return s.PublicAccessAuditStatus().LastWriteAt != nil })
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				s.RecordPublicAccess(testAccessEvent())
			}
		}()
	}
	s.StopPublicAccessAudit()
	wg.Wait()
	select {
	case <-s.auditService().done:
	default:
		t.Fatal("worker survived close")
	}
}

func TestPublicAccessAuditInitializationFailureVisible(t *testing.T) {
	s, _ := fixture(t)
	s.db.Close()
	if err := s.InitPublicAccessAudit(); !errors.Is(err, ErrPublicAccessAuditUnavailable) {
		t.Fatal(err)
	}
	s.RecordPublicAccess(testAccessEvent())
	status := s.PublicAccessAuditStatus()
	if status.Enabled || status.LastError != "initialization_failed" || status.WriteFailures != 1 || status.Dropped != 1 {
		t.Fatal(status)
	}
	s.StopPublicAccessAudit()
	s.StopPublicAccessAudit()
}

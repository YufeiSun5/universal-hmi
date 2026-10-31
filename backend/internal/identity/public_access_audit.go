package identity

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

// PublicAccessEvent is the version-1 request audit contract. Owner fields are
// manually assigned historical labels, not proof of the authenticated UserID.
// No arbitrary URL, headers, query, request/response body or credentials are accepted.
type PublicAccessEvent struct {
	Seq         int64     `json:"seq"`
	At          time.Time `json:"at"`
	IP          string    `json:"ip"`
	Channel     string    `json:"channel"`
	UserID      string    `json:"user_id,omitempty"`
	Kind        string    `json:"kind"`
	Route       string    `json:"route"`
	Method      string    `json:"method"`
	Status      int       `json:"status"`
	Decision    string    `json:"decision"`
	RuleID      string    `json:"rule_id,omitempty"`
	OwnerLabel  string    `json:"owner_label,omitempty"`
	OwnerUserID string    `json:"owner_user_id,omitempty"`
}
type PublicAccessAuditStatus struct {
	Enabled       bool       `json:"enabled"`
	QueueDepth    int        `json:"queue_depth"`
	Dropped       uint64     `json:"dropped"`
	WriteFailures uint64     `json:"write_failures"`
	LastWriteAt   *time.Time `json:"last_write_at,omitempty"`
	LastError     string     `json:"last_error,omitempty"`
	RetentionDays int        `json:"retention_days"`
	MaxEvents     int        `json:"max_events"`
}
type PublicAccessSnapshot struct {
	Items      []PublicAccessEvent     `json:"items"`
	NextBefore int64                   `json:"next_before"`
	Status     PublicAccessAuditStatus `json:"status"`
}

var ErrPublicAccessAuditUnavailable = errors.New("public access audit unavailable")

type publicAccessAudit struct {
	mu             sync.Mutex
	queue          chan PublicAccessEvent
	done           chan struct{}
	cancel         context.CancelFunc
	stopped        bool
	status         PublicAccessAuditStatus
	now            func() time.Time
	maxEvents      int
	tick           time.Duration
	cleanupReserve int
}

func (s *Service) InitPublicAccessAudit() error {
	return s.initPublicAccessAudit(100000, time.Hour, time.Now)
}
func (s *Service) initPublicAccessAudit(max int, tick time.Duration, now func() time.Time) error {
	s.publicAuditMu.Lock()
	defer s.publicAuditMu.Unlock()
	if s.publicAudit != nil {
		s.publicAudit.mu.Lock()
		defer s.publicAudit.mu.Unlock()
		if s.publicAudit.status.Enabled {
			return nil
		}
		return ErrPublicAccessAuditUnavailable
	}
	ctx, cancel := context.WithCancel(context.Background())
	a := &publicAccessAudit{queue: make(chan PublicAccessEvent, 256), done: make(chan struct{}), cancel: cancel, now: now, maxEvents: max, tick: tick, status: PublicAccessAuditStatus{RetentionDays: 14, MaxEvents: 100000}}
	s.publicAudit = a
	if err := s.db.Schema([]string{"CREATE TABLE IF NOT EXISTS public_access_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT NOT NULL,ip TEXT NOT NULL,channel TEXT NOT NULL,user_id TEXT NOT NULL,kind TEXT NOT NULL,route TEXT NOT NULL,method TEXT NOT NULL,status INTEGER NOT NULL,decision TEXT NOT NULL,rule_id TEXT NOT NULL,owner_label TEXT NOT NULL,owner_user_id TEXT NOT NULL)", "CREATE INDEX IF NOT EXISTS public_access_events_at ON public_access_events(at)"}); err != nil {
		a.status.LastError = "initialization_failed"
		a.status.WriteFailures++
		a.stopped = true
		cancel()
		close(a.done)
		return ErrPublicAccessAuditUnavailable
	}
	a.status.Enabled = true
	go s.publicAuditWorker(ctx, a)
	return nil
}
func (s *Service) auditService() *publicAccessAudit {
	s.publicAuditMu.Lock()
	defer s.publicAuditMu.Unlock()
	return s.publicAudit
}
func (s *Service) PublicAccessAuditStatus() PublicAccessAuditStatus {
	a := s.auditService()
	if a == nil {
		return PublicAccessAuditStatus{RetentionDays: 14, MaxEvents: 100000}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	status := a.status
	status.QueueDepth = len(a.queue)
	if status.LastWriteAt != nil {
		v := *status.LastWriteAt
		status.LastWriteAt = &v
	}
	return status
}
func (s *Service) StopPublicAccessAudit() {
	a := s.auditService()
	if a == nil {
		return
	}
	a.mu.Lock()
	a.stopped = true
	a.status.Enabled = false
	a.cancel()
	a.mu.Unlock()
	<-a.done
}
func validPublicAccessEvent(e PublicAccessEvent) bool {
	ip, err := netip.ParseAddr(e.IP)
	if err != nil || ip.Zone() != "" {
		return false
	}
	if e.Channel != "public:web" || e.Status < 100 || e.Status > 599 {
		return false
	}
	switch e.Kind {
	case "api_request", "static_denied", "stream_end":
	default:
		return false
	}
	switch e.Method {
	case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "OTHER":
	default:
		return false
	}
	switch e.Decision {
	case "allowed", "public_ip_denied", "public_read_only", "public_path_denied", "authentication_required", "authentication_failed", "forbidden", "request_failed", "stream_closed", "stream_access_revoked":
	default:
		return false
	}
	for _, id := range []string{e.UserID, e.RuleID, e.OwnerUserID} {
		if id != "" && !publicIPIdentifier.MatchString(id) {
			return false
		}
	}
	if len(e.OwnerLabel) > 128 || strings.IndexFunc(e.OwnerLabel, unicode.IsControl) >= 0 {
		return false
	}
	switch e.Route {
	case "/other", "/static", "/api/*", "/health", "/api/v1/auth/session", "/api/v1/auth/login", "/api/v1/auth/logout",
		"/api/v1/security/mfa/begin", "/api/v1/security/mfa/confirm", "/api/v1/stations", "/api/v1/points", "/api/v1/runtime", "/api/v1/runtime/events",
		"/api/v1/screens", "/api/v1/screens/{id}", "/api/v1/navigation", "/api/v1/equipment", "/api/v1/equipment/{id}", "/api/v1/equipment/status",
		"/api/v1/equipment/{id}/photos/{photo}", "/api/v1/equipment-navigation", "/api/v1/external/screens", "/api/v1/external/screens/{id}/stations", "/api/v1/external/screens/{id}/query":
		return true
	}
	return false
}
func (s *Service) RecordPublicAccess(event PublicAccessEvent) {
	a := s.auditService()
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stopped || !a.status.Enabled || !validPublicAccessEvent(event) {
		a.status.Dropped++
		return
	}
	event.Seq = 0
	event.At = a.now().UTC()
	ip, _ := netip.ParseAddr(event.IP)
	event.IP = ip.Unmap().String()
	select {
	case a.queue <- event:
	default:
		a.status.Dropped++
	}
}
func (s *Service) publicAuditPrune(ctx context.Context, a *publicAccessAudit, reserve int) error {
	cutoff := a.now().UTC().Add(-14 * 24 * time.Hour).Format("2006-01-02T15:04:05.000000000Z")
	// Every cleanup performs at most ten 1000-row deletes. If backlog remains,
	// writes pause until later cleanup catches up; rows are never allowed to grow unbounded.
	for i := 0; i < 10; i++ {
		result, err := s.db.ExecContext(ctx, "DELETE FROM public_access_events WHERE seq IN (SELECT seq FROM public_access_events WHERE at<? ORDER BY seq LIMIT 1000)", cutoff)
		if err != nil {
			return err
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n < 1000 {
			break
		}
	}
	var expired, count int
	if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM public_access_events WHERE at<?", cutoff).Scan(&expired); err != nil {
		return err
	}
	if expired != 0 {
		return ErrPublicAccessAuditUnavailable
	}
	if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM public_access_events").Scan(&count); err != nil {
		return err
	}
	excess := count + reserve - a.maxEvents
	for i := 0; excess > 0 && i < 10; i++ {
		n := excess
		if n > 1000 {
			n = 1000
		}
		result, err := s.db.ExecContext(ctx, "DELETE FROM public_access_events WHERE seq IN (SELECT seq FROM public_access_events ORDER BY seq LIMIT ?)", n)
		if err != nil {
			return err
		}
		deleted, err := result.RowsAffected()
		if err != nil {
			return err
		}
		excess -= int(deleted)
	}
	if excess > 0 {
		return ErrPublicAccessAuditUnavailable
	}
	return nil
}
func (s *Service) publicAuditBatch(ctx context.Context, a *publicAccessAudit, batch []PublicAccessEvent) {
	a.mu.Lock()
	if a.stopped || ctx.Err() != nil {
		a.status.Dropped += uint64(len(batch))
		a.mu.Unlock()
		return
	}
	a.mu.Unlock()
	// Shutdown stops scheduling work but lets the current bounded batch finish.
	// Canceling an active SQL query/transaction can return before driver-owned
	// cleanup completes; worker completion must precede closing the database.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()
	reserve := len(batch)
	if a.cleanupReserve > reserve {
		reserve = a.cleanupReserve
	}
	err := s.publicAuditPrune(ctx, a, reserve)
	if err != nil {
		a.cleanupReserve = reserve
	} else {
		a.cleanupReserve = 0
	}
	reason := "cleanup_failed"
	if err == nil && len(batch) > 0 {
		reason = "write_failed"
		tx, e := s.db.BeginTx(ctx, nil)
		err = e
		if err == nil {
			defer tx.Rollback()
			for _, event := range batch {
				_, err = tx.ExecContext(ctx, "INSERT INTO public_access_events(at,ip,channel,user_id,kind,route,method,status,decision,rule_id,owner_label,owner_user_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", event.At.Format("2006-01-02T15:04:05.000000000Z"), event.IP, event.Channel, event.UserID, event.Kind, event.Route, event.Method, event.Status, event.Decision, event.RuleID, event.OwnerLabel, event.OwnerUserID)
				if err != nil {
					break
				}
			}
			if err == nil {
				err = tx.Commit()
			}
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if err != nil {
		a.status.WriteFailures++
		a.status.Dropped += uint64(len(batch))
		a.status.LastError = reason
		return
	}
	a.status.LastError = ""
	if len(batch) > 0 {
		now := a.now().UTC()
		a.status.LastWriteAt = &now
	}
}
func (s *Service) publicAuditWorker(ctx context.Context, a *publicAccessAudit) {
	defer close(a.done)
	defer func() {
		a.mu.Lock()
		defer a.mu.Unlock()
		a.status.Dropped += uint64(len(a.queue))
		for len(a.queue) > 0 {
			<-a.queue
		}
	}()
	ticker := time.NewTicker(a.tick)
	defer ticker.Stop()
	s.publicAuditBatch(ctx, a, nil)
	for {
		if ctx.Err() != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			s.publicAuditBatch(ctx, a, nil)
		case event := <-a.queue:
			batch := []PublicAccessEvent{event}
			for len(batch) < 32 {
				select {
				case next := <-a.queue:
					batch = append(batch, next)
				default:
					goto ready
				}
			}
		ready:
			if ctx.Err() != nil {
				a.mu.Lock()
				a.status.Dropped += uint64(len(batch))
				a.mu.Unlock()
				return
			}
			s.publicAuditBatch(ctx, a, batch)
		}
	}
}
func (s *Service) PublicAccessEvents(actor authorization.Actor, before int64, limit int) (PublicAccessSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return PublicAccessSnapshot{}, ErrDenied
	}
	status := s.PublicAccessAuditStatus()
	if !status.Enabled {
		return PublicAccessSnapshot{Status: status}, ErrPublicAccessAuditUnavailable
	}
	if before < 0 || limit < 1 || limit > 200 {
		return PublicAccessSnapshot{}, errors.New("invalid audit pagination")
	}
	a := s.auditService()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	rows, err := s.db.QueryContext(ctx, "SELECT seq,at,ip,channel,user_id,kind,route,method,status,decision,rule_id,owner_label,owner_user_id FROM public_access_events WHERE at>=? AND (?=0 OR seq<?) ORDER BY seq DESC LIMIT ?", a.now().UTC().Add(-14*24*time.Hour).Format("2006-01-02T15:04:05.000000000Z"), before, before, limit+1)
	if err != nil {
		return PublicAccessSnapshot{Status: status}, ErrPublicAccessAuditUnavailable
	}
	defer rows.Close()
	result := PublicAccessSnapshot{Items: []PublicAccessEvent{}, Status: status}
	for rows.Next() {
		var e PublicAccessEvent
		var at string
		if rows.Scan(&e.Seq, &at, &e.IP, &e.Channel, &e.UserID, &e.Kind, &e.Route, &e.Method, &e.Status, &e.Decision, &e.RuleID, &e.OwnerLabel, &e.OwnerUserID) != nil {
			return PublicAccessSnapshot{}, ErrPublicAccessAuditUnavailable
		}
		e.At, err = time.Parse(time.RFC3339Nano, at)
		if err != nil {
			return PublicAccessSnapshot{}, ErrPublicAccessAuditUnavailable
		}
		result.Items = append(result.Items, e)
	}
	if rows.Err() != nil {
		return PublicAccessSnapshot{}, ErrPublicAccessAuditUnavailable
	}
	if len(result.Items) > limit {
		result.Items = result.Items[:limit]
		result.NextBefore = result.Items[limit-1].Seq
	}
	return result, nil
}

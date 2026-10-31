package runtime

import (
	"context"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"sync/atomic"
	"testing"
	"time"
)

func TestIdentityControlAndQueuedRevocation(t *testing.T) {
	e, ps := setup(t)
	p := point(t, ps, "controlled", true)
	version, err := e.Apply()
	if err != nil {
		t.Fatal(err)
	}
	e.RequireIdentity()
	w := Write{CommandID: "identity-write-01", PointID: p.ID, Value: 50, Version: version}
	if _, err = e.Write(w); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("anonymous write", err)
	}
	var current atomic.Bool
	current.Store(true)
	a := authorization.Actor{ID: "operator", Version: 1, Grants: authorization.Grants{Roles: []string{"operator"}, AllStations: true}, Valid: current.Load, IdentityValid: current.Load}
	w.Actor = &a
	a.StationID = func(name string) string { return name }
	if _, err = e.Write(w); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("role implied control", err)
	}
	a.Grants.Control = true
	r, err := e.Write(w)
	if err != nil || r.State != "readback_confirmed" || r.UserID != a.ID || r.PolicyVersion != 1 {
		t.Fatal(r, err)
	}
	// Simulate a previously accepted queue entry. No connection exists: invoking
	// publication would panic. Revocation must persist not_sent before that point.
	w.CommandID = "identity-queued-02"
	e.mu.Lock()
	e.pending[w.CommandID] = &pendingWrite{Result: Result{CommandID: w.CommandID, PointID: p.ID, State: "accepted", PublishState: "queued"}}
	e.mu.Unlock()
	current.Store(false)
	e.executeWrite(writeTask{Request: w, Target: p})
	e.mu.Lock()
	r, err = e.commandLocked(w.CommandID)
	e.mu.Unlock()
	if err != nil || r.PublishState != "not_sent" || r.Message != "authorization revoked before publication" {
		t.Fatal(r, err)
	}
}

func TestIdentityRuleOwnershipOutlivesSessionButNotPermission(t *testing.T) {
	e, ps := setup(t)
	stopRuntimeClock(t, e)
	input := point(t, ps, "input", false)
	output := point(t, ps, "output", true)
	if _, err := e.Apply(); err != nil {
		t.Fatal(err)
	}
	e.RequireIdentity()
	var permission, session atomic.Bool
	permission.Store(true)
	session.Store(true)
	a := authorization.Actor{ID: "engineer", Version: 3, Grants: authorization.Grants{Roles: []string{"engineer"}, AllStations: true}, Valid: session.Load, IdentityValid: permission.Load}
	rule := Rule{ID: "identity-rule", Name: "controlled rule", Enabled: true, Logic: "and", Conditions: []Condition{{input.ID, ">", 30}}, CooldownMS: 1000, Trigger: "periodic", Actions: []Action{{"write", output.ID, 50}}}
	a.StationID = func(name string) string { return name }
	ctx := authorization.WithActor(context.Background(), a)
	if err := e.SetRules([]Rule{rule}, ctx); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("engineer implicitly controls", err)
	}
	a.Grants.Control = true
	ctx = authorization.WithActor(context.Background(), a)
	if err := e.SetRules([]Rule{rule}, ctx); err != nil {
		t.Fatal(err)
	}
	session.Store(false)
	now := time.Now()
	e.mu.Lock()
	e.ingest(input, 20.0, "good", now, now)
	e.evaluate(now)
	got := e.live[output.ID].Value
	e.mu.Unlock()
	if got != 50.0 {
		t.Fatal("logout stopped authorized background rule", got)
	}
	permission.Store(false)
	e.mu.Lock()
	// The preceding manual write uses its own current timestamp. Reusing the
	// earlier rule evaluation time can be rejected as an out-of-order sample,
	// leaving the prior 50 and falsely reporting a post-revocation execution.
	resetAt := e.live[output.ID].SourceTime.Add(time.Millisecond)
	if !e.ingest(output, 10.0, "good", resetAt, resetAt) {
		e.mu.Unlock()
		t.Fatal("fresh reset sample rejected")
	}
	if e.live[output.ID].Value != 30.0 {
		e.mu.Unlock()
		t.Fatal("reset sample did not establish expected baseline")
	}
	e.evaluate(resetAt.Add(2 * time.Second))
	got = e.live[output.ID].Value
	e.mu.Unlock()
	if got != 30.0 {
		t.Fatal("revoked rule executed", got)
	}
}

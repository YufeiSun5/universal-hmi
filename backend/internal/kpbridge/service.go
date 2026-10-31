// Package kpbridge owns KP-linked sessions independently of HTTP and the UI.
package kpbridge

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"
	"sync"
	"time"
)

type Error struct {
	Code   string
	Status int
}

func (e *Error) Error() string              { return e.Code }
func failure(code string, status int) error { return &Error{code, status} }

// Proof is opaque to the bridge. A verifier must validate the actual KP login,
// its audience, expiry and binding to this source/context/login version.
type Bootstrap struct {
	ContextID     string `json:"contextId"`
	LoginVersion  string `json:"loginVersion"`
	UserName      string `json:"userName"`
	KPHost        string `json:"kpHost"`
	IdentityProof string `json:"identityProof"`
}
type Identity struct {
	Subject, UserName string
	MFA               bool
	AuthenticatedAt   time.Time
}
type Verifier interface {
	Verify(context.Context, string, Bootstrap) (Identity, error)
}
type VerifyFunc func(context.Context, string, Bootstrap) (Identity, error)

func (f VerifyFunc) Verify(c context.Context, source string, b Bootstrap) (Identity, error) {
	return f(c, source, b)
}

// Grants are explicitly provisioned. Current deployment has one shared
// workspace; a grant authorizes that entire workspace, never an implied station
// subset. Fine-grained station grants must be enforced by business services.
type Grant struct {
	Subject     string `json:"subject"`
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	Role        string `json:"role"`
}
type User struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Role        string `json:"role"`
	WorkspaceID string `json:"workspace_id"`
}

func (u User) CanWrite() bool { return u.Role == "operator" }

type Options struct {
	SourceID, WorkspaceID                      string
	Grants                                     []Grant
	Verifier                                   Verifier
	Lease, TicketTTL, AbsoluteTTL, TerminalTTL time.Duration
	Capacity                                   int
	Now                                        func() time.Time
}
type Channel struct {
	ContextID    string `json:"contextId"`
	LoginVersion string `json:"loginVersion"`
	BridgeToken  string `json:"bridgeToken"`
}
type LogoffResult struct {
	Channel
	Success *bool `json:"success"`
}
type View struct {
	MFA              bool      `json:"mfa_verified"`
	AuthenticatedAt  time.Time `json:"authenticated_at"`
	ContextID        string    `json:"contextId"`
	LoginVersion     string    `json:"loginVersion"`
	State            string    `json:"state"`
	User             User      `json:"user"`
	SourceID         string    `json:"sourceId"`
	KPHost           string    `json:"kpHost"`
	KPObservedIP     string    `json:"kpObservedIp"`
	WebObservedIP    string    `json:"webObservedIp"`
	ExpiresAt        time.Time `json:"expires_at"`
	LastLogoffResult *bool     `json:"lastLogoffResult"`
}
type BootstrapReply struct {
	Channel
	Ticket          string    `json:"ticket"`
	TicketExpiresAt time.Time `json:"ticketExpiresAt"`
	PollIntervalMS  int       `json:"pollIntervalMs"`
}
type WebReply struct {
	View
	Enabled       bool   `json:"enabled"`
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
	CanWrite      bool   `json:"can_write"`
	WebToken      string `json:"webToken,omitempty"`
}
type PollReply struct {
	ContextID    string `json:"contextId"`
	LoginVersion string `json:"loginVersion"`
	Command      string `json:"command"`
	State        string `json:"state"`
}
type sessionKey struct{ context, version string }
type session struct {
	view                                       View
	subject                                    string
	bridge, ticket                             string
	webHash                                    [32]byte
	consumed                                   bool
	logoutRequested                            bool
	ticketUntil, heartbeat, absolute, terminal time.Time
}
type Service struct {
	mu       sync.Mutex
	o        Options
	grants   map[string]Grant
	sessions map[sessionKey]*session
	web      map[[32]byte]*session
}

func validText(v string, max int) bool {
	return v != "" && len(v) <= max && strings.TrimSpace(v) == v && !strings.ContainsAny(v, "\r\n\x00")
}
func New(o Options) (*Service, error) {
	if !validText(o.SourceID, 128) || !validText(o.WorkspaceID, 128) {
		return nil, fmt.Errorf("source_id and workspace_id are required")
	}
	if o.Lease == 0 {
		o.Lease = 30 * time.Second
	}
	if o.TicketTTL == 0 {
		o.TicketTTL = 30 * time.Second
	}
	if o.AbsoluteTTL == 0 {
		o.AbsoluteTTL = 8 * time.Hour
	}
	if o.TerminalTTL == 0 {
		o.TerminalTTL = 2 * time.Minute
	}
	if o.Capacity == 0 {
		o.Capacity = 256
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Lease < 15*time.Second || o.Lease > 10*time.Minute || o.TicketTTL < 5*time.Second || o.TicketTTL > time.Minute || o.AbsoluteTTL < time.Minute || o.AbsoluteTTL > 24*time.Hour || o.TerminalTTL < time.Second || o.TerminalTTL > 10*time.Minute || o.Capacity < 1 || o.Capacity > 1024 {
		return nil, fmt.Errorf("invalid bridge lifetime or capacity")
	}
	s := &Service{o: o, grants: make(map[string]Grant), sessions: make(map[sessionKey]*session), web: make(map[[32]byte]*session)}
	for _, g := range o.Grants {
		if !validText(g.Subject, 200) || !validText(g.UserID, 128) || !validText(g.DisplayName, 200) || (g.Role != "viewer" && g.Role != "operator") {
			return nil, fmt.Errorf("invalid user grant")
		}
		if _, ok := s.grants[g.Subject]; ok {
			return nil, fmt.Errorf("duplicate subject grant")
		}
		s.grants[g.Subject] = g
	}
	return s, nil
}
func token() (string, error) {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}
func equal(a, b string) bool {
	x, y := sha256.Sum256([]byte(a)), sha256.Sum256([]byte(b))
	return subtle.ConstantTimeCompare(x[:], y[:]) == 1
}
func (s *Service) transition(v *session, state string, now time.Time) {
	v.view.State = state
	v.terminal = now
}
func (s *Service) update(v *session, now time.Time) {
	expiry := v.heartbeat.Add(s.o.Lease)
	if v.absolute.Before(expiry) {
		expiry = v.absolute
	}
	if v.view.State != "closed" && v.view.State != "expired" && !now.Before(expiry) {
		s.transition(v, "expired", expiry)
	}
	v.view.ExpiresAt = v.absolute
}
func (s *Service) cleanup(now time.Time) {
	for k, v := range s.sessions {
		s.update(v, now)
		if !v.terminal.IsZero() && !now.Before(v.terminal.Add(s.o.TerminalTTL)) {
			delete(s.web, v.webHash)
			delete(s.sessions, k)
		}
	}
}
func (s *Service) Bootstrap(ctx context.Context, b Bootstrap, ip string) (BootstrapReply, error) {
	if !validText(b.ContextID, 200) || !validText(b.LoginVersion, 200) || !validText(b.UserName, 200) || len(b.KPHost) > 300 || len(b.IdentityProof) > 16*1024 {
		return BootstrapReply{}, failure("invalid_request", 400)
	}
	if s.o.Verifier == nil {
		return BootstrapReply{}, failure("identity_verifier_unconfigured", 503)
	}
	identity, err := s.o.Verifier.Verify(ctx, s.o.SourceID, b)
	if err != nil {
		return BootstrapReply{}, err
	}
	if !validText(identity.Subject, 200) || identity.UserName != b.UserName {
		return BootstrapReply{}, failure("identity_mismatch", 403)
	}
	g, ok := s.grants[identity.Subject]
	if !ok {
		return BootstrapReply{}, failure("user_not_provisioned", 403)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.o.Now()
	s.cleanup(now)
	key := sessionKey{b.ContextID, b.LoginVersion}
	v := s.sessions[key]
	if v != nil {
		if v.subject != identity.Subject {
			return BootstrapReply{}, failure("identity_conflict", 409)
		}
		if v.view.State != "created" {
			return BootstrapReply{}, failure("login_already_started", 409)
		}
	} else {
		if len(s.sessions) >= s.o.Capacity {
			return BootstrapReply{}, failure("bridge_capacity_reached", 503)
		}
		secret, e := token()
		if e != nil {
			return BootstrapReply{}, failure("token_creation_failed", 500)
		}
		v = &session{subject: identity.Subject, bridge: secret, heartbeat: now, absolute: now.Add(s.o.AbsoluteTTL), view: View{MFA: identity.MFA, AuthenticatedAt: identity.AuthenticatedAt, ContextID: b.ContextID, LoginVersion: b.LoginVersion, State: "created", User: User{g.UserID, g.DisplayName, g.Role, s.o.WorkspaceID}, SourceID: s.o.SourceID, KPHost: b.KPHost, KPObservedIP: ip}}
		s.sessions[key] = v
	}
	if v.ticket == "" || !now.Before(v.ticketUntil) {
		var e error
		v.ticket, e = token()
		if e != nil {
			return BootstrapReply{}, failure("token_creation_failed", 500)
		}
		v.ticketUntil = now.Add(s.o.TicketTTL)
	}
	return BootstrapReply{Channel{b.ContextID, b.LoginVersion, v.bridge}, v.ticket, v.ticketUntil, 2000}, nil
}
func (s *Service) reply(v *session, includeToken string) WebReply {
	return WebReply{v.view, true, v.view.State == "active", v.view.User.Name, v.view.State == "active" && v.view.User.CanWrite(), includeToken}
}
func (s *Service) Redeem(ticket, ip string) (WebReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.o.Now()
	s.cleanup(now)
	if len(ticket) != 43 {
		return WebReply{}, failure("invalid_ticket", 403)
	}
	for _, v := range s.sessions {
		if !equal(v.ticket, ticket) {
			continue
		}
		if v.consumed || v.view.State != "created" || !now.Before(v.ticketUntil) {
			return WebReply{}, failure("ticket_used_or_expired", 403)
		}
		secret, e := token()
		if e != nil {
			return WebReply{}, failure("token_creation_failed", 500)
		}
		v.consumed = true
		v.webHash = sha256.Sum256([]byte(secret))
		v.view.WebObservedIP = ip
		v.view.State = "active"
		s.web[v.webHash] = v
		s.update(v, now)
		return s.reply(v, secret), nil
	}
	return WebReply{}, failure("invalid_ticket", 403)
}
func (s *Service) webSession(secret string) (*session, error) {
	if len(secret) != 43 {
		return nil, failure("invalid_web_token", 401)
	}
	s.cleanup(s.o.Now())
	v := s.web[sha256.Sum256([]byte(secret))]
	if v == nil {
		return nil, failure("invalid_web_token", 401)
	}
	return v, nil
}
func (s *Service) Me(secret string) (WebReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.webSession(secret)
	if e != nil {
		return WebReply{}, e
	}
	if v.view.State != "active" {
		return WebReply{}, failure("business_session_revoked", 401)
	}
	return s.reply(v, ""), nil
}
func (s *Service) Status(secret string) (WebReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.webSession(secret)
	if e != nil {
		return WebReply{}, e
	}
	return s.reply(v, ""), nil
}
func (s *Service) Logout(secret string) (WebReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.webSession(secret)
	if e != nil {
		return WebReply{}, e
	}
	if v.view.State != "closed" {
		v.logoutRequested = true
	}
	if v.view.State == "active" {
		v.view.State = "logout_requested"
	}
	return s.reply(v, ""), nil
}
func (s *Service) kpSession(c Channel) (*session, error) {
	s.cleanup(s.o.Now())
	v := s.sessions[sessionKey{c.ContextID, c.LoginVersion}]
	if v == nil || len(c.BridgeToken) != 43 || !equal(v.bridge, c.BridgeToken) {
		return nil, failure("invalid_bridge_token", 401)
	}
	return v, nil
}
func (s *Service) Poll(c Channel) (PollReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.kpSession(c)
	if e != nil {
		return PollReply{}, e
	}
	command := "none"
	switch v.view.State {
	case "closed":
		command = "closed"
	case "expired":
		command = "rebootstrap"
		if v.logoutRequested {
			command = "logout"
		}
	case "logout_requested":
		command = "logout"
	}
	if v.view.State != "expired" && v.view.State != "closed" {
		v.heartbeat = s.o.Now()
	}
	return PollReply{c.ContextID, c.LoginVersion, command, v.view.State}, nil
}
func (s *Service) LogoffResult(r LogoffResult) (View, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.kpSession(r.Channel)
	if e != nil {
		return View{}, e
	}
	if r.Success == nil {
		return View{}, failure("success_required", 400)
	}
	if v.view.State == "closed" || (v.view.State == "expired" && !v.logoutRequested) {
		return v.view, nil
	}
	if !v.logoutRequested {
		return View{}, failure("unexpected_logoff_result", 409)
	}
	result := *r.Success
	v.view.LastLogoffResult = &result
	if result {
		s.transition(v, "closed", s.o.Now())
	}
	return v.view, nil
}
func (s *Service) Close(c Channel) (View, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, e := s.kpSession(c)
	if e != nil {
		return View{}, e
	}
	if v.view.State != "closed" && v.view.State != "expired" {
		s.transition(v, "closed", s.o.Now())
	}
	return v.view, nil
}

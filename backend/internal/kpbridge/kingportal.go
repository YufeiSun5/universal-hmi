package kpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// KingPortalVerifier calls a configured KP server, never a browser-supplied
// host. Business errors also use HTTP 200, so status alone proves nothing.
type KingPortalVerifier struct {
	endpoint, project string
	client            *http.Client
	slots             chan struct{}
}

func NewKingPortalVerifier(origin, project string, transport http.RoundTripper) (*KingPortalVerifier, error) {
	u, e := url.Parse(origin)
	if e != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return nil, failure("invalid_kp_server", 400)
	}
	// The administrator may explicitly select a private IP for an on-site KP
	// server that only exposes HTTP. Do not resolve hostnames to expand this
	// exception: public names and public IPs still require HTTPS.
	localHTTP := u.Hostname() == "localhost"
	if ip := net.ParseIP(u.Hostname()); ip != nil {
		localHTTP = ip.IsLoopback() || ip.IsPrivate()
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && localHTTP) {
		return nil, failure("invalid_kp_server", 400)
	}
	if len(project) > 200 || strings.ContainsAny(project, "\r\n\x00") {
		return nil, failure("invalid_kp_project", 400)
	}
	u.Path = "/api/v1/getUserInfo"
	if project != "" {
		q := u.Query()
		q.Set("projectName", project)
		u.RawQuery = q.Encode()
	}
	return &KingPortalVerifier{u.String(), project, &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, make(chan struct{}, 8)}, nil
}

func (v *KingPortalVerifier) Verify(ctx context.Context, _ string, b Bootstrap) (Identity, error) {
	if b.IdentityProof == "" || len(b.IdentityProof) > 16*1024 || strings.ContainsAny(b.IdentityProof, "\r\n\x00") {
		return Identity{}, failure("identity_proof_required", 401)
	}
	select {
	case v.slots <- struct{}{}:
		defer func() { <-v.slots }()
	default:
		return Identity{}, failure("identity_verifier_busy", 503)
	}
	r, e := http.NewRequestWithContext(ctx, http.MethodGet, v.endpoint, nil)
	if e != nil {
		return Identity{}, failure("identity_verifier_unavailable", 503)
	}
	nonce, e := token()
	if e != nil {
		return Identity{}, failure("identity_verifier_unavailable", 503)
	}
	r.Header.Set("Authorization", "Bearer "+b.IdentityProof)
	r.Header.Set("projectname", url.PathEscape(v.project))
	r.Header.Set("requesttime", strconv.FormatInt(time.Now().UnixMilli(), 10))
	r.Header.Set("onces", nonce)
	response, e := v.client.Do(r)
	if e != nil {
		return Identity{}, failure("identity_verifier_unavailable", 503)
	}
	defer response.Body.Close()
	if response.StatusCode == 401 || response.StatusCode == 403 {
		return Identity{}, failure("identity_not_verified", 401)
	}
	if response.StatusCode != 200 {
		return Identity{}, failure("identity_verifier_unavailable", 503)
	}
	data, e := io.ReadAll(io.LimitReader(response.Body, 32*1024+1))
	if e != nil || len(data) > 32*1024 {
		return Identity{}, failure("identity_verifier_bad_response", 503)
	}
	var result struct {
		UserID   json.RawMessage `json:"userId"`
		UserName string          `json:"userName"`
		Username string          `json:"username"`
		Code     json.RawMessage `json:"code"`
		Error    json.RawMessage `json:"error"`
	}
	d := json.NewDecoder(bytes.NewReader(data))
	if d.Decode(&result) != nil || d.Decode(new(any)) != io.EOF {
		return Identity{}, failure("identity_verifier_bad_response", 503)
	}
	// The verified KP success response is a top-level userId/userName object.
	// Unknown response envelopes fail closed until that KP version is verified.
	if len(result.Code) > 0 || len(result.Error) > 0 {
		return Identity{}, failure("identity_not_verified", 401)
	}
	var subject string
	if json.Unmarshal(result.UserID, &subject) != nil {
		var n json.Number
		if json.Unmarshal(result.UserID, &n) != nil {
			return Identity{}, failure("identity_not_verified", 401)
		}
		i, e := strconv.ParseInt(string(n), 10, 64)
		if e != nil || i <= 0 {
			return Identity{}, failure("identity_not_verified", 401)
		}
		subject = strconv.FormatInt(i, 10)
	}
	name := result.UserName
	if name == "" {
		name = result.Username
	}
	if !validText(subject, 200) || !validText(name, 200) {
		return Identity{}, failure("identity_not_verified", 401)
	}
	return Identity{Subject: subject, UserName: name}, nil
}

func (s *Service) NativeTokenMode() bool { _, ok := s.o.Verifier.(*KingPortalVerifier); return ok }

// PollVerified renews a managed lease only with its configured verifier:
// upstream KP identity or an administrator-issued fixed-account trial grant.
// Proofs are request-scoped, never persisted in linked sessions.
func (s *Service) PollVerified(ctx context.Context, c Channel, proof string) (PollReply, error) {
	if !s.ManagedReadOnlyMode() {
		return s.Poll(c)
	}
	s.mu.Lock()
	v, e := s.kpSession(c)
	if e != nil {
		s.mu.Unlock()
		return PollReply{}, e
	}
	if v.view.State != "active" && v.view.State != "created" {
		s.mu.Unlock()
		return s.poll(c)
	}
	subject, name := v.subject, v.verifiedName
	s.mu.Unlock()
	id, e := s.o.Verifier.Verify(ctx, s.o.SourceID, Bootstrap{ContextID: c.ContextID, LoginVersion: c.LoginVersion, UserName: name, IdentityProof: proof})
	if e != nil || id.Subject != subject || id.UserName != name {
		// Outages do not renew leases; invalid or switched identity closes at once.
		if e == nil || isIdentityRejection(e) {
			_, _ = s.Close(c)
		}
		if e != nil {
			return PollReply{}, e
		}
		return PollReply{}, failure("identity_mismatch", 403)
	}
	return s.poll(c)
}
func isIdentityRejection(e error) bool {
	v, ok := e.(*Error)
	return ok && (v.Status == 401 || v.Status == 403)
}

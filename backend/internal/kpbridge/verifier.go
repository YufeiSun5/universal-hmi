package kpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"time"
)

// HTTPVerifier is the adapter contract for a trusted KP integration service.
// This URL is provisioned by the operator, never selected by a bootstrap caller.
// No KP-specific session/token format is assumed.
type HTTPVerifier struct {
	endpoint string
	client   *http.Client
	slots    chan struct{}
}

func NewHTTPVerifier(endpoint string, transport http.RoundTripper) (*HTTPVerifier, error) {
	u, e := url.Parse(endpoint)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return nil, failure("invalid_verifier_url", 400)
	}
	return &HTTPVerifier{endpoint, &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, make(chan struct{}, 8)}, nil
}
func (v *HTTPVerifier) Verify(ctx context.Context, source string, b Bootstrap) (Identity, error) {
	if b.IdentityProof == "" {
		return Identity{}, failure("identity_proof_required", 401)
	}
	select {
	case v.slots <- struct{}{}:
		defer func() { <-v.slots }()
	default:
		return Identity{}, failure("identity_verifier_busy", 503)
	}
	payload, _ := json.Marshal(struct {
		SourceID string `json:"sourceId"`
		Bootstrap
	}{source, b})
	r, e := http.NewRequestWithContext(ctx, http.MethodPost, v.endpoint, bytes.NewReader(payload))
	if e != nil {
		return Identity{}, failure("identity_verifier_unavailable", 503)
	}
	r.Header.Set("Content-Type", "application/json")
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
	var result struct {
		MFA             bool      `json:"mfa_verified"`
		AuthenticatedAt time.Time `json:"authenticated_at"`
		Verified        bool      `json:"verified"`
		SourceID        string    `json:"sourceId"`
		ContextID       string    `json:"contextId"`
		LoginVersion    string    `json:"loginVersion"`
		Subject         string    `json:"subject"`
		UserName        string    `json:"userName"`
	}
	data, e := io.ReadAll(io.LimitReader(response.Body, 32*1024+1))
	if e != nil || len(data) > 32*1024 {
		return Identity{}, failure("identity_verifier_bad_response", 503)
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(&result) != nil || d.Decode(new(any)) != io.EOF {
		return Identity{}, failure("identity_verifier_bad_response", 503)
	}
	if !result.Verified || result.SourceID != source || result.ContextID != b.ContextID || result.LoginVersion != b.LoginVersion {
		return Identity{}, failure("identity_not_verified", 401)
	}
	return Identity{Subject: result.Subject, UserName: result.UserName, MFA: result.MFA, AuthenticatedAt: result.AuthenticatedAt}, nil
}

package identity

import (
	"crypto/sha256"
	"crypto/x509"
	"time"
)

// LinkKPToken is only used by the native, server-verified KP bridge on a
// public read-only listener. It does not assert MFA or a KP authentication time.
// Existing enabled MFA still requires the ordinary login path.
func (s *Service) LinkKPToken(userID, token string, leaf *x509.Certificate, valid func() bool) error {
	return s.linkPublicBridgeToken(userID, token, leaf, valid, "login.kp_token")
}

// LinkKPTrial records an explicit administrator-issued test authorization.
// It never claims KP identity or MFA verification and retains account/device checks.
func (s *Service) LinkKPTrial(userID, token string, leaf *x509.Certificate, valid func() bool) error {
	return s.linkPublicBridgeToken(userID, token, leaf, valid, "login.kp_trial")
}

// KPTokenValid accepts only a live public session linked by the KP bridge.
// Ordinary password sessions and local federated sessions cannot use KP admission.
// resolveBound also checks account changes, expiry, device binding and the bridge lease.
func (s *Service) KPTokenValid(token string, leaf *x509.Certificate) bool {
	var session Session
	var err error
	if leaf != nil {
		_, session, err = s.ResolveDevice(token, false, leaf)
	} else {
		_, session, err = s.ResolveChannel(token, false, "public:web")
	}
	return err == nil && session.Bearer && session.LinkedValid != nil
}

func (s *Service) linkPublicBridgeToken(userID, token string, leaf *x509.Certificate, valid func() bool, auditAction string) error {
	if len(token) < 32 || valid == nil || !valid() {
		return ErrLogin
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	u, err := s.User(userID)
	if err != nil || u.Disabled {
		return ErrLogin
	}
	if _, err = s.verifyMFALocked(u.ID, ""); err != nil {
		return ErrLogin
	}
	key := sha256.Sum256([]byte(token))
	if _, exists := s.sessions[key]; exists {
		return ErrLogin
	}
	now := s.now()
	for k, v := range s.sessions {
		if v.timedOut(now) || (v.LinkedValid != nil && !v.LinkedValid()) {
			delete(s.sessions, k)
		}
	}
	if len(s.sessions) >= 256 {
		return ErrLoginBusy
	}
	sess := Session{Channel: "public:web", LinkedValid: valid, ID: randomID(), UserID: u.ID, Version: u.Version, Bearer: true, Started: now, Last: now}
	if leaf != nil {
		device, e := s.verifyDeviceCertificateLocked(leaf)
		if e != nil {
			return ErrDeviceCertificateInvalid
		}
		sess.deviceLeaf, err = x509.ParseCertificate(append([]byte(nil), leaf.Raw...))
		if err != nil {
			return ErrLogin
		}
		sess.Channel, sess.deviceApproval = "public:device", device.ApprovalID
	}
	if err := s.Record(u.ID, auditAction, sess.ID, "authenticated"); err != nil {
		return err
	}
	s.sessions[key] = sess
	return nil
}

// LinkFederated is called once after a trusted bridge consumes its single-use
// ticket. The immutable user ID is provisioned by the operator, never a name
// supplied by the browser. Bridge and identity revocation both remain binding.
func (s *Service) LinkFederated(userID, token string, mfa bool, started time.Time, valid func() bool) error {
	if !mfa || len(token) < 32 || valid == nil || !valid() {
		return ErrLogin
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if started.After(now.Add(time.Minute)) || now.Sub(started) > 15*time.Minute {
		return ErrLogin
	}
	u, err := s.User(userID)
	if err != nil || u.Disabled {
		return ErrLogin
	}
	key := sha256.Sum256([]byte(token))
	if _, exists := s.sessions[key]; exists {
		return ErrLogin
	}
	for k, v := range s.sessions {
		if v.timedOut(now) {
			delete(s.sessions, k)
		}
	}
	if len(s.sessions) >= 256 {
		return ErrLogin
	}
	sess := Session{LinkedValid: valid, MFA: true, ID: randomID(), UserID: u.ID, Version: u.Version, Bearer: true, Started: started, Last: now, Expires: started.Add(8 * time.Hour)}
	if err := s.Record(u.ID, "login.federated", sess.ID, "authenticated"); err != nil {
		return err
	}
	s.sessions[key] = sess
	return nil
}

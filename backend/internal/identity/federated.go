package identity

import (
	"crypto/sha256"
	"time"
)

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
		if now.After(v.Expires) || now.Sub(v.Last) > 30*time.Minute {
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

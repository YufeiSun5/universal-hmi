package identity

import "github.com/YufeiSun5/universal-hmi/backend/internal/authorization"

// ChangePassword revokes every session, including the current session.
func (s *Service) ChangePassword(a authorization.Actor, current, next string) error {
	if !a.Active() || !s.allowAttempt("password:"+a.ID) {
		return ErrDenied
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return ErrDenied
	}
	_, hash, err := scanUser(s.db.QueryRow("SELECT * FROM users WHERE id=?", a.ID))
	if err != nil || !passwordMatches(hash, current) {
		return ErrLogin
	}
	newHash, err := s.passwordHash(next)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.Current(a.ID, a.Version) {
		return ErrDenied
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("UPDATE users SET password=?,version=version+1 WHERE id=?", newHash, a.ID); err != nil {
		return err
	}
	if err = auditTx(tx, a.ID, "password.change", a.ID, "changed; sessions revoked"); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	for k, v := range s.sessions {
		if v.UserID == a.ID {
			delete(s.sessions, k)
		}
	}
	return nil
}

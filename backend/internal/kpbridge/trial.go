package kpbridge

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
)

// Trial identity comes from an administrator-issued capability, not KP.
// A single server-side grant determines the user; browser names cannot choose it.
const TrialSubject = "administrator-selected-test-account"
const TrialUsername = "KP联调"

type TrialVerifier struct{ proof [32]byte }

func NewTrialVerifier(proof string) (*TrialVerifier, error) {
	if len(proof) != 43 {
		return nil, fmt.Errorf("invalid trial capability")
	}
	return &TrialVerifier{proof: sha256.Sum256([]byte(proof))}, nil
}

func (v *TrialVerifier) Verify(_ context.Context, _ string, b Bootstrap) (Identity, error) {
	proof := sha256.Sum256([]byte(b.IdentityProof))
	if len(b.IdentityProof) != 43 || subtle.ConstantTimeCompare(proof[:], v.proof[:]) != 1 {
		return Identity{}, failure("identity_not_verified", 401)
	}
	if b.UserName != TrialUsername {
		return Identity{}, failure("identity_mismatch", 403)
	}
	return Identity{Subject: TrialSubject, UserName: TrialUsername}, nil
}

func (s *Service) TrialMode() bool           { _, ok := s.o.Verifier.(*TrialVerifier); return ok }
func (s *Service) ManagedReadOnlyMode() bool { return s.NativeTokenMode() || s.TrialMode() }

package identity

import (
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

var ErrDeviceApprovalPending = errors.New("device approval pending")

// VerifyDeviceBootstrap admits only the sign-in surface, never project data.
// The caller must already have verified possession of this exact key with TLS.
// A revoked, disabled, expired or different previously registered leaf cannot
// become a new installation simply by submitting another certificate.
func (s *Service) VerifyDeviceBootstrap(leaf *x509.Certificate) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.verifyDeviceBootstrapLocked(leaf)
}

func (s *Service) verifyDeviceBootstrapLocked(leaf *x509.Certificate) error {
	if leaf == nil {
		return ErrDeviceCertificateInvalid
	}
	_, _, spki, err := certificateLeaf(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})))
	if err != nil || s.now().Before(leaf.NotBefore) || !s.now().Before(leaf.NotAfter) || leaf.CheckSignature(leaf.SignatureAlgorithm, leaf.RawTBSCertificate, leaf.Signature) != nil {
		return ErrDeviceCertificateInvalid
	}
	doc, _, err := s.loadDeviceRegistrations()
	if err != nil {
		return err
	}
	for _, item := range doc.Items {
		if item.SPKISHA256 == spki {
			if item.State != "pending" || item.LoginLeafPEM == "" {
				return ErrDeviceCertificateInvalid
			}
			stored, _, _, e := certificateLeaf(item.LoginLeafPEM)
			if e != nil || !constantCertificate(stored, leaf) {
				return ErrDeviceCertificateInvalid
			}
		}
	}
	return nil
}

// Called only after password/MFA verification, under the identity mutation lock.
func (s *Service) requestLoginDeviceLocked(user User, leaf *x509.Certificate) error {
	if err := s.verifyDeviceBootstrapLocked(leaf); err != nil {
		return ErrLogin
	}
	key, spki, err := registrationPublicKey(leaf.PublicKey)
	if err != nil {
		return ErrLogin
	}
	doc, previous, err := s.loadDeviceRegistrations()
	if err != nil {
		return err
	}
	count := 0
	for _, item := range doc.Items {
		if item.SPKISHA256 == spki {
			if item.OwnerUserID == user.ID && item.State == "pending" {
				return ErrDeviceApprovalPending
			}
			return ErrLogin
		}
		if item.OwnerUserID == user.ID && item.State == "pending" {
			count++
		}
	}
	if len(doc.Items) >= 256 || count >= 8 {
		return ErrLogin
	}
	item := DeviceRegistration{ID: randomID(), OwnerUserID: user.ID, Label: "手机登录申请", PublicKeyPEM: key, SPKISHA256: spki, State: "pending", CreatedAt: s.now().UTC(), LoginLeafPEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw}))}
	if !validRegistration(item) {
		return ErrLogin
	}
	doc.Items = append(doc.Items, item)
	doc.Revision++
	raw, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var query = "UPDATE security_settings SET value=? WHERE key=? AND value=?"
	args := []any{string(raw), deviceRegistrationsKey, previous}
	if previous == "" {
		query = "INSERT INTO security_settings(value,key) VALUES(?,?) ON CONFLICT(key) DO NOTHING"
		args = args[:2]
	}
	result, err := tx.Exec(query, args...)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil || n != 1 {
		return ErrDeviceRegistrationConflict
	}
	if auditTx(tx, user.ID, "device_login.request", item.ID, "pending") != nil || tx.Commit() != nil {
		return ErrDeviceRegistrationUnavailable
	}
	return ErrDeviceApprovalPending
}

// ApproveLoginDevice atomically approves the account binding and exact TLS leaf.
// Expiry follows the installation certificate; no second certificate step.
func (s *Service) ApproveLoginDevice(actor authorization.Actor, revision int64, id string) (DeviceRegistrationSnapshot, error) {
	return s.mutateDeviceRegistration(actor, revision, "approve_login", func(doc *deviceRegistrationDocument) (string, error) {
		for i := range doc.Items {
			item := &doc.Items[i]
			if item.ID != id {
				continue
			}
			leaf, _, _, err := certificateLeaf(item.LoginLeafPEM)
			now := s.now().UTC()
			if err != nil || item.State != "pending" || now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
				return "", ErrDeviceRegistrationInvalid
			}
			if err = s.activeRegistrationOwner(item.OwnerUserID); err != nil {
				return "", err
			}
			item.State, item.ApprovedBy = "approved", actor.ID
			item.ApprovedAt, item.ExpiresAt = &now, &leaf.NotAfter
			return id, nil
		}
		return "", ErrDeviceRegistrationNotFound
	})
}

func approveLoginCertificateTx(tx *persistence.Tx, registration DeviceRegistration, actorID string, now time.Time) error {
	leaf, digest, spki, err := certificateLeaf(registration.LoginLeafPEM)
	if err != nil {
		return err
	}
	doc, previous, err := readCertificateDocument(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	if err != nil {
		return err
	}
	if len(doc.Items) >= 256 {
		return ErrDeviceCertificateInvalid
	}
	generation := make([]byte, 16)
	if _, err = rand.Read(generation); err != nil {
		return err
	}
	doc.Items = append(doc.Items, DeviceCertificate{RegistrationID: registration.ID, OwnerUserID: registration.OwnerUserID, ApprovalID: hex.EncodeToString(generation), LeafPEM: registration.LoginLeafPEM, LeafSHA256: digest, SPKISHA256: spki, ApprovedAt: now, ApprovedBy: actorID, ExpiresAt: leaf.NotAfter})
	return saveCertificateDocument(tx, doc, previous)
}

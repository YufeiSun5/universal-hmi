package identity

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"strings"
	"time"
	"unicode"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

var (
	ErrDeviceRegistrationUnavailable = errors.New("device registrations unavailable")
	ErrDeviceRegistrationInvalid     = errors.New("invalid device registration")
	ErrDeviceRegistrationConflict    = errors.New("device registration revision conflict")
	ErrDeviceRegistrationNotFound    = errors.New("device registration not found")
)

const deviceRegistrationsKey = "public_device_registrations_v1"

// DeviceRegistration binds an account and installation public key. Manual CSR
// records require a separate certificate approval; LoginLeafPEM requests are
// approved atomically with that exact TLS leaf. Neither is hardware attestation.
type DeviceRegistration struct {
	ID           string     `json:"id"`
	OwnerUserID  string     `json:"owner_user_id"`
	OwnerStatus  string     `json:"owner_status,omitempty"`
	Label        string     `json:"label"`
	SPKISHA256   string     `json:"spki_sha256"`
	PublicKeyPEM string     `json:"public_key_pem"`
	LoginLeafPEM string     `json:"login_leaf_pem,omitempty"`
	State        string     `json:"state"`
	CreatedAt    time.Time  `json:"created_at"`
	ApprovedAt   *time.Time `json:"approved_at,omitempty"`
	ApprovedBy   string     `json:"approved_by,omitempty"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
	DisabledAt   *time.Time `json:"disabled_at,omitempty"`
}
type DeviceRegistrationSnapshot struct {
	Schema               int                  `json:"schema"`
	Revision             int64                `json:"revision"`
	Items                []DeviceRegistration `json:"items"`
	MobileTransportReady bool                 `json:"mobile_transport_ready"`
	GrantsAccess         bool                 `json:"grants_access"`
}
type deviceRegistrationDocument struct {
	Schema   int                  `json:"schema"`
	Revision int64                `json:"revision"`
	Items    []DeviceRegistration `json:"items"`
}

func registrationPublicKey(key any) (string, string, error) {
	ec, ok := key.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() || !ec.Curve.IsOnCurve(ec.X, ec.Y) {
		return "", "", ErrDeviceRegistrationInvalid
	}
	der, err := x509.MarshalPKIXPublicKey(ec)
	if err != nil {
		return "", "", ErrDeviceRegistrationInvalid
	}
	sum := sha256.Sum256(der)
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})), hex.EncodeToString(sum[:]), nil
}
func registrationCSR(raw string) (string, string, error) {
	if len(raw) == 0 || len(raw) > 8192 || !strings.HasPrefix(raw, "-----BEGIN CERTIFICATE REQUEST-----") {
		return "", "", ErrDeviceRegistrationInvalid
	}
	block, rest := pem.Decode([]byte(raw))
	if block == nil || block.Type != "CERTIFICATE REQUEST" || len(block.Headers) != 0 || len(bytes.TrimSpace(rest)) != 0 {
		return "", "", ErrDeviceRegistrationInvalid
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil || csr.CheckSignature() != nil {
		return "", "", ErrDeviceRegistrationInvalid
	}
	return registrationPublicKey(csr.PublicKey)
}
func registrationTime(t *time.Time) bool {
	return t != nil && !t.IsZero() && t.Year() >= 1 && t.Year() <= 9999
}
func validRegistration(item DeviceRegistration) bool {
	if len(item.ID) != 32 || !publicIPIdentifier.MatchString(item.ID) || !publicIPIdentifier.MatchString(item.OwnerUserID) || item.OwnerStatus != "" || strings.TrimSpace(item.Label) == "" || len(item.Label) > 128 || strings.IndexFunc(item.Label, unicode.IsControl) >= 0 || !registrationTime(&item.CreatedAt) || len(item.PublicKeyPEM) > 2048 {
		return false
	}
	block, rest := pem.Decode([]byte(item.PublicKeyPEM))
	if block == nil || block.Type != "PUBLIC KEY" || len(block.Headers) != 0 || len(rest) != 0 {
		return false
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return false
	}
	canonical, digest, err := registrationPublicKey(key)
	if err != nil || canonical != item.PublicKeyPEM || digest != item.SPKISHA256 {
		return false
	}
	if item.LoginLeafPEM != "" {
		_, _, spki, err := certificateLeaf(item.LoginLeafPEM)
		if err != nil || spki != item.SPKISHA256 {
			return false
		}
	}
	approved := registrationTime(item.ApprovedAt) && registrationTime(item.ExpiresAt) && publicIPIdentifier.MatchString(item.ApprovedBy) && !item.ApprovedAt.Before(item.CreatedAt) && item.ExpiresAt.After(*item.ApprovedAt)
	pending := item.ApprovedAt == nil && item.ExpiresAt == nil && item.ApprovedBy == ""
	switch item.State {
	case "pending":
		return pending && item.DisabledAt == nil
	case "approved":
		return approved && item.DisabledAt == nil
	case "disabled":
		return (pending || approved) && registrationTime(item.DisabledAt) && !item.DisabledAt.Before(item.CreatedAt)
	}
	return false
}
func (s *Service) loadDeviceRegistrations() (deviceRegistrationDocument, string, error) {
	var raw string
	err := s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceRegistrationsKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return deviceRegistrationDocument{Schema: 1, Items: []DeviceRegistration{}}, "", nil
	}
	if err != nil {
		return deviceRegistrationDocument{}, "", ErrDeviceRegistrationUnavailable
	}
	var doc deviceRegistrationDocument
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&doc) != nil || decoder.Decode(new(any)) != io.EOF || doc.Schema != 1 || doc.Revision < 1 || len(doc.Items) > 256 {
		return doc, "", ErrDeviceRegistrationUnavailable
	}
	ids, keys := map[string]bool{}, map[string]bool{}
	for _, item := range doc.Items {
		if !validRegistration(item) || ids[item.ID] || keys[item.SPKISHA256] {
			return doc, "", ErrDeviceRegistrationUnavailable
		}
		ids[item.ID] = true
		keys[item.SPKISHA256] = true
	}
	return doc, raw, nil
}
func (s *Service) registrationSnapshot(doc deviceRegistrationDocument) (DeviceRegistrationSnapshot, error) {
	out := DeviceRegistrationSnapshot{Schema: 1, Revision: doc.Revision, Items: append([]DeviceRegistration{}, doc.Items...)}
	for i := range out.Items {
		item := &out.Items[i]
		var disabled int
		err := s.db.QueryRow("SELECT disabled FROM users WHERE id=?", item.OwnerUserID).Scan(&disabled)
		if errors.Is(err, sql.ErrNoRows) {
			item.OwnerStatus = "missing"
		} else if err != nil {
			return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
		} else if disabled != 0 {
			item.OwnerStatus = "disabled"
		} else {
			item.OwnerStatus = "active"
		}
	}
	return out, nil
}
func (s *Service) DeviceRegistrations(actor authorization.Actor) (DeviceRegistrationSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return DeviceRegistrationSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Active may resolve a session and take s.mu; never call it under this lock.
	// Recheck the account revision under the same lock as account mutations.
	if err := s.registrationActorCurrent(actor); err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	doc, _, err := s.loadDeviceRegistrations()
	if err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	return s.registrationSnapshot(doc)
}
func (s *Service) activeRegistrationOwner(id string) error {
	if !publicIPIdentifier.MatchString(id) {
		return ErrDeviceRegistrationInvalid
	}
	var disabled int
	err := s.db.QueryRow("SELECT disabled FROM users WHERE id=?", id).Scan(&disabled)
	if errors.Is(err, sql.ErrNoRows) || err == nil && disabled != 0 {
		return ErrDeviceRegistrationInvalid
	}
	if err != nil {
		return ErrDeviceRegistrationUnavailable
	}
	return nil
}
func (s *Service) mutateDeviceRegistration(actor authorization.Actor, revision int64, action string, change func(*deviceRegistrationDocument) (string, error)) (DeviceRegistrationSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return DeviceRegistrationSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Active may resolve a session and take s.mu; never call it under this lock.
	// Recheck the account revision under the same lock as account mutations.
	if err := s.registrationActorCurrent(actor); err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	doc, previous, err := s.loadDeviceRegistrations()
	if err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	if revision != doc.Revision {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationConflict
	}
	id, err := change(&doc)
	if err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	doc.Revision++
	if doc.Revision <= 0 {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationInvalid
	}
	// Capture the exact mutation revision before commit. No later reload mixes
	// a device from this write with another writer's revision.
	snapshot, err := s.registrationSnapshot(doc)
	if err != nil {
		return DeviceRegistrationSnapshot{}, err
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationInvalid
	}
	tx, err := s.db.Begin()
	if err != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
	}
	defer tx.Rollback()
	var result sql.Result
	if previous == "" {
		result, err = tx.Exec("INSERT INTO security_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", deviceRegistrationsKey, string(raw))
	} else {
		result, err = tx.Exec("UPDATE security_settings SET value=? WHERE key=? AND value=?", string(raw), deviceRegistrationsKey, previous)
	}
	if err != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
	}
	n, err := result.RowsAffected()
	if err != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
	}
	if n != 1 {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationConflict
	}
	if action == "approve" {
		if err := revokeRegistrationCertificateTx(tx, id, s.now().UTC()); err != nil {
			if errors.Is(err, ErrDeviceCertificateConflict) {
				return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationConflict
			}
			return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
		}
	}
	if action == "approve_login" {
		for _, item := range doc.Items {
			if item.ID == id {
				if err = approveLoginCertificateTx(tx, item, actor.ID, s.now().UTC()); err != nil {
					return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
				}
			}
		}
	}
	resultText := "saved; grants_access=false"
	if action == "approve_login" {
		resultText = "approved; exact TLS leaf and owner bound"
	}
	if auditTx(tx, actor.ID, "device_registration."+action, id, resultText) != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
	}
	if tx.Commit() != nil {
		return DeviceRegistrationSnapshot{}, ErrDeviceRegistrationUnavailable
	}
	return snapshot, nil
}
func (s *Service) CreateDeviceRegistration(actor authorization.Actor, revision int64, ownerID, label, csrPEM string) (DeviceRegistrationSnapshot, error) {
	return s.mutateDeviceRegistration(actor, revision, "create", func(doc *deviceRegistrationDocument) (string, error) {
		if len(doc.Items) >= 256 {
			return "", ErrDeviceRegistrationInvalid
		}
		if err := s.activeRegistrationOwner(ownerID); err != nil {
			return "", err
		}
		key, digest, err := registrationCSR(csrPEM)
		if err != nil {
			return "", err
		}
		for _, item := range doc.Items {
			if item.SPKISHA256 == digest {
				return "", ErrDeviceRegistrationInvalid
			}
		}
		item := DeviceRegistration{ID: randomID(), OwnerUserID: ownerID, Label: label, PublicKeyPEM: key, SPKISHA256: digest, State: "pending", CreatedAt: s.now().UTC()}
		if !validRegistration(item) {
			return "", ErrDeviceRegistrationInvalid
		}
		doc.Items = append(doc.Items, item)
		return item.ID, nil
	})
}
func (s *Service) ApproveDeviceRegistration(actor authorization.Actor, revision int64, id string, expiresAt time.Time) (DeviceRegistrationSnapshot, error) {
	return s.mutateDeviceRegistration(actor, revision, "approve", func(doc *deviceRegistrationDocument) (string, error) {
		now := s.now().UTC()
		if !registrationTime(&expiresAt) || !expiresAt.After(now) {
			return "", ErrDeviceRegistrationInvalid
		}
		for i := range doc.Items {
			item := &doc.Items[i]
			if item.ID != id {
				continue
			}
			if item.State == "disabled" {
				return "", ErrDeviceRegistrationInvalid
			}
			if err := s.activeRegistrationOwner(item.OwnerUserID); err != nil {
				return "", err
			}
			expiry := expiresAt.UTC()
			item.State = "approved"
			item.ApprovedAt = &now
			item.ApprovedBy = actor.ID
			item.ExpiresAt = &expiry
			if !validRegistration(*item) {
				return "", ErrDeviceRegistrationInvalid
			}
			return id, nil
		}
		return "", ErrDeviceRegistrationNotFound
	})
}
func (s *Service) DisableDeviceRegistration(actor authorization.Actor, revision int64, id string) (DeviceRegistrationSnapshot, error) {
	return s.mutateDeviceRegistration(actor, revision, "disable", func(doc *deviceRegistrationDocument) (string, error) {
		for i := range doc.Items {
			item := &doc.Items[i]
			if item.ID != id {
				continue
			}
			if item.State == "disabled" {
				return "", ErrDeviceRegistrationInvalid
			}
			now := s.now().UTC()
			item.State = "disabled"
			item.DisabledAt = &now
			if !validRegistration(*item) {
				return "", ErrDeviceRegistrationInvalid
			}
			return id, nil
		}
		return "", ErrDeviceRegistrationNotFound
	})
}

func (s *Service) registrationActorCurrent(actor authorization.Actor) error {
	user, err := s.User(actor.ID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrDenied
	}
	if err != nil {
		return ErrDeviceRegistrationUnavailable
	}
	if user.Disabled || user.Version != actor.Version {
		return ErrDenied
	}
	return nil
}

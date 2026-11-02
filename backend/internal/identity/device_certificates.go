package identity

import (
	"bytes"
	"crypto/rand"
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

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

var (
	ErrDeviceCertificateUnavailable = errors.New("device certificates unavailable")
	ErrDeviceCertificateInvalid     = errors.New("invalid device certificate")
	ErrDeviceCertificateConflict    = errors.New("device certificate revision conflict")
	ErrDeviceCertificateNotFound    = errors.New("device certificate not found")
)

const deviceCertificatesKey = "public_device_certificates_v1"

// DeviceCertificate is an explicit exact-leaf pin, not CA trust or proof that
// a request possesses its private key. No certificate approval enables access.
type DeviceCertificate struct {
	RegistrationID string     `json:"registration_id"`
	OwnerUserID    string     `json:"owner_user_id"`
	ApprovalID     string     `json:"approval_id"`
	LeafPEM        string     `json:"leaf_pem"`
	LeafSHA256     string     `json:"leaf_sha256"`
	SPKISHA256     string     `json:"spki_sha256"`
	ApprovedAt     time.Time  `json:"approved_at"`
	ApprovedBy     string     `json:"approved_by"`
	ExpiresAt      time.Time  `json:"expires_at"`
	RevokedAt      *time.Time `json:"revoked_at,omitempty"`
}
type DeviceCertificateSnapshot struct {
	Schema               int                 `json:"schema"`
	Revision             int64               `json:"revision"`
	Items                []DeviceCertificate `json:"items"`
	MobileTransportReady bool                `json:"mobile_transport_ready"`
	GrantsAccess         bool                `json:"grants_access"`
}
type deviceCertificateDocument struct {
	Schema   int                 `json:"schema"`
	Revision int64               `json:"revision"`
	Items    []DeviceCertificate `json:"items"`
}

func certificateLeaf(raw string) (*x509.Certificate, string, string, error) {
	if len(raw) == 0 || len(raw) > 16384 || !strings.HasPrefix(raw, "-----BEGIN CERTIFICATE-----") {
		return nil, "", "", ErrDeviceCertificateInvalid
	}
	block, rest := pem.Decode([]byte(raw))
	if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 || len(bytes.TrimSpace(rest)) != 0 {
		return nil, "", "", ErrDeviceCertificateInvalid
	}
	leaf, err := x509.ParseCertificate(block.Bytes)
	if err != nil || leaf.IsCA || len(leaf.UnhandledCriticalExtensions) > 0 || leaf.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return nil, "", "", ErrDeviceCertificateInvalid
	}
	explicitClient := false
	for _, usage := range leaf.ExtKeyUsage {
		if usage == x509.ExtKeyUsageClientAuth {
			explicitClient = true
		}
	}
	if !explicitClient {
		return nil, "", "", ErrDeviceCertificateInvalid
	}
	_, spki, err := registrationPublicKey(leaf.PublicKey)
	if err != nil {
		return nil, "", "", ErrDeviceCertificateInvalid
	}
	digest := sha256.Sum256(leaf.Raw)
	return leaf, hex.EncodeToString(digest[:]), spki, nil
}
func validCertificateRecord(item DeviceCertificate) bool {
	leaf, digest, spki, err := certificateLeaf(item.LeafPEM)
	generation, e := hex.DecodeString(item.ApprovalID)
	if err != nil || e != nil || len(generation) != 16 || hex.EncodeToString(generation) != item.ApprovalID || len(item.RegistrationID) != 32 || !publicIPIdentifier.MatchString(item.RegistrationID) || !publicIPIdentifier.MatchString(item.OwnerUserID) || !publicIPIdentifier.MatchString(item.ApprovedBy) || digest != item.LeafSHA256 || spki != item.SPKISHA256 {
		return false
	}
	if string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})) != item.LeafPEM {
		return false
	}
	return registrationTime(&item.ApprovedAt) && registrationTime(&item.ExpiresAt) && !item.ApprovedAt.Before(leaf.NotBefore) && item.ExpiresAt.After(item.ApprovedAt) && !item.ExpiresAt.After(leaf.NotAfter) && (item.RevokedAt == nil || registrationTime(item.RevokedAt) && !item.RevokedAt.Before(item.ApprovedAt))
}
func parseCertificateDocument(raw string) (deviceCertificateDocument, error) {
	var doc deviceCertificateDocument
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&doc) != nil || d.Decode(new(any)) != io.EOF || doc.Schema != 1 || doc.Revision < 1 || len(doc.Items) > 256 {
		return doc, ErrDeviceCertificateUnavailable
	}
	ids, generations := map[string]bool{}, map[string]bool{}
	for _, item := range doc.Items {
		if !validCertificateRecord(item) || ids[item.RegistrationID] || generations[item.ApprovalID] {
			return doc, ErrDeviceCertificateUnavailable
		}
		ids[item.RegistrationID] = true
		generations[item.ApprovalID] = true
	}
	return doc, nil
}
func readCertificateDocument(row *sql.Row) (deviceCertificateDocument, string, error) {
	var raw string
	err := row.Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return deviceCertificateDocument{Schema: 1, Items: []DeviceCertificate{}}, "", nil
	}
	if err != nil {
		return deviceCertificateDocument{}, "", ErrDeviceCertificateUnavailable
	}
	doc, err := parseCertificateDocument(raw)
	return doc, raw, err
}
func certificateSnapshot(doc deviceCertificateDocument) DeviceCertificateSnapshot {
	return DeviceCertificateSnapshot{Schema: doc.Schema, Revision: doc.Revision, Items: doc.Items}
}
func (s *Service) DeviceCertificates(actor authorization.Actor) (DeviceCertificateSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return DeviceCertificateSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.registrationActorCurrent(actor); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	doc, _, err := readCertificateDocument(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	return certificateSnapshot(doc), err
}
func saveCertificateDocument(tx *persistence.Tx, doc deviceCertificateDocument, previous string) error {
	for _, item := range doc.Items {
		if !validCertificateRecord(item) {
			return ErrDeviceCertificateInvalid
		}
	}
	doc.Revision++
	if doc.Revision <= 0 {
		return ErrDeviceCertificateInvalid
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		return ErrDeviceCertificateInvalid
	}
	var result sql.Result
	if previous == "" {
		result, err = tx.Exec("INSERT INTO security_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", deviceCertificatesKey, string(raw))
	} else {
		result, err = tx.Exec("UPDATE security_settings SET value=? WHERE key=? AND value=?", string(raw), deviceCertificatesKey, previous)
	}
	if err != nil {
		return ErrDeviceCertificateUnavailable
	}
	n, err := result.RowsAffected()
	if err != nil {
		return ErrDeviceCertificateUnavailable
	}
	if n != 1 {
		return ErrDeviceCertificateConflict
	}
	return nil
}

// The caller has already CAS-locked the registration row. Keep reg -> cert lock
// order so certificate approval cannot race reapproval across Service instances.
func revokeRegistrationCertificateTx(tx *persistence.Tx, id string, now time.Time) error {
	doc, raw, err := readCertificateDocument(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	if err != nil {
		return err
	}
	for i := range doc.Items {
		if doc.Items[i].RegistrationID == id && doc.Items[i].RevokedAt == nil {
			doc.Items[i].RevokedAt = &now
			return saveCertificateDocument(tx, doc, raw)
		}
	}
	return nil
}
func (s *Service) ApproveDeviceCertificate(actor authorization.Actor, revision int64, id, leafPEM string, expiresAt time.Time) (DeviceCertificateSnapshot, error) {
	return s.approveDeviceCertificate(actor, revision, id, leafPEM, expiresAt, false)
}

// ApproveDeviceCertificateForLeaf explicitly follows the public leaf's expiry.
// Registration lifetime, owner, current approval generation and revocation still apply.
func (s *Service) ApproveDeviceCertificateForLeaf(actor authorization.Actor, revision int64, id, leafPEM string) (DeviceCertificateSnapshot, error) {
	return s.approveDeviceCertificate(actor, revision, id, leafPEM, time.Time{}, true)
}

func (s *Service) approveDeviceCertificate(actor authorization.Actor, revision int64, id, leafPEM string, expiresAt time.Time, followLeaf bool) (DeviceCertificateSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return DeviceCertificateSnapshot{}, ErrDenied
	}
	leaf, digest, spki, err := certificateLeaf(leafPEM)
	if err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err = s.registrationActorCurrent(actor); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	registrations, registrationRaw, err := s.loadDeviceRegistrations()
	if err != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	var registration *DeviceRegistration
	for i := range registrations.Items {
		if registrations.Items[i].ID == id {
			registration = &registrations.Items[i]
			break
		}
	}
	if registration == nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateNotFound
	}
	now := s.now().UTC()
	if followLeaf {
		expiresAt = leaf.NotAfter
	}
	expiresAt = expiresAt.UTC()
	if registration.State != "approved" || registration.ExpiresAt == nil || !registration.ExpiresAt.After(now) || registration.SPKISHA256 != spki || leaf.NotAfter.After(*registration.ExpiresAt) || now.Before(leaf.NotBefore) || !registrationTime(&expiresAt) || !expiresAt.After(now) || expiresAt.After(leaf.NotAfter) || expiresAt.After(*registration.ExpiresAt) {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateInvalid
	}
	if err = s.activeRegistrationOwner(registration.OwnerUserID); err != nil {
		if errors.Is(err, ErrDeviceRegistrationUnavailable) {
			return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
		}
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateInvalid
	}
	tx, err := s.db.Begin()
	if err != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	defer tx.Rollback()
	if err = guardCertificateRegistrationTx(tx, registrationRaw); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	doc, raw, err := readCertificateDocument(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	if err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	if revision != doc.Revision {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateConflict
	}
	generation := make([]byte, 16)
	if _, err = rand.Read(generation); err != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	item := DeviceCertificate{RegistrationID: id, OwnerUserID: registration.OwnerUserID, ApprovalID: hex.EncodeToString(generation), LeafPEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})), LeafSHA256: digest, SPKISHA256: spki, ApprovedAt: now, ApprovedBy: actor.ID, ExpiresAt: expiresAt}
	found := false
	for i := range doc.Items {
		if doc.Items[i].RegistrationID == id {
			doc.Items[i] = item
			found = true
			break
		}
	}
	if !found {
		if len(doc.Items) >= 256 {
			return DeviceCertificateSnapshot{}, ErrDeviceCertificateInvalid
		}
		doc.Items = append(doc.Items, item)
	}
	if err = saveCertificateDocument(tx, doc, raw); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	if auditTx(tx, actor.ID, "device_certificate.approve", id, "saved; transport not enabled") != nil || tx.Commit() != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	doc.Revision++
	return certificateSnapshot(doc), nil
}
func (s *Service) RevokeDeviceCertificate(actor authorization.Actor, revision int64, id string) (DeviceCertificateSnapshot, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return DeviceCertificateSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.registrationActorCurrent(actor); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	defer tx.Rollback()
	doc, raw, err := readCertificateDocument(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	if err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	if revision != doc.Revision {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateConflict
	}
	found := false
	for i := range doc.Items {
		if doc.Items[i].RegistrationID == id {
			if doc.Items[i].RevokedAt != nil {
				return DeviceCertificateSnapshot{}, ErrDeviceCertificateInvalid
			}
			now := s.now().UTC()
			doc.Items[i].RevokedAt = &now
			found = true
			break
		}
	}
	if !found {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateNotFound
	}
	if err = saveCertificateDocument(tx, doc, raw); err != nil {
		return DeviceCertificateSnapshot{}, err
	}
	if auditTx(tx, actor.ID, "device_certificate.revoke", id, "saved") != nil || tx.Commit() != nil {
		return DeviceCertificateSnapshot{}, ErrDeviceCertificateUnavailable
	}
	doc.Revision++
	return certificateSnapshot(doc), nil
}

// VerifyDeviceCertificate checks only current exact-leaf approval. The caller
// must separately require TLS proof of private-key possession and account/MFA.
// Never install this as a LinkedValid callback called while holding s.mu.
func (s *Service) VerifyDeviceCertificate(leaf *x509.Certificate) (DeviceCertificate, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.verifyDeviceCertificateLocked(leaf)
}
func (s *Service) verifyDeviceCertificateLocked(leaf *x509.Certificate) (DeviceCertificate, error) {
	if leaf == nil || len(leaf.Raw) == 0 {
		return DeviceCertificate{}, ErrDeviceCertificateInvalid
	}
	digest := sha256.Sum256(leaf.Raw)
	doc, _, err := readCertificateDocument(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", deviceCertificatesKey))
	if err != nil {
		return DeviceCertificate{}, err
	}
	registrations, _, err := s.loadDeviceRegistrations()
	if err != nil {
		return DeviceCertificate{}, ErrDeviceCertificateUnavailable
	}
	now := s.now()
	for _, item := range doc.Items {
		if item.LeafSHA256 != hex.EncodeToString(digest[:]) {
			continue
		}
		if item.RevokedAt != nil || !now.Before(item.ExpiresAt) || now.Before(item.ApprovedAt) {
			return DeviceCertificate{}, ErrDeviceCertificateInvalid
		}
		for _, registration := range registrations.Items {
			if registration.ID == item.RegistrationID && registration.State == "approved" && registration.ExpiresAt != nil && now.Before(*registration.ExpiresAt) && registration.OwnerUserID == item.OwnerUserID && registration.SPKISHA256 == item.SPKISHA256 {
				if err = s.activeRegistrationOwner(item.OwnerUserID); err != nil {
					if errors.Is(err, ErrDeviceRegistrationUnavailable) {
						return DeviceCertificate{}, ErrDeviceCertificateUnavailable
					}
					return DeviceCertificate{}, ErrDeviceCertificateInvalid
				}
				return item, nil
			}
		}
	}
	return DeviceCertificate{}, ErrDeviceCertificateInvalid
}

func guardCertificateRegistrationTx(tx *persistence.Tx, raw string) error {
	// Same-value CAS acquires the row lock and verifies the exact approval that
	// was validated above. A concurrent registration approval must serialize here.
	result, err := tx.Exec("UPDATE security_settings SET value=value WHERE key=? AND value=?", deviceRegistrationsKey, raw)
	if err != nil {
		return ErrDeviceCertificateUnavailable
	}
	n, err := result.RowsAffected()
	if err != nil {
		return ErrDeviceCertificateUnavailable
	}
	if n != 1 {
		return ErrDeviceCertificateConflict
	}
	return nil
}

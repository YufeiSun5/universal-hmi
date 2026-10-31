package identity

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"regexp"
	"strings"
	"time"
	"unicode"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

var (
	ErrPublicIPConflict    = errors.New("public IP policy revision conflict")
	ErrPublicIPInvalid     = errors.New("invalid public IP policy")
	ErrPublicIPUnavailable = errors.New("public IP policy unavailable")
	publicIPIdentifier     = regexp.MustCompile(`^[A-Za-z0-9_-]{1,96}$`)
)

const publicIPKey = "public_ip_policy_v1"

type PublicIPRule struct {
	ID          string     `json:"id"`
	CIDR        string     `json:"cidr"`
	OwnerLabel  string     `json:"owner_label"`
	OwnerUserID string     `json:"owner_user_id,omitempty"`
	OwnerStatus string     `json:"owner_status,omitempty"`
	Remark      string     `json:"remark,omitempty"`
	Enabled     bool       `json:"enabled"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
}
type PublicIPPolicy struct {
	Schema   int            `json:"schema"`
	Revision int64          `json:"revision"`
	Rules    []PublicIPRule `json:"rules"`
	Source   string         `json:"source"`
}

func publicIPPrefix(raw string) (netip.Prefix, error) {
	if ip, e := netip.ParseAddr(raw); e == nil && ip.Zone() == "" {
		ip = ip.Unmap()
		return netip.PrefixFrom(ip, ip.BitLen()), nil
	}
	p, e := netip.ParsePrefix(raw)
	if e != nil || p.Addr().Is4In6() || p.Addr().Zone() != "" {
		return netip.Prefix{}, ErrPublicIPInvalid
	}
	return p.Masked(), nil
}
func copyPublicIP(p PublicIPPolicy) PublicIPPolicy {
	p.Rules = append([]PublicIPRule{}, p.Rules...)
	for i := range p.Rules {
		if p.Rules[i].ExpiresAt != nil {
			v := *p.Rules[i].ExpiresAt
			p.Rules[i].ExpiresAt = &v
		}
	}
	return p
}
func validatePublicIP(p PublicIPPolicy) error {
	if p.Schema != 1 || p.Revision < 0 || len(p.Rules) > 256 {
		return ErrPublicIPInvalid
	}
	seen := map[string]bool{}
	for _, r := range p.Rules {
		if !publicIPIdentifier.MatchString(r.ID) || seen[r.ID] {
			return ErrPublicIPInvalid
		}
		seen[r.ID] = true
		if _, e := publicIPPrefix(r.CIDR); e != nil {
			return e
		}
		if len(r.OwnerLabel) > 128 || len(r.Remark) > 512 || strings.IndexFunc(r.OwnerLabel+r.Remark, unicode.IsControl) >= 0 {
			return ErrPublicIPInvalid
		}
		if r.OwnerUserID != "" && !publicIPIdentifier.MatchString(r.OwnerUserID) {
			return ErrPublicIPInvalid
		}
		if r.ExpiresAt != nil && (r.ExpiresAt.IsZero() || r.ExpiresAt.Year() < 1 || r.ExpiresAt.Year() > 9999) {
			return ErrPublicIPInvalid
		}
	}
	return nil
}

// InitPublicIPPolicy never writes bootstrap data. A stored policy is authoritative,
// including malformed data: failure disables policy checks rather than falling back.
func (s *Service) InitPublicIPPolicy(bootstrap []PublicIPRule) error {
	s.publicIPMu.Lock()
	defer s.publicIPMu.Unlock()
	s.publicIPPolicy = nil
	s.publicIPRaw = ""
	var raw string
	err := s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicIPKey).Scan(&raw)
	p := PublicIPPolicy{Schema: 1, Source: "file", Rules: copyPublicIP(PublicIPPolicy{Rules: bootstrap}).Rules}
	if errors.Is(err, sql.ErrNoRows) {
		for i := range p.Rules {
			p.Rules[i].ID = randomID()
			p.Rules[i].OwnerStatus = ""
		}
	} else if err != nil {
		return ErrPublicIPUnavailable
	} else {
		p = PublicIPPolicy{}
		decoder := json.NewDecoder(bytes.NewBufferString(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&p) != nil || decoder.Decode(new(any)) != io.EOF || p.Revision < 1 {
			return ErrPublicIPInvalid
		}
		p.Source = "database"
	}
	if err = validatePublicIP(p); err != nil {
		return err
	}
	s.publicIPPolicy = &p
	s.publicIPRaw = raw
	return nil
}
func (s *Service) publicIPSnapshotLocked() (PublicIPPolicy, error) {
	if s.publicIPPolicy == nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	return s.publicIPOwnerSnapshot(*s.publicIPPolicy)
}
func (s *Service) publicIPOwnerSnapshot(policy PublicIPPolicy) (PublicIPPolicy, error) {
	p := copyPublicIP(policy)
	for i := range p.Rules {
		r := &p.Rules[i]
		r.OwnerStatus = ""
		if r.OwnerUserID == "" {
			continue
		}
		var disabled int
		err := s.db.QueryRow("SELECT disabled FROM users WHERE id=?", r.OwnerUserID).Scan(&disabled)
		if errors.Is(err, sql.ErrNoRows) {
			r.OwnerStatus = "missing"
		} else if err != nil {
			return PublicIPPolicy{}, ErrPublicIPUnavailable
		} else if disabled != 0 {
			r.OwnerStatus = "disabled"
		} else {
			r.OwnerStatus = "active"
		}
	}
	return p, nil
}
func (s *Service) PublicIPPolicy(actor authorization.Actor) (PublicIPPolicy, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return PublicIPPolicy{}, ErrDenied
	}
	s.publicIPMu.RLock()
	defer s.publicIPMu.RUnlock()
	return s.publicIPSnapshotLocked()
}
func (s *Service) SavePublicIPPolicy(actor authorization.Actor, expected int64, rules []PublicIPRule) (PublicIPPolicy, error) {
	if !actor.Active() || !actor.Grants.Manage() {
		return PublicIPPolicy{}, ErrDenied
	}
	s.publicIPMu.Lock()
	defer s.publicIPMu.Unlock()
	if s.publicIPPolicy == nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	old := s.publicIPPolicy
	if expected != old.Revision {
		return PublicIPPolicy{}, ErrPublicIPConflict
	}
	p := PublicIPPolicy{Schema: 1, Revision: expected + 1, Source: "database", Rules: copyPublicIP(PublicIPPolicy{Rules: rules}).Rules}
	previous := map[string]PublicIPRule{}
	for _, r := range old.Rules {
		previous[r.ID] = r
	}
	for i := range p.Rules {
		r := &p.Rules[i]
		r.OwnerStatus = ""
		prior, exists := previous[r.ID]
		if r.ID == "" {
			r.ID = randomID()
		} else if !exists {
			return PublicIPPolicy{}, ErrPublicIPInvalid
		}
		if r.OwnerUserID != "" && (!exists || prior.OwnerUserID != r.OwnerUserID) {
			var n int
			if err := s.db.QueryRow("SELECT count(*) FROM users WHERE id=?", r.OwnerUserID).Scan(&n); err != nil {
				return PublicIPPolicy{}, ErrPublicIPUnavailable
			}
			if n != 1 {
				return PublicIPPolicy{}, ErrPublicIPInvalid
			}
		}
	}
	if err := validatePublicIP(p); err != nil {
		return PublicIPPolicy{}, err
	}
	response, err := s.publicIPOwnerSnapshot(p)
	if err != nil {
		return PublicIPPolicy{}, err
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return PublicIPPolicy{}, ErrPublicIPInvalid
	}
	tx, err := s.db.Begin()
	if err != nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	defer tx.Rollback()
	var result sql.Result
	if old.Source == "file" {
		result, err = tx.Exec("INSERT INTO security_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", publicIPKey, string(raw))
	} else {
		result, err = tx.Exec("UPDATE security_settings SET value=? WHERE key=? AND value=?", string(raw), publicIPKey, s.publicIPRaw)
	}
	if err != nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	count, err := result.RowsAffected()
	if err != nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	if count != 1 {
		return PublicIPPolicy{}, ErrPublicIPConflict
	}
	if auditTx(tx, actor.ID, "public_ip_policy.change", publicIPKey, "saved") != nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	if tx.Commit() != nil {
		return PublicIPPolicy{}, ErrPublicIPUnavailable
	}
	s.publicIPPolicy = &p
	s.publicIPRaw = string(raw)
	return response, nil
}

// PublicIPAllowed uses only network approval, never owner metadata as identity.
func (s *Service) PublicIPAllowed(ip netip.Addr) bool {
	if !ip.IsValid() || ip.Zone() != "" {
		return false
	}
	s.publicIPMu.RLock()
	defer s.publicIPMu.RUnlock()
	if s.publicIPPolicy == nil {
		return false
	}
	now := s.now()
	for _, r := range s.publicIPPolicy.Rules {
		if !r.Enabled || (r.ExpiresAt != nil && !now.Before(*r.ExpiresAt)) {
			continue
		}
		p, e := publicIPPrefix(r.CIDR)
		if e == nil && p.Contains(ip.Unmap()) {
			return true
		}
	}
	return false
}

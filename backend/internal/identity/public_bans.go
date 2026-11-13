package identity

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

const publicBansKey = "public_ip_bans_v1"

var ErrPublicBanUnavailable = errors.New("public ban storage unavailable")
var ErrPublicBanConflict = errors.New("public ban revision conflict")

type PublicBan struct {
	IP        string            `json:"ip"`
	Reason    string            `json:"reason"`
	CreatedAt time.Time         `json:"created_at"`
	ExpiresAt time.Time         `json:"expires_at"`
	Details   *PublicBanDetails `json:"details,omitempty"`
}

type PublicBanRule struct {
	ID          int    `json:"id"`
	Description string `json:"description"`
}
type PublicBanDetails struct {
	CreatedAt time.Time       `json:"created_at"`
	Summary   string          `json:"summary"`
	Method    string          `json:"method"`
	Path      string          `json:"path"`
	Entry     string          `json:"entry"`
	Rules     []PublicBanRule `json:"rules,omitempty"`
}

// Kept outside the v1 ban policy so a previous server can still read policy on rollback.
const publicBanDetailsKey = "public_ip_ban_details_v1"

func readBanDetails(row *sql.Row) map[string]PublicBanDetails {
	var raw string
	result := map[string]PublicBanDetails{}
	if row.Scan(&raw) == nil && len(raw) <= 8*1024*1024 {
		_ = json.Unmarshal([]byte(raw), &result)
	}
	return result
}

type PublicBanSnapshot struct {
	Schema   int         `json:"schema"`
	Revision int64       `json:"revision"`
	Items    []PublicBan `json:"items"`
}

func banReason(reason string) bool {
	return reason == "waf" || reason == "login_failures" || reason == "request_rate" || reason == "manual"
}

func readPublicBans(row *sql.Row) (PublicBanSnapshot, string, error) {
	var raw string
	err := row.Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return PublicBanSnapshot{Schema: 1, Items: []PublicBan{}}, "", nil
	}
	if err != nil || len(raw) > 2*1024*1024 {
		return PublicBanSnapshot{}, "", ErrPublicBanUnavailable
	}
	var doc PublicBanSnapshot
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&doc) != nil || d.Decode(new(any)) != io.EOF || doc.Schema != 1 || doc.Revision < 1 || len(doc.Items) > 4096 {
		return PublicBanSnapshot{}, "", ErrPublicBanUnavailable
	}
	seen := map[string]bool{}
	for _, item := range doc.Items {
		ip, err := netip.ParseAddr(item.IP)
		maximum := time.Hour
		if item.Reason == "manual" {
			maximum = 365 * 24 * time.Hour
		}
		if err != nil || ip.Zone() != "" || ip.Unmap().String() != item.IP || seen[item.IP] || !banReason(item.Reason) || !registrationTime(&item.CreatedAt) || !registrationTime(&item.ExpiresAt) || !item.ExpiresAt.After(item.CreatedAt) || item.ExpiresAt.Sub(item.CreatedAt) > maximum {
			return PublicBanSnapshot{}, "", ErrPublicBanUnavailable
		}
		seen[item.IP] = true
	}
	return doc, raw, nil
}

// PublicPeerAllowed fails closed on malformed or unavailable persistent policy.
func (s *Service) PublicPeerAllowed(ip netip.Addr) (bool, error) {
	if !ip.IsValid() || ip.Zone() != "" {
		return false, ErrPublicBanUnavailable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	doc, _, err := readPublicBans(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBansKey))
	if err != nil {
		return false, err
	}
	for _, item := range doc.Items {
		if item.IP == ip.Unmap().String() && s.now().Before(item.ExpiresAt) {
			return false, nil
		}
	}
	return true, nil
}

func (s *Service) PublicBans(a authorization.Actor) (PublicBanSnapshot, error) {
	if !a.Active() || !a.Grants.ManagePublicBans() {
		return PublicBanSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.registrationActorCurrent(a); err != nil {
		return PublicBanSnapshot{}, err
	}
	doc, _, err := readPublicBans(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBansKey))
	active := []PublicBan{}
	details := readBanDetails(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBanDetailsKey))
	for _, item := range doc.Items {
		if s.now().Before(item.ExpiresAt) {
			if d, ok := details[item.IP]; ok && d.CreatedAt.Equal(item.CreatedAt) {
				item.Details = &d
			}
			active = append(active, item)
		}
	}
	doc.Items = active
	return doc, err
}

// BanPublicPeer is called only with the direct TCP peer and a fixed reason.
func (s *Service) BanPublicPeer(ip netip.Addr, reason string) error {
	return s.BanPublicPeerWithDetails(ip, reason, nil)
}

func (s *Service) BanPublicPeerWithDetails(ip netip.Addr, reason string, details *PublicBanDetails) error {
	if !ip.IsValid() || ip.Zone() != "" || !banReason(reason) || reason == "manual" {
		return ErrPublicBanUnavailable
	}
	return s.changePublicBan(nil, 0, ip.Unmap().String(), reason, 15*time.Minute, details)
}

// ManuallyBanPublicPeer is a revision-checked administrator action. Automatic
// detections must never shorten an existing manual block.
func (s *Service) ManuallyBanPublicPeer(a authorization.Actor, revision int64, ip string, duration time.Duration) error {
	parsed, err := netip.ParseAddr(ip)
	if !a.Active() || !a.Grants.Manage() {
		return ErrDenied
	}
	if err != nil || parsed.Zone() != "" || parsed.Unmap().String() != ip || duration < time.Minute || duration > 365*24*time.Hour {
		return ErrPublicBanUnavailable
	}
	return s.changePublicBan(&a, revision, ip, "manual", duration, nil)
}

func (s *Service) UnbanPublicPeer(a authorization.Actor, revision int64, ip string) error {
	if !a.Active() || !a.Grants.ManagePublicBans() {
		return ErrDenied
	}
	parsed, err := netip.ParseAddr(ip)
	if err != nil || parsed.Zone() != "" || parsed.Unmap().String() != ip {
		return ErrPublicBanUnavailable
	}
	return s.changePublicBan(&a, revision, ip, "", 0, nil)
}

func (s *Service) changePublicBan(a *authorization.Actor, revision int64, ip, reason string, duration time.Duration, details *PublicBanDetails) error {
	if details != nil && (len(details.Summary) > 512 || len(details.Path) > 512 || len(details.Method) > 16 || len(details.Entry) > 64 || len(details.Rules) > 12) {
		return ErrPublicBanUnavailable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if a != nil {
		if err := s.registrationActorCurrent(*a); err != nil {
			return err
		}
	}
	tx, err := s.db.Begin()
	if err != nil {
		return ErrPublicBanUnavailable
	}
	defer tx.Rollback()
	doc, previous, err := readPublicBans(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBansKey))
	if err != nil {
		return err
	}
	if a != nil && revision != doc.Revision {
		return ErrPublicBanConflict
	}
	now := s.now().UTC()
	oldDetails := readBanDetails(tx.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBanDetailsKey))
	nextDetails := map[string]PublicBanDetails{}
	items := []PublicBan{}
	for _, item := range doc.Items {
		if a == nil && item.IP == ip && item.Reason == "manual" && now.Before(item.ExpiresAt) {
			return nil
		}
		if item.IP != ip && now.Before(item.ExpiresAt) {
			items = append(items, item)
			if d, ok := oldDetails[item.IP]; ok && d.CreatedAt.Equal(item.CreatedAt) {
				nextDetails[item.IP] = d
			}
		}
	}
	actor, action := "system", "public.ban"
	if reason != "" {
		if len(items) >= 4096 {
			return ErrPublicBanUnavailable
		}
		items = append(items, PublicBan{IP: ip, Reason: reason, CreatedAt: now, ExpiresAt: now.Add(duration)})
		if details != nil {
			d := *details
			d.CreatedAt = now
			nextDetails[ip] = d
		}
		if a != nil {
			actor, action = a.ID, "public.manual_ban"
		}
	} else {
		actor, action = a.ID, "public.unban"
	}
	doc.Items = items
	doc.Revision++
	if doc.Revision < 1 {
		return ErrPublicBanUnavailable
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		return ErrPublicBanUnavailable
	}
	var result sql.Result
	if previous == "" {
		result, err = tx.Exec("INSERT INTO security_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO NOTHING", publicBansKey, string(raw))
	} else {
		result, err = tx.Exec("UPDATE security_settings SET value=? WHERE key=? AND value=?", string(raw), publicBansKey, previous)
	}
	if err != nil {
		return ErrPublicBanUnavailable
	}
	count, err := result.RowsAffected()
	if err != nil {
		return ErrPublicBanUnavailable
	}
	if count != 1 {
		return ErrPublicBanConflict
	}
	detailJSON, e := json.Marshal(nextDetails)
	if e != nil || len(detailJSON) > 8*1024*1024 {
		return ErrPublicBanUnavailable
	}
	if _, e = tx.Exec("INSERT INTO security_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", publicBanDetailsKey, string(detailJSON)); e != nil {
		return ErrPublicBanUnavailable
	}
	if auditTx(tx, actor, action, ip, "saved") != nil || tx.Commit() != nil {
		return ErrPublicBanUnavailable
	}
	return nil
}

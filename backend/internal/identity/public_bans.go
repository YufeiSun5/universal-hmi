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
	IP        string    `json:"ip"`
	Reason    string    `json:"reason"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}
type PublicBanSnapshot struct {
	Schema   int         `json:"schema"`
	Revision int64       `json:"revision"`
	Items    []PublicBan `json:"items"`
}

func banReason(reason string) bool {
	return reason == "waf" || reason == "login_failures" || reason == "request_rate"
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
		if err != nil || ip.Zone() != "" || ip.Unmap().String() != item.IP || seen[item.IP] || !banReason(item.Reason) || !registrationTime(&item.CreatedAt) || !registrationTime(&item.ExpiresAt) || !item.ExpiresAt.After(item.CreatedAt) || item.ExpiresAt.Sub(item.CreatedAt) > time.Hour {
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
	if !a.Active() || !a.Grants.Manage() {
		return PublicBanSnapshot{}, ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.registrationActorCurrent(a); err != nil {
		return PublicBanSnapshot{}, err
	}
	doc, _, err := readPublicBans(s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBansKey))
	active := []PublicBan{}
	for _, item := range doc.Items {
		if s.now().Before(item.ExpiresAt) {
			active = append(active, item)
		}
	}
	doc.Items = active
	return doc, err
}

// BanPublicPeer is called only with the direct TCP peer and a fixed reason.
func (s *Service) BanPublicPeer(ip netip.Addr, reason string) error {
	if !ip.IsValid() || ip.Zone() != "" || !banReason(reason) {
		return ErrPublicBanUnavailable
	}
	return s.changePublicBan(nil, 0, ip.Unmap().String(), reason)
}

func (s *Service) UnbanPublicPeer(a authorization.Actor, revision int64, ip string) error {
	if !a.Active() || !a.Grants.Manage() {
		return ErrDenied
	}
	parsed, err := netip.ParseAddr(ip)
	if err != nil || parsed.Zone() != "" || parsed.Unmap().String() != ip {
		return ErrPublicBanUnavailable
	}
	return s.changePublicBan(&a, revision, ip, "")
}

func (s *Service) changePublicBan(a *authorization.Actor, revision int64, ip, reason string) error {
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
	items := []PublicBan{}
	for _, item := range doc.Items {
		if item.IP != ip && now.Before(item.ExpiresAt) {
			items = append(items, item)
		}
	}
	actor, action := "system", "public.ban"
	if a == nil {
		if len(items) >= 4096 {
			return ErrPublicBanUnavailable
		}
		items = append(items, PublicBan{IP: ip, Reason: reason, CreatedAt: now, ExpiresAt: now.Add(15 * time.Minute)})
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
	if auditTx(tx, actor, action, ip, "saved") != nil || tx.Commit() != nil {
		return ErrPublicBanUnavailable
	}
	return nil
}

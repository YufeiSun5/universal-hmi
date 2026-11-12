package identity

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestPublicBansPersistExpireAndRecover(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	u, err := s.Bootstrap("owner", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	ip := netip.MustParseAddr("192.0.2.1")
	if allowed, err := s.PublicPeerAllowed(ip); err != nil || !allowed {
		t.Fatal(allowed, err)
	}
	if err := s.BanPublicPeerWithDetails(ip, "waf", &PublicBanDetails{Summary: "repeated rejection", Entry: "内网入口", Method: "GET", Path: "/total-reports/index.html", Rules: []PublicBanRule{{ID: 931130, Description: "远程文件包含特征"}}}); err != nil {
		t.Fatal(err)
	}
	if allowed, err := s.PublicPeerAllowed(ip); err != nil || allowed {
		t.Fatal(allowed, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if allowed, err := s.PublicPeerAllowed(ip); err != nil || allowed {
		t.Fatal("restart lost ban", allowed, err)
	}
	a := s.Actor(u)
	doc, err := s.PublicBans(a)
	if err != nil || len(doc.Items) != 1 || doc.Items[0].Details == nil || doc.Items[0].Details.Rules[0].ID != 931130 {
		t.Fatal(doc, err)
	}
	if err := s.UnbanPublicPeer(a, doc.Revision-1, ip.String()); !errors.Is(err, ErrPublicBanConflict) {
		t.Fatal(err)
	}
	if err := s.UnbanPublicPeer(a, doc.Revision, ip.String()); err != nil {
		t.Fatal(err)
	}
	if allowed, err := s.PublicPeerAllowed(ip); err != nil || !allowed {
		t.Fatal("manual recovery failed", allowed, err)
	}
	if err := s.BanPublicPeer(ip, "login_failures"); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(16 * time.Minute)
	s.now = func() time.Time { return now }
	if allowed, err := s.PublicPeerAllowed(ip); err != nil || !allowed {
		t.Fatal("expiry failed", allowed, err)
	}
	if _, err := s.db.Exec("UPDATE security_settings SET value=? WHERE key=?", `{"schema":1,"revision":1,"items":[{"ip":"invalid"}]}`, publicBansKey); err != nil {
		t.Fatal(err)
	}
	if allowed, err := s.PublicPeerAllowed(ip); !errors.Is(err, ErrPublicBanUnavailable) || allowed {
		t.Fatal("corruption failed open", allowed, err)
	}
}

func TestUnbanPermissionAndRollbackCompatiblePolicy(t *testing.T) {
	s, u := fixture(t)
	admin := s.Actor(u)
	manager, e := s.Change(admin, "", Change{Username: "unban-only", Password: testPassword, Grants: authorization.Grants{Roles: []string{"viewer"}, PublicBanManagement: true}})
	if e != nil {
		t.Fatal(e)
	}
	a := s.Actor(manager)
	ip := netip.MustParseAddr("192.0.2.8")
	if e = s.BanPublicPeerWithDetails(ip, "waf", &PublicBanDetails{Summary: "three rejections", Path: "/total-reports/"}); e != nil {
		t.Fatal(e)
	}
	var raw string
	if e = s.db.QueryRow("SELECT value FROM security_settings WHERE key=?", publicBansKey).Scan(&raw); e != nil || strings.Contains(raw, "details") {
		t.Fatal("old policy schema changed", e, raw)
	}
	d, e := s.PublicBans(a)
	if e != nil || len(d.Items) != 1 || d.Items[0].Details == nil {
		t.Fatal(d, e)
	}
	if e = s.ManuallyBanPublicPeer(a, d.Revision, ip.String(), time.Hour); !errors.Is(e, ErrDenied) {
		t.Fatal("unban grant allowed manual ban", e)
	}
	if e = s.UnbanPublicPeer(a, d.Revision, ip.String()); e != nil {
		t.Fatal(e)
	}
	if e = s.BanPublicPeer(ip, "login_failures"); e != nil {
		t.Fatal(e)
	}
	d, e = s.PublicBans(a)
	if e != nil || d.Items[0].Details != nil {
		t.Fatal("previous ban details leaked into new ban", d, e)
	}
}

func TestManualBanRevisionDurationAndAutomaticDetectionCannotShorten(t *testing.T) {
	s, u := fixture(t)
	a := s.Actor(u)
	ip := netip.MustParseAddr("203.0.113.7")
	doc, e := s.PublicBans(a)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.ManuallyBanPublicPeer(a, doc.Revision, ip.String(), 365*24*time.Hour); e != nil {
		t.Fatal(e)
	}
	doc, e = s.PublicBans(a)
	if e != nil || len(doc.Items) != 1 || doc.Items[0].Reason != "manual" {
		t.Fatal(doc, e)
	}
	expires := doc.Items[0].ExpiresAt
	if e = s.ManuallyBanPublicPeer(a, doc.Revision-1, ip.String(), time.Hour); !errors.Is(e, ErrPublicBanConflict) {
		t.Fatal(e)
	}
	if e = s.BanPublicPeer(ip, "waf"); e != nil {
		t.Fatal(e)
	}
	next, e := s.PublicBans(a)
	if e != nil || !next.Items[0].ExpiresAt.Equal(expires) || next.Revision != doc.Revision {
		t.Fatal("automatic detection shortened manual ban", next, e)
	}
	if e = s.ManuallyBanPublicPeer(a, doc.Revision, ip.String(), 366*24*time.Hour); e == nil {
		t.Fatal("unbounded ban")
	}
	if e = s.UnbanPublicPeer(a, doc.Revision, ip.String()); e != nil {
		t.Fatal(e)
	}
	if allowed, e := s.PublicPeerAllowed(ip); e != nil || !allowed {
		t.Fatal(allowed, e)
	}
}

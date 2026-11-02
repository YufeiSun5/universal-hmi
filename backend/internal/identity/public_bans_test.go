package identity

import (
	"errors"
	"net/netip"
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
	if err := s.BanPublicPeer(ip, "waf"); err != nil {
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
	if err != nil || len(doc.Items) != 1 {
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

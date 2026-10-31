package identity

import (
	"encoding/base32"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

func TestPostgresMFAReplayRecoveryAndRestart(t *testing.T) {
	path := os.Getenv("HMI_PG_TEST_CONFIG")
	if path == "" {
		t.Skip("real PostgreSQL test configuration required")
	}
	dsn, e := persistence.ConfigFile(path)
	if e != nil {
		t.Fatal(e)
	}
	admin, e := persistence.Open("", dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer admin.Close()
	schema := fmt.Sprintf("hmi_mfa_%d", time.Now().UnixNano())
	if _, e = admin.Exec("CREATE SCHEMA " + schema); e != nil {
		t.Fatal(e)
	}
	defer func() {
		if _, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE"); e != nil {
			t.Error(e)
		}
	}()
	u, e := url.Parse(dsn)
	if e != nil {
		t.Fatal(e)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	dsn = u.String()
	dir := t.TempDir()
	s, e := OpenDatabase(dir, dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer func() { s.Close() }()
	owner, e := s.Bootstrap("owner", testPassword)
	if e != nil {
		t.Fatal(e)
	}
	at := time.Unix(2000000000, 0)
	s.now = func() time.Time { return at }
	_, session, _, e := s.Login("owner", testPassword, "one", true)
	if e != nil {
		t.Fatal(e)
	}
	secret, e := s.BeginMFA(s.Actor(owner), testPassword)
	if e != nil {
		t.Fatal(e)
	}
	raw, e := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if e != nil {
		t.Fatal(e)
	}
	codes, e := s.ConfirmMFA(s.Actor(owner), totp(raw, at.Unix()/30, 6), session.ID)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, _, e = s.Login("owner", testPassword, "replay", true, totp(raw, at.Unix()/30, 6)); e == nil {
		t.Fatal("TOTP replay accepted")
	}
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	s, e = OpenDatabase(dir, dsn)
	if e != nil {
		t.Fatal(e)
	}
	s.now = func() time.Time { return at.Add(30 * time.Second) }
	if _, _, _, e = s.Login("owner", testPassword, "restart", true, totp(raw, (at.Unix()+30)/30, 6)); e != nil {
		t.Fatal(e)
	}
	if _, _, _, e = s.Login("owner", testPassword, "recovery", true, codes[0]); e != nil {
		t.Fatal(e)
	}
	if _, _, _, e = s.Login("owner", testPassword, "reused", true, codes[0]); e == nil {
		t.Fatal("recovery code reused")
	}
}

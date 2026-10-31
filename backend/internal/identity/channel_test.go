package identity

import (
	"crypto/sha256"
	"encoding/base32"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestSessionChannelsIsolateAndPreserveLegacy(t *testing.T) {
	s, u := fixture(t)
	now := time.Now()
	s.now = func() time.Time { return now }
	_, local, localToken, err := s.Login(u.Username, testPassword, "local", true)
	if err != nil {
		t.Fatal(err)
	}
	_, public, publicToken, err := s.LoginChannel(u.Username, testPassword, "public", true, "public:web")
	if err != nil {
		t.Fatal(err)
	}
	if local.Channel != "" || public.Channel != "public:web" {
		t.Fatalf("channels local=%q public=%q", local.Channel, public.Channel)
	}
	now = now.Add(time.Minute)
	for _, test := range []struct{ token, channel string }{{localToken, "public:web"}, {publicToken, ""}, {publicToken, "local"}, {publicToken, "public:android"}, {localToken, "PUBLIC:WEB"}} {
		user, session, err := s.ResolveChannel(test.token, true, test.channel)
		if !errors.Is(err, ErrLogin) || user.ID != "" || session.ID != "" {
			t.Fatalf("cross-channel identity exposed: %+v %+v %v", user, session, err)
		}
	}
	for _, test := range []struct {
		token, channel string
		last           time.Time
	}{{localToken, "", local.Last}, {publicToken, "public:web", public.Last}} {
		_, session, err := s.ResolveChannel(test.token, false, test.channel)
		if err != nil || !session.Last.Equal(test.last) {
			t.Fatalf("wrong channel touched/revoked valid session: %+v %v", session, err)
		}
	}
	if _, _, err := s.Resolve(publicToken, false); !errors.Is(err, ErrLogin) {
		t.Fatal("legacy Resolve accepted public token")
	}
	_, session, err := s.ResolveChannel(publicToken, true, "public:web")
	if err != nil || !session.Last.Equal(now) {
		t.Fatal("same-channel touch failed")
	}
	// Decode a historical Session representation with no channel field.
	var legacy Session
	if err := json.Unmarshal([]byte(`{"id":"legacy","user_id":"`+u.ID+`"}`), &legacy); err != nil {
		t.Fatal(err)
	}
	legacy.Version = u.Version
	legacy.Started = now
	legacy.Last = now
	legacy.Expires = now.Add(time.Hour)
	s.sessions[sha256.Sum256([]byte("legacy-token"))] = legacy
	if _, _, err := s.Resolve("legacy-token", false); err != nil {
		t.Fatal("legacy local session rejected", err)
	}
	if _, _, err := s.ResolveChannel("legacy-token", false, "public:web"); !errors.Is(err, ErrLogin) {
		t.Fatal("legacy session acquired public access")
	}
	for _, channel := range []string{"local", "public:android", "public:web ", "PUBLIC:WEB", "arbitrary"} {
		if _, _, token, err := s.LoginChannel(u.Username, testPassword, "invalid", true, channel); !errors.Is(err, ErrLogin) || token != "" {
			t.Fatalf("unsupported login channel %q", channel)
		}
	}

}

func TestPublicChannelMFAExpiryAndReopen(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	u, err := s.Bootstrap("owner", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(2000000000, 0)
	s.now = func() time.Time { return now }
	_, sess, token, err := s.LoginChannel(u.Username, testPassword, "enroll", true, "public:web")
	if err != nil {
		t.Fatal(err)
	}
	actor := s.Actor(u)
	actor.Valid = func() bool { _, _, err := s.ResolveChannel(token, false, "public:web"); return err == nil }
	secret, err := s.BeginMFA(actor, testPassword)
	if err != nil {
		t.Fatal(err)
	}
	bytes, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if err != nil {
		t.Fatal(err)
	}
	recovery, err := s.ConfirmMFA(actor, totp(bytes, now.Unix()/30, 6), sess.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, verified, err := s.ResolveChannel(token, false, "public:web")
	if err != nil || !verified.MFA || verified.Channel != "public:web" {
		t.Fatalf("MFA lost channel: %+v %v", verified, err)
	}
	if _, _, err := s.Resolve(token, false); !errors.Is(err, ErrLogin) {
		t.Fatal("MFA promoted public session to local")
	}
	// Persisted account/MFA survives reopening, but existing memory-only sessions do not.
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return now }
	if _, _, err := s.ResolveChannel(token, false, "public:web"); !errors.Is(err, ErrLogin) {
		t.Fatal("reopen unexpectedly retained session")
	}
	if _, _, err := s.Resolve(token, false); !errors.Is(err, ErrLogin) {
		t.Fatal("reopen converted old token to local")
	}
	_, fresh, newToken, err := s.LoginChannel(u.Username, testPassword, "reopened", true, "public:web", recovery[0])
	if err != nil || !fresh.MFA || fresh.Channel != "public:web" {
		t.Fatalf("persistent MFA login: %+v %v", fresh, err)
	}
	now = now.Add(31 * time.Minute)
	if _, _, err := s.ResolveChannel(newToken, false, "public:web"); !errors.Is(err, ErrLogin) {
		t.Fatal("idle public session survived")
	}
	_, _, absolute, err := s.LoginChannel(u.Username, testPassword, "absolute", true, "public:web", recovery[1])
	if err != nil {
		t.Fatal(err)
	}
	key := sha256.Sum256([]byte(absolute))
	v := s.sessions[key]
	now = v.Expires.Add(time.Second)
	v.Last = now
	s.sessions[key] = v
	if _, _, err := s.ResolveChannel(absolute, false, "public:web"); !errors.Is(err, ErrLogin) {
		t.Fatal("absolute public session survived despite recent touch")
	}
}

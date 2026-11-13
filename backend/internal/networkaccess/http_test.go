package networkaccess

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHTTPDefaultLegacyHTTPSAndNoCertificate(t *testing.T) {
	s := fixture(t)
	v, err := s.Snapshot()
	if err != nil || v.Protocol != "http" {
		t.Fatal(v, err)
	}
	v, err = s.Save(Input{Enabled: true, Address: "192.168.50.5", Port: 18443})
	if err != nil || v.CertificatePEM != "" || v.Origin != "http://192.168.50.5:18443" {
		t.Fatal(v, err)
	}
	if _, err = os.Stat(filepath.Join(s.dir, "lan-certificates")); !os.IsNotExist(err) {
		t.Fatal("HTTP generated certificates", err)
	}
	c, tlsConfig, err := s.Deployment()
	if err != nil || !c.Enabled || tlsConfig != nil {
		t.Fatal(c, err)
	}
	// An older UI must retain the saved protocol when it omits this new field.
	v, err = s.Save(Input{Revision: v.Revision, Enabled: true, Address: c.Address, Port: c.Port})
	if err != nil || v.Protocol != "http" {
		t.Fatal(v, err)
	}
	if _, err = s.Save(Input{Protocol: "ftp", Revision: v.Revision, Address: c.Address, Port: c.Port}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(s.dir, "lan-access.json"), []byte(`{"schema":1,"revision":2,"enabled":false,"address":"192.168.50.5","port":18443}`), 0600); err != nil {
		t.Fatal(err)
	}
	v, err = s.Snapshot()
	if err != nil || v.Protocol != "https" {
		t.Fatal("legacy transport changed", v, err)
	}
}

func TestLiveProtocolSwitchSamePortAndHTTPRecovery(t *testing.T) {
	s, ip := liveFixture(t)
	v, err := s.Save(Input{Protocol: "http", Enabled: true, Address: ip, Port: freeLANPort(t, ip)})
	if err != nil {
		t.Fatal(err)
	}
	for _, protocol := range []string{"http", "https", "http"} {
		v, err = s.Save(Input{Protocol: protocol, Revision: v.Revision, Enabled: true, Address: ip, Port: v.Port})
		if err != nil {
			t.Fatal(err)
		}
		v, err = s.Apply(v.Revision)
		if err != nil || !v.Running || v.Phase != "applied" || v.RestartRequired || !strings.HasPrefix(v.RunningOrigin, protocol+"://") {
			t.Fatal(v, err)
		}
		assertLive(t, s, v.RunningOrigin, 200)
	}
	original := s.factory
	s.EnableApply(func(c Config) (http.Handler, error) {
		if c.Scheme() == "https" {
			return nil, errors.New("injected startup failure")
		}
		return original(c)
	})
	v, err = s.Save(Input{Protocol: "https", Revision: v.Revision, Enabled: true, Address: ip, Port: v.Port})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || !v.Running || v.Recovery != "previous_restored" || !strings.HasPrefix(v.RunningOrigin, "http://") {
		t.Fatal(v, err)
	}
	assertLive(t, s, v.RunningOrigin, 200)
}

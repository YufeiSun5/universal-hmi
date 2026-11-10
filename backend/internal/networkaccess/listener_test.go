package networkaccess

import (
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func liveFixture(t *testing.T) (*Service, string) {
	t.Helper()
	addresses, err := LocalAddresses()
	if err != nil || len(addresses) == 0 {
		t.Skip("real LAN listener test requires assigned private IPv4")
	}
	s := New(t.TempDir(), "https://public.example:9090", true, "")
	s.EnableApply(func(c Config) (http.Handler, error) {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-Test-Session") != "preserved" {
				w.WriteHeader(401)
				return
			}
			io.WriteString(w, "same application session")
		}), nil
	})
	t.Cleanup(func() { s.Close() })
	return s, addresses[0].IP
}

func freeLANPort(t *testing.T, ip string) int {
	t.Helper()
	l, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func assertLive(t *testing.T, s *Service, origin string, status int) {
	t.Helper()
	// The control plane has already verified the pinned certificate. This client
	// exercises authentication preservation across changes and old-address loss.
	tr := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: time.Second}
	req, _ := http.NewRequest("GET", origin+"/application", nil)
	if status == 200 {
		req.Header.Set("X-Test-Session", "preserved")
	}
	resp, err := client.Do(req)
	if status == 0 {
		if err == nil {
			resp.Body.Close()
			t.Fatal("old listener is still serving")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != status {
		t.Fatal(resp.StatusCode)
	}
}

func TestLiveApplyPortToggleAndSessionPreservation(t *testing.T) {
	s, ip := liveFixture(t)
	v, err := s.Save(Input{false, 0, true, ip, freeLANPort(t, ip)})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || v.Phase != "applied" || !v.Running || v.RestartRequired {
		t.Fatal(v, err)
	}
	first := v.RunningOrigin
	fingerprint := v.Fingerprint
	assertLive(t, s, first, 401)
	assertLive(t, s, first, 200)
	v, err = s.Save(Input{false, v.Revision, true, ip, freeLANPort(t, ip)})
	if err != nil {
		t.Fatal(err)
	}
	if !v.RestartRequired || v.RunningOrigin != first {
		t.Fatal("save changed actual listener", v)
	}
	assertLive(t, s, first, 200)
	v, err = s.Apply(v.Revision)
	if err != nil || v.Phase != "applied" || v.Fingerprint != fingerprint {
		t.Fatal(v, err)
	}
	assertLive(t, s, first, 0)
	assertLive(t, s, v.RunningOrigin, 200)
	second := v.RunningOrigin
	v, err = s.Save(Input{false, v.Revision, false, ip, v.Port})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || v.Running || v.RestartRequired || v.Phase != "applied" {
		t.Fatal(v, err)
	}
	assertLive(t, s, second, 0)
}

func TestLiveOccupiedPortAndCertificateFailureKeepOriginal(t *testing.T) {
	s, ip := liveFixture(t)
	v, err := s.Save(Input{false, 0, true, ip, freeLANPort(t, ip)})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil {
		t.Fatal(err)
	}
	first := v.RunningOrigin
	foreign, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
	if err != nil {
		t.Fatal(err)
	}
	defer foreign.Close()
	v, err = s.Save(Input{false, v.Revision, true, ip, foreign.Addr().(*net.TCPAddr).Port})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || v.ErrorCode != "port_in_use" || v.Recovery != "previous_unchanged" || v.RunningOrigin != first || !v.RestartRequired {
		t.Fatal(v, err)
	}
	assertLive(t, s, first, 200)
	connection, err := net.DialTimeout("tcp", foreign.Addr().String(), time.Second)
	if err != nil {
		t.Fatal("foreign listener affected", err)
	}
	connection.Close()
	c, _, err := s.Deployment()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(s.dir, "lan-certificates", c.Certificate), []byte("invalid certificate"), 0600); err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || v.ErrorCode != "certificate_failed" || v.RunningOrigin != first {
		t.Fatal(v, err)
	}
	assertLive(t, s, first, 200)
}

func TestLiveSameAddressStartupFailureRestoresAndSerializes(t *testing.T) {
	s, ip := liveFixture(t)
	v, err := s.Save(Input{false, 0, true, ip, freeLANPort(t, ip)})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil {
		t.Fatal(err)
	}
	first := v.RunningOrigin
	original := s.factory
	s.EnableApply(func(c Config) (http.Handler, error) {
		if c.Revision == 2 {
			return nil, fmt.Errorf("injected startup failure")
		}
		return original(c)
	})
	v, err = s.Save(Input{false, v.Revision, true, ip, v.Port})
	if err != nil {
		t.Fatal(err)
	}
	v, err = s.Apply(v.Revision)
	if err != nil || v.ErrorCode != "start_failed" || v.Recovery != "previous_restored" || !v.Running {
		t.Fatal(v, err)
	}
	assertLive(t, s, first, 200)
	s.opMu.Lock()
	_, err = s.Apply(v.Revision)
	s.opMu.Unlock()
	if !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	if _, err = s.Apply(v.Revision - 1); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	// The old endpoint's handler and certificate remain usable after failed apply.
	assertLive(t, s, first, 200)
}

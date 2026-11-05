package networkaccess

import (
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// HandlerFactory is supplied by the composition root. Authentication, IP
// approval and read-only authorization remain in the existing server adapters.
type HandlerFactory func(Config) (http.Handler, error)

type liveListener struct {
	config   Config
	server   *http.Server
	listener net.Listener
	done     chan struct{}
}

func (s *Service) EnableApply(factory HandlerFactory) {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	s.factory = factory
	s.mu.Unlock()
}

func (s *Service) state(phase, code, message, recovery string) {
	s.mu.Lock()
	s.phase, s.errorCode, s.statusError, s.recovery = phase, code, message, recovery
	s.portOwners = nil
	s.mu.Unlock()
}

func failureCode(err error) string {
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "address already in use"), strings.Contains(text, "only one usage"), strings.Contains(text, "10048"):
		return "port_in_use"
	case errors.Is(err, os.ErrPermission), strings.Contains(text, "permission"), strings.Contains(text, "access is denied"), strings.Contains(text, "10013"):
		return "permission_denied"
	case strings.Contains(text, "assigned"), strings.Contains(text, "invalid lan"), strings.Contains(text, "requested address"), strings.Contains(text, "10049"):
		return "invalid_address"
	case strings.Contains(text, "certificate"), strings.Contains(text, "pem"), strings.Contains(text, "x509"), strings.Contains(text, "private key"):
		return "certificate_failed"
	default:
		return "start_failed"
	}
}

func (s *Service) open(c Config, config *tls.Config) (*liveListener, error) {
	handler, err := s.factory(c)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(c.Address, fmt.Sprint(c.Port)))
	if err != nil {
		return nil, err
	}
	// A random, short-lived probe proves this exact TLS listener is serving.
	// It returns no application data and is removed before Apply succeeds.
	token := make([]byte, 32)
	if _, err = rand.Read(token); err != nil {
		listener.Close()
		return nil, err
	}
	probePath := fmt.Sprintf("/local-listener-probe/%x", token)
	probeDone := make(chan struct{})
	wrapped := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-probeDone:
		default:
			if r.Method == "GET" && r.URL.Path == probePath {
				w.WriteHeader(204)
				return
			}
		}
		handler.ServeHTTP(w, r)
	})
	live := &liveListener{config: c, listener: listener, done: make(chan struct{}), server: &http.Server{Handler: wrapped, MaxHeaderBytes: 32768, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}}
	go func() {
		defer close(live.done)
		err := live.server.Serve(tls.NewListener(listener, config))
		if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			s.mu.Lock()
			if s.live == live {
				s.started = false
				s.phase = "failed"
				s.errorCode = "listener_failed"
				s.statusError = err.Error()
			}
			s.mu.Unlock()
		}
	}()
	s.state("verifying", "", "", "")
	leaf, err := x509.ParseCertificate(config.Certificates[0].Certificate[0])
	if err == nil {
		pool := x509.NewCertPool()
		pool.AddCert(leaf)
		transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}}
		client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
		var response *http.Response
		response, err = client.Get(c.Origin() + probePath)
		if err == nil {
			response.Body.Close()
			if response.StatusCode != 204 {
				err = fmt.Errorf("listener verification returned %d", response.StatusCode)
			}
		}
		transport.CloseIdleConnections()
	}
	close(probeDone)
	if err != nil {
		live.server.Close()
		<-live.done
		return nil, err
	}
	return live, nil
}

func (s *Service) stop(live *liveListener) error {
	if live == nil {
		return nil
	}
	s.state("stopping", "", "", "")
	// Closing this optional listener terminates its SSE connections. Other
	// listeners, identity sessions and acquisition are deliberately independent.
	if err := live.server.Close(); err != nil {
		return err
	}
	select {
	case <-live.done:
		return nil
	case <-time.After(5 * time.Second):
		return fmt.Errorf("listener stop timeout")
	}
}

// Apply serializes all changes with Save; the requested revision cannot drift
// during preparation/verification. A failed new address keeps the old listener.
func (s *Service) Apply(revision int64) (Snapshot, error) {
	if !s.opMu.TryLock() {
		return Snapshot{}, ErrBusy
	}
	defer s.opMu.Unlock()
	return s.apply(revision)
}

var ErrBusy = errors.New("network operation in progress")

func (s *Service) apply(revision int64) (Snapshot, error) {
	s.mu.Lock()
	c, err := s.load()
	available := s.factory != nil
	old := s.live
	s.mu.Unlock()
	if err != nil {
		return Snapshot{}, err
	}
	if revision >= 0 && c.Revision != revision {
		return Snapshot{}, ErrConflict
	}
	if !available {
		return Snapshot{}, fmt.Errorf("listener reload is unavailable on this host")
	}
	s.state("preparing", "", "", "")
	c, config, err := s.Deployment()
	if err != nil {
		s.state("failed", failureCode(err), err.Error(), "previous_unchanged")
		return s.Snapshot()
	}
	if old != nil && old.config == c {
		s.state("applied", "", "", "")
		return s.Snapshot()
	}
	oldStopped := false
	if old != nil && (!c.Enabled || old.config.Origin() == c.Origin()) {
		if err = s.stop(old); err != nil {
			s.state("failed", "stop_timeout", err.Error(), "unverified")
			return s.Snapshot()
		}
		oldStopped = true
		s.mu.Lock()
		s.live = nil
		s.started = false
		s.mu.Unlock()
	}
	var next *liveListener
	if c.Enabled {
		s.state("starting", "", "", "")
		next, err = s.open(c, config)
	}
	if err != nil {
		recovery := "previous_unchanged"
		message := err.Error()
		code := failureCode(err)
		if oldStopped {
			s.state("restoring", code, message, "restoring")
			pair, _, restoreErr := s.material(old.config)
			var restored *liveListener
			if restoreErr == nil {
				restored, restoreErr = s.open(old.config, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}})
			}
			if restoreErr == nil {
				s.mu.Lock()
				s.live = restored
				s.running = old.config
				s.started = true
				s.mu.Unlock()
				recovery = "previous_restored"
			} else {
				recovery = "restore_failed"
				message += "; restore: " + restoreErr.Error()
			}
		}
		s.state("failed", code, message, recovery)
		if code == "port_in_use" {
			owners := describePortOwners(c.Address, c.Port)
			s.mu.Lock()
			s.portOwners = owners
			s.mu.Unlock()
		}
		return s.Snapshot()
	}
	if old != nil && !oldStopped {
		if err = s.stop(old); err != nil {
			if next != nil {
				_ = s.stop(next)
			}
			s.state("failed", "stop_timeout", err.Error(), "unverified")
			return s.Snapshot()
		}
	}
	s.mu.Lock()
	s.live = next
	s.running = c
	s.started = next != nil
	s.mu.Unlock()
	s.state("applied", "", "", "")
	if raw, err := json.Marshal(c); err != nil {
		s.state("applied", "recovery_checkpoint_failed", "监听已生效，但无法生成配置恢复点", "")
	} else if err = atomicWrite(filepath.Join(s.dir, "lan-last-working.json"), raw); err != nil {
		s.state("applied", "recovery_checkpoint_failed", "监听已生效，但无法保存配置恢复点", "")
	}
	return s.Snapshot()
}

func (s *Service) Close() error {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	live := s.live
	s.mu.Unlock()
	err := s.stop(live)
	if err == nil {
		s.mu.Lock()
		s.live = nil
		s.started = false
		s.mu.Unlock()
	}
	return err
}

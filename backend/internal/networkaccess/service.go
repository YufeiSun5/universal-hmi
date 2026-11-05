// Package networkaccess owns the optional, project-local LAN Web deployment.
// It never changes the public listener, public certificate or access policy.
package networkaccess

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var ErrConflict = errors.New("LAN configuration changed")
var ErrInvalid = errors.New("invalid LAN configuration")

type Config struct {
	Schema      int    `json:"schema"`
	Revision    int64  `json:"revision"`
	Enabled     bool   `json:"enabled"`
	Address     string `json:"address"`
	Port        int    `json:"port"`
	Certificate string `json:"certificate,omitempty"`
	PrivateKey  string `json:"private_key,omitempty"`
}
type Input struct {
	Revision int64  `json:"revision"`
	Enabled  bool   `json:"enabled"`
	Address  string `json:"address"`
	Port     int    `json:"port"`
}
type Address struct {
	IP        string `json:"ip"`
	Interface string `json:"interface"`
}
type Snapshot struct {
	Input
	Addresses       []Address   `json:"addresses"`
	Origin          string      `json:"origin"`
	PublicOrigin    string      `json:"public_origin"`
	PublicEnabled   bool        `json:"public_enabled"`
	Running         bool        `json:"running"`
	RunningOrigin   string      `json:"running_origin"`
	RestartRequired bool        `json:"restart_required"`
	StatusError     string      `json:"status_error,omitempty"`
	Fingerprint     string      `json:"fingerprint,omitempty"`
	Expires         time.Time   `json:"expires,omitempty"`
	CertificatePEM  string      `json:"certificate_pem,omitempty"`
	ApplyAvailable  bool        `json:"apply_available"`
	Phase           string      `json:"phase"`
	ErrorCode       string      `json:"error_code,omitempty"`
	Recovery        string      `json:"recovery,omitempty"`
	PortOwners      []PortOwner `json:"port_owners,omitempty"`
}
type PortOwner struct {
	PID     int    `json:"pid"`
	Program string `json:"program"`
}
type Service struct {
	opMu          sync.Mutex
	mu            sync.Mutex
	dir           string
	webRoot       string
	running       Config
	started       bool
	statusError   string
	publicOrigin  string
	publicEnabled bool
	addresses     func() ([]Address, error)
	live          *liveListener
	factory       HandlerFactory
	phase         string
	errorCode     string
	recovery      string
	portOwners    []PortOwner
}

func New(dir, publicOrigin string, publicEnabled bool, webRoot string) *Service {
	return &Service{dir: dir, publicOrigin: publicOrigin, publicEnabled: publicEnabled, webRoot: webRoot, addresses: LocalAddresses}
}
func IsPrivateIPv4(text string) bool {
	ip, e := netip.ParseAddr(text)
	return e == nil && ip.Is4() && ip.IsPrivate()
}
func LocalAddresses() ([]Address, error) {
	interfaces, e := net.Interfaces()
	if e != nil {
		return nil, e
	}
	result := []Address{}
	for _, i := range interfaces {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, e := i.Addrs()
		if e != nil {
			return nil, e
		}
		for _, a := range addresses {
			prefix, e := netip.ParsePrefix(a.String())
			if e == nil && IsPrivateIPv4(prefix.Addr().String()) {
				result = append(result, Address{prefix.Addr().String(), i.Name})
			}
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].IP < result[j].IP })
	return result, nil
}
func (c Config) Origin() string {
	if c.Address == "" {
		return ""
	}
	return "https://" + net.JoinHostPort(c.Address, strconv.Itoa(c.Port))
}
func (s *Service) load() (Config, error) {
	c := Config{Schema: 1, Port: 18443}
	raw, e := os.ReadFile(filepath.Join(s.dir, "lan-access.json"))
	if os.IsNotExist(e) {
		addresses, err := s.addresses()
		if err != nil {
			return c, err
		}
		if len(addresses) > 0 {
			c.Address = addresses[0].IP
		}
		return c, nil
	}
	if e != nil {
		return c, e
	}
	if e = json.Unmarshal(raw, &c); e != nil {
		return c, e
	}
	if c.Schema != 1 || c.Revision < 0 || c.Port < 1024 || c.Port > 65535 || c.Enabled && !IsPrivateIPv4(c.Address) {
		return c, ErrInvalid
	}
	return c, nil
}
func (s *Service) material(c Config) (tls.Certificate, *x509.Certificate, error) {
	var pair tls.Certificate
	// Only files generated in this module's private directory may be read.
	if filepath.Base(c.Certificate) != c.Certificate || filepath.Base(c.PrivateKey) != c.PrivateKey || c.Certificate == "" || c.PrivateKey == "" {
		return pair, nil, ErrInvalid
	}
	pair, e := tls.LoadX509KeyPair(filepath.Join(s.dir, "lan-certificates", c.Certificate), filepath.Join(s.dir, "lan-certificates", c.PrivateKey))
	if e != nil {
		return pair, nil, e
	}
	leaf, e := x509.ParseCertificate(pair.Certificate[0])
	if e != nil {
		return pair, nil, e
	}
	if e = leaf.VerifyHostname(c.Address); e != nil {
		return pair, nil, e
	}
	if time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return pair, nil, ErrInvalid
	}
	return pair, leaf, nil
}
func (s *Service) Deployment() (Config, *tls.Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return c, nil, e
	}
	if !c.Enabled {
		return c, nil, nil
	}
	addresses, e := s.addresses()
	if e != nil {
		return c, nil, e
	}
	found := false
	for _, a := range addresses {
		found = found || a.IP == c.Address
	}
	if !found {
		return c, nil, fmt.Errorf("configured LAN IP is not assigned to this computer")
	}
	pair, _, e := s.material(c)
	if e != nil {
		return c, nil, fmt.Errorf("certificate: %w", e)
	}
	return c, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}}, nil
}
func (s *Service) SetRunning(c Config, running bool, statusError string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.running = c
	s.started = running
	s.statusError = statusError
}
func (s *Service) Snapshot() (Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshot()
}
func (s *Service) snapshot() (Snapshot, error) {
	c, e := s.load()
	if e != nil {
		return Snapshot{}, e
	}
	addresses, e := s.addresses()
	if e != nil {
		return Snapshot{}, e
	}
	return s.snapshotFor(c, addresses), nil
}
func (s *Service) snapshotFor(c Config, addresses []Address) Snapshot {
	out := Snapshot{Input: Input{c.Revision, c.Enabled, c.Address, c.Port}, Addresses: addresses, Origin: c.Origin(), PublicOrigin: s.publicOrigin, PublicEnabled: s.publicEnabled, Running: s.started, StatusError: s.statusError}
	out.ApplyAvailable, out.Phase, out.ErrorCode, out.Recovery = s.factory != nil, s.phase, s.errorCode, s.recovery
	out.PortOwners = append([]PortOwner(nil), s.portOwners...)
	if s.started {
		out.RunningOrigin = s.running.Origin()
	}
	out.RestartRequired = c.Enabled != s.started || c.Enabled && (c.Address != s.running.Address || c.Port != s.running.Port || c.Certificate != s.running.Certificate)
	if c.Certificate != "" {
		_, leaf, e := s.material(c)
		if e != nil {
			out.StatusError = "内网证书不可用，请重新保存配置后应用"
			out.RestartRequired = c.Enabled || out.RestartRequired
		} else {
			out.Fingerprint = fmt.Sprintf("%x", sha256.Sum256(leaf.Raw))
			out.Expires = leaf.NotAfter
			out.CertificatePEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw}))
		}
	}
	return out
}
func (s *Service) Save(in Input) (Snapshot, error) {
	s.opMu.Lock()
	defer s.opMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return Snapshot{}, e
	}
	if in.Revision != c.Revision {
		return Snapshot{}, ErrConflict
	}
	if in.Port < 1024 || in.Port > 65535 || !IsPrivateIPv4(in.Address) {
		return Snapshot{}, ErrInvalid
	}
	addresses, e := s.addresses()
	if e != nil {
		return Snapshot{}, e
	}
	found := false
	for _, a := range addresses {
		found = found || a.IP == in.Address
	}
	if in.Enabled && !found {
		return Snapshot{}, fmt.Errorf("%w: selected IP is not assigned to this computer", ErrInvalid)
	}
	c.Address = in.Address
	c.Port = in.Port
	c.Enabled = in.Enabled
	c.Revision++
	if in.Enabled {
		if _, _, e = s.material(c); e != nil {
			if e = s.generate(&c); e != nil {
				return Snapshot{}, e
			}
		}
	}
	raw, e := json.MarshalIndent(c, "", "  ")
	if e != nil {
		return Snapshot{}, e
	}
	if e = atomicWrite(filepath.Join(s.dir, "lan-access.json"), raw); e != nil {
		return Snapshot{}, e
	}
	return s.snapshotFor(c, addresses), nil
}
func atomicWrite(path string, data []byte) error {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".lan-config-")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e != nil {
		f.Close()
		return e
	}
	if _, e = f.Write(data); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(name, path)
}
func (s *Service) generate(c *Config) error {
	if s.webRoot != "" {
		privateDir := filepath.Join(s.dir, "lan-certificates")
		if e := os.MkdirAll(privateDir, 0700); e != nil {
			return e
		}
		privateDir, e := filepath.EvalSymlinks(privateDir)
		if e != nil {
			return e
		}
		web, e := filepath.EvalSymlinks(s.webRoot)
		if e != nil {
			return e
		}
		privateDir, e = filepath.Abs(privateDir)
		if e != nil {
			return e
		}
		web, e = filepath.Abs(web)
		if e != nil {
			return e
		}
		rel, e := filepath.Rel(web, privateDir)
		if e != nil {
			return e
		}
		if rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("LAN private keys must remain outside the served web directory")
		}
	}
	key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		return e
	}
	serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if e != nil {
		return e
	}
	now := time.Now()
	leaf := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Universal HMI LAN Web"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(10, 0, 0), IPAddresses: []net.IP{net.ParseIP(c.Address)}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	der, e := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	if e != nil {
		return e
	}
	keyDER, e := x509.MarshalPKCS8PrivateKey(key)
	if e != nil {
		return e
	}
	name := serial.Text(16)
	cert := name + "-cert.pem"
	private := name + "-key.pem"
	dir := filepath.Join(s.dir, "lan-certificates")
	if e = atomicWrite(filepath.Join(dir, private), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})); e != nil {
		return e
	}
	if e = atomicWrite(filepath.Join(dir, cert), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); e != nil {
		return e
	}
	c.Certificate = cert
	c.PrivateKey = private
	return nil
}

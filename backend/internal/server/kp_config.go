package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

type KPConfig struct {
	Enabled         *bool            `json:"enabled,omitempty"`
	KPServer        string           `json:"kp_server,omitempty"`
	KPProject       string           `json:"kp_project,omitempty"`
	SourceID        string           `json:"source_id"`
	WorkspaceID     string           `json:"workspace_id"`
	KPOrigins       []string         `json:"kp_origins"`
	VerifierURL     string           `json:"verifier_url"`
	Users           []kpbridge.Grant `json:"users"`
	LeaseSeconds    int              `json:"lease_seconds"`
	AbsoluteSeconds int              `json:"absolute_seconds"`
}

// PublicKP loads the optional project-owned configuration at backend startup.
// Ordinary login is retained; no extra process or KP password is required.
func PublicKP(dataDir, webDir, origin string, ids *identity.Service, legacy http.Handler) (http.Handler, error) {
	filename := filepath.Join(dataDir, "kp-bridge.json")
	if _, err := os.Stat(filename); os.IsNotExist(err) {
		return nil, nil
	}
	c, err := LoadKPFile(filename)
	if err != nil {
		return nil, err
	}
	if c.Enabled != nil && !*c.Enabled {
		return nil, nil
	}
	if c.KPServer == "" || c.VerifierURL != "" {
		return nil, fmt.Errorf("public KP configuration requires kp_server")
	}
	bridge, err := NewKPService(c, false, nil)
	if err != nil {
		return nil, err
	}
	return KPHandler(bridge, KPOptions{Identity: ids, PublicReadOnly: true, PublicOrigin: origin, WebDir: webDir, KPOrigins: c.KPOrigins}, legacy, nil)
}

func LoadKPFile(filename string) (KPConfig, error) {
	c, _, e := readKPFile(filename)
	return c, e
}
func readKPFile(filename string) (KPConfig, []byte, error) {
	var c KPConfig
	f, e := os.Open(filename)
	if e != nil {
		return c, nil, fmt.Errorf("open KP configuration: %w", e)
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return c, nil, e
	}
	if !info.Mode().IsRegular() || info.Size() > 256*1024 {
		return c, nil, fmt.Errorf("KP configuration must be a regular file up to 256 KiB")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return c, nil, fmt.Errorf("KP configuration requires owner-only permissions (0600)")
	}
	raw, e := io.ReadAll(io.LimitReader(f, 256*1024+1))
	if e != nil {
		return c, nil, e
	}
	if len(raw) > 256*1024 {
		return c, nil, fmt.Errorf("KP configuration exceeds 256 KiB")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || d.Decode(new(any)) != io.EOF {
		return KPConfig{}, raw, fmt.Errorf("invalid KP configuration")
	}
	return c, raw, nil
}
func NewKPService(c KPConfig, localTrial bool, transport http.RoundTripper) (*kpbridge.Service, error) {
	if c.LeaseSeconds < 0 || c.LeaseSeconds > 600 || c.AbsoluteSeconds < 0 || c.AbsoluteSeconds > 86400 {
		return nil, fmt.Errorf("invalid KP lifetime")
	}
	var verifier kpbridge.Verifier
	if c.KPServer != "" && (localTrial || c.VerifierURL != "") {
		return nil, fmt.Errorf("native KP requires exactly one trusted identity source")
	}
	if localTrial {
		if c.VerifierURL != "" {
			return nil, fmt.Errorf("local trial cannot configure a production verifier")
		}
		verifier = kpbridge.VerifyFunc(func(_ context.Context, _ string, b kpbridge.Bootstrap) (kpbridge.Identity, error) {
			return kpbridge.Identity{Subject: b.UserName, UserName: b.UserName}, nil
		})
	} else if c.KPServer != "" {
		var e error
		verifier, e = kpbridge.NewKingPortalVerifier(c.KPServer, c.KPProject, transport)
		if e != nil {
			return nil, e
		}
	} else if c.VerifierURL != "" {
		var e error
		verifier, e = kpbridge.NewHTTPVerifier(c.VerifierURL, transport)
		if e != nil {
			return nil, e
		}
	}
	return kpbridge.New(kpbridge.Options{SourceID: c.SourceID, WorkspaceID: c.WorkspaceID, Grants: c.Users, Verifier: verifier, Lease: time.Duration(c.LeaseSeconds) * time.Second, AbsoluteTTL: time.Duration(c.AbsoluteSeconds) * time.Second})
}

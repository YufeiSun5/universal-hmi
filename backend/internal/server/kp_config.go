package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

type KPConfig struct {
	SourceID        string           `json:"source_id"`
	WorkspaceID     string           `json:"workspace_id"`
	KPOrigins       []string         `json:"kp_origins"`
	VerifierURL     string           `json:"verifier_url"`
	Users           []kpbridge.Grant `json:"users"`
	LeaseSeconds    int              `json:"lease_seconds"`
	AbsoluteSeconds int              `json:"absolute_seconds"`
}

func LoadKPFile(filename string) (KPConfig, error) {
	var c KPConfig
	f, e := os.Open(filename)
	if e != nil {
		return c, fmt.Errorf("open KP configuration: %w", e)
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return c, e
	}
	if !info.Mode().IsRegular() || info.Size() > 256*1024 {
		return c, fmt.Errorf("KP configuration must be a regular file up to 256 KiB")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return c, fmt.Errorf("KP configuration requires owner-only permissions (0600)")
	}
	d := json.NewDecoder(io.LimitReader(f, 256*1024+1))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || d.Decode(new(any)) != io.EOF {
		return c, fmt.Errorf("invalid KP configuration")
	}
	return c, nil
}
func NewKPService(c KPConfig, localTrial bool, transport http.RoundTripper) (*kpbridge.Service, error) {
	if c.LeaseSeconds < 0 || c.LeaseSeconds > 600 || c.AbsoluteSeconds < 0 || c.AbsoluteSeconds > 86400 {
		return nil, fmt.Errorf("invalid KP lifetime")
	}
	var verifier kpbridge.Verifier
	if localTrial {
		if c.VerifierURL != "" {
			return nil, fmt.Errorf("local trial cannot configure a production verifier")
		}
		verifier = kpbridge.VerifyFunc(func(_ context.Context, _ string, b kpbridge.Bootstrap) (kpbridge.Identity, error) {
			return kpbridge.Identity{Subject: b.UserName, UserName: b.UserName}, nil
		})
	} else if c.VerifierURL != "" {
		var e error
		verifier, e = kpbridge.NewHTTPVerifier(c.VerifierURL, transport)
		if e != nil {
			return nil, e
		}
	}
	return kpbridge.New(kpbridge.Options{SourceID: c.SourceID, WorkspaceID: c.WorkspaceID, Grants: c.Users, Verifier: verifier, Lease: time.Duration(c.LeaseSeconds) * time.Second, AbsoluteTTL: time.Duration(c.AbsoluteSeconds) * time.Second})
}

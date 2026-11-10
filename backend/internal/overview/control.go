package overview

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

type ControlConfig struct {
	Enabled bool   `json:"enabled"`
	BaseURL string `json:"base_url,omitempty"`
}
type ControlBinding struct {
	Station string `json:"station,omitempty"`
	Zone    string `json:"zone,omitempty"`
}
type ControlState struct {
	Active bool   `json:"active"`
	Label  string `json:"label"`
}
type ControlResult struct {
	Revision int64                   `json:"revision"`
	Rows     map[string]ControlState `json:"rows"`
}
type controlCache struct {
	revision int64
	until    time.Time
	rows     []controlStation
}
type controlStation struct {
	Name         string `json:"name"`
	WriteEnabled *bool  `json:"write_enabled"`
	Status       *struct {
		Strategy string `json:"strategy"`
		Mode     string `json:"mode"`
		Healthy  bool   `json:"data_healthy"`
		Recovery bool   `json:"recovery_pending"`
		Zones    []struct {
			ID           string `json:"id"`
			Name         string `json:"name"`
			WriteEnabled *bool  `json:"write_enabled"`
			SampledAt    string `json:"sampled_at"`
			ControlMode  struct {
				State     string `json:"state"`
				Suspended bool   `json:"suspended"`
			} `json:"control_mode"`
		} `json:"zones"`
		Settings struct {
			Zones []struct {
				ID   string `json:"id"`
				Mode string `json:"mode"`
			} `json:"zones"`
		} `json:"active_settings"`
	} `json:"status"`
}

func validateControl(c ControlConfig) error {
	if c.BaseURL == "" && !c.Enabled {
		return nil
	}
	u, err := url.Parse(c.BaseURL)
	if err != nil {
		return errors.New("接管状态服务地址无效")
	}
	ip, err := netip.ParseAddr(u.Hostname())
	if err != nil || !(ip.IsPrivate() || ip.IsLoopback()) || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return errors.New("接管状态服务须为内网IP的HTTP/HTTPS根地址，不含凭据、路径或查询参数")
	}
	return nil
}

func stationKey(v string) string {
	for _, p := range []string{"新北站", "新南站", "新西站", "新北换热站", "新南换热站", "新西换热站"} {
		if strings.HasPrefix(v, p) {
			return strings.TrimPrefix(v, "新")
		}
	}
	return v
}
func controlState(rows []controlStation, b ControlBinding) ControlState {
	unknown := ControlState{Label: "状态未知"}
	idle := ControlState{Label: "未接管"}
	if b.Station == "" || b.Zone == "" {
		return unknown
	}
	var found *controlStation
	for i := range rows {
		if stationKey(rows[i].Name) == stationKey(b.Station) {
			if found != nil {
				return unknown
			}
			found = &rows[i]
		}
	}
	if found == nil || found.Status == nil || found.Status.Strategy != "workbench" {
		return unknown
	}
	s := found.Status
	zi := -1
	for i := range s.Zones {
		if s.Zones[i].Name == b.Zone {
			if zi >= 0 {
				return unknown
			}
			zi = i
		}
	}
	if zi < 0 {
		return unknown
	}
	z := s.Zones[zi]
	mode, count := "", 0
	for _, setting := range s.Settings.Zones {
		if setting.ID == z.ID {
			mode = setting.Mode
			count++
		}
	}
	if (found.WriteEnabled != nil && !*found.WriteEnabled) || (z.WriteEnabled != nil && !*z.WriteEnabled) || z.ControlMode.State == "field_auto" || z.ControlMode.Suspended || (count == 1 && mode == "idle") || s.Recovery || s.Mode == "MANUAL" {
		return idle
	}
	if count != 1 || z.ID == "" || s.Mode != "AUTO" || !s.Healthy || z.ControlMode.State == "unknown" || z.SampledAt == "" {
		return unknown
	}
	switch mode {
	case "valve", "manual", "curve", "schedule", "auto":
		return ControlState{Active: true, Label: "已接管"}
	}
	return unknown
}

func fetchControl(ctx context.Context, base string) []controlStation {
	if validateControl(ControlConfig{Enabled: true, BaseURL: base}) != nil {
		return nil
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/api/heatnet/overview", nil)
	if err != nil {
		return nil
	}
	response, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024+1))
	if err != nil || len(body) > 4*1024*1024 {
		return nil
	}
	var payload struct {
		Code *int             `json:"code"`
		Data []controlStation `json:"data"`
	}
	if json.Unmarshal(body, &payload) != nil || payload.Code == nil || *payload.Code != 0 {
		return nil
	}
	return payload.Data
}

// ControlStatus coalesces viewers into one bounded read, then projects only
// authorized current rows. No upstream credentials or configuration are exposed.
func (s *Service) ControlStatus(ctx context.Context) (ControlResult, error) {
	a, managed := authorization.FromContext(ctx)
	if managed && !a.Active() {
		return ControlResult{}, authorization.ErrDenied
	}
	s.mu.Lock()
	c, err := s.load()
	s.mu.Unlock()
	if err != nil {
		return ControlResult{}, err
	}
	result := ControlResult{Revision: c.Revision, Rows: map[string]ControlState{}}
	allowed := func(r Row) bool { return !managed || a.Grants.Develop() || a.Station(r.Station) }
	for _, r := range c.Rows {
		if allowed(r) {
			result.Rows[r.ID] = ControlState{Label: "状态未知"}
		}
	}
	if !c.Control.Enabled || len(result.Rows) == 0 {
		return result, nil
	}
	s.controlMu.Lock()
	if s.controlCache.revision != c.Revision || time.Now().After(s.controlCache.until) {
		// A viewer cancelling does not invalidate other viewers' shared request.
		readCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		rows := fetchControl(readCtx, c.Control.BaseURL)
		cancel()
		s.controlCache = controlCache{revision: c.Revision, until: time.Now().Add(2 * time.Second), rows: rows}
	}
	rows := s.controlCache.rows
	s.controlMu.Unlock()
	if err := ctx.Err(); err != nil {
		return ControlResult{}, err
	}
	if managed && !a.Active() {
		return ControlResult{}, authorization.ErrDenied
	}
	s.mu.Lock()
	current, err := s.load()
	s.mu.Unlock()
	if err != nil {
		return ControlResult{}, err
	}
	if current.Revision != c.Revision {
		return result, nil
	} // Late result never paints a new configuration green.
	for _, r := range c.Rows {
		if allowed(r) {
			result.Rows[r.ID] = controlState(rows, r.Control)
		}
	}
	return result, nil
}

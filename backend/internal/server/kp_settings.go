package server

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

// KPSettings owns the single project file and a replaceable public handler.
// Saving never changes the live handler. Apply retires all old linked sessions.
type KPSettings struct {
	mu                            sync.RWMutex
	file, project, origin, webDir string
	ids                           *identity.Service
	legacy                        http.Handler
	handler                       http.Handler
	bridge                        *kpbridge.Service
	activeRevision, statusError   string
	listening                     bool
}
type KPSettingsInput struct {
	Revision string           `json:"revision"`
	Enabled  bool             `json:"enabled"`
	Server   string           `json:"kp_server"`
	Project  string           `json:"kp_project"`
	Origins  []string         `json:"kp_origins"`
	Users    []kpbridge.Grant `json:"users"`
}
type KPSettingsView struct {
	KPSettingsInput
	PublicOrigin    string `json:"public_origin"`
	Running         bool   `json:"running"`
	PublicListening bool   `json:"public_listening"`
	Pending         bool   `json:"pending"`
	StatusError     string `json:"status_error,omitempty"`
}

var errKPConflict = errors.New("配置已改变，请保留草稿并重新读取核对")

func NewKPSettings(dir, project string, ids *identity.Service) *KPSettings {
	return &KPSettings{file: filepath.Join(dir, "kp-bridge.json"), project: project, ids: ids}
}
func (s *KPSettings) read() (KPConfig, string, error) {
	c, raw, e := readKPFile(s.file)
	if errors.Is(e, os.ErrNotExist) {
		f := false
		return KPConfig{Enabled: &f}, "absent", nil
	}
	if raw == nil {
		return KPConfig{}, "", e
	}
	return c, fmt.Sprintf("%x", sha256.Sum256(raw)), e
}
func kpEnabled(c KPConfig) bool { return c.Enabled == nil || *c.Enabled }
func (s *KPSettings) snapshot() KPSettingsView {
	c, rev, e := s.read()
	msg := s.statusError
	if e != nil {
		msg = "读取 KP 配置失败：" + e.Error()
	}
	return KPSettingsView{KPSettingsInput: KPSettingsInput{rev, kpEnabled(c) && e == nil, c.KPServer, c.KPProject, c.KPOrigins, c.Users}, PublicOrigin: s.origin, Running: s.listening && s.bridge != nil, PublicListening: s.listening, Pending: rev != s.activeRevision, StatusError: msg}
}
func (s *KPSettings) Snapshot() KPSettingsView {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snapshot()
}
func (s *KPSettings) validate(c KPConfig) error {
	if !kpEnabled(c) {
		return nil
	}
	if c.KPServer == "" || c.VerifierURL != "" {
		return fmt.Errorf("请填写 KP 后台服务地址；旧版外部验证器配置需单独维护")
	}
	if e := ValidateKPOptions(KPOptions{PublicOrigin: "https://validation.invalid", PublicReadOnly: true, KPOrigins: c.KPOrigins}); e != nil {
		return fmt.Errorf("KP 公网网页地址需为1至8个完整来源（协议、主机、端口），不含路径、查询或通配符")
	}
	if len(c.Users) == 0 {
		return fmt.Errorf("请至少映射一个 KP 用户到监控账号")
	}
	for _, g := range c.Users {
		u, e := s.ids.User(g.UserID)
		if e != nil || u.Disabled {
			return fmt.Errorf("KP 用户 %s 对应的监控账号不存在或已停用", g.Subject)
		}
	}
	if _, e := NewKPService(c, false, nil); e != nil {
		return fmt.Errorf("KP 配置无效（检查服务地址、工程名和重复用户ID）：%w", e)
	}
	return nil
}
func (s *KPSettings) Save(in KPSettingsInput) (KPSettingsView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, rev, e := s.read()
	// A readable but malformed file may be repaired explicitly using its digest.
	if rev == "" && e != nil {
		return s.snapshot(), e
	}
	if rev != in.Revision {
		return s.snapshot(), errKPConflict
	}
	if old.VerifierURL != "" {
		return s.snapshot(), fmt.Errorf("当前为旧版外部验证器配置，请保留原接入并由维护人员迁移")
	}
	c := old
	c.Enabled = &in.Enabled
	c.KPServer = strings.TrimRight(strings.TrimSpace(in.Server), "/")
	c.KPProject = strings.TrimSpace(in.Project)
	c.KPOrigins = in.Origins
	c.Users = in.Users
	for i := range c.KPOrigins {
		c.KPOrigins[i] = strings.TrimRight(strings.TrimSpace(c.KPOrigins[i]), "/")
	}
	if c.SourceID == "" {
		c.SourceID = "kp-native"
	}
	if c.WorkspaceID == "" {
		c.WorkspaceID = s.project
		if c.WorkspaceID == "" {
			c.WorkspaceID = "default"
		}
	}
	for i := range c.Users {
		g := &c.Users[i]
		g.Subject = strings.TrimSpace(g.Subject)
		g.Role = "viewer"
		u, err := s.ids.User(g.UserID)
		if err != nil {
			if in.Enabled {
				return s.snapshot(), fmt.Errorf("请选择有效监控账号")
			}
		} else {
			g.DisplayName = u.Username
		}
	}
	if e = s.validate(c); e != nil {
		return s.snapshot(), e
	}
	data, e := json.MarshalIndent(c, "", "  ")
	if e != nil {
		return s.snapshot(), e
	}
	if e = os.MkdirAll(filepath.Dir(s.file), 0700); e != nil {
		return s.snapshot(), e
	}
	f, e := os.CreateTemp(filepath.Dir(s.file), ".kp-config-")
	if e != nil {
		return s.snapshot(), e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(data)
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e == nil {
		e = os.Rename(name, s.file)
	}
	if e == nil {
		s.statusError = ""
	}
	return s.snapshot(), e
}
func (s *KPSettings) apply(revision string) error {
	c, rev, e := s.read()
	if e != nil {
		return e
	}
	if rev != revision {
		return errKPConflict
	}
	if e = s.validate(c); e != nil {
		return e
	}
	var bridge *kpbridge.Service
	var handler http.Handler
	if kpEnabled(c) {
		if s.legacy == nil {
			return fmt.Errorf("公网 HTTPS 入口未就绪，请先启用网络入口后重新应用")
		}
		bridge, e = NewKPService(c, false, nil)
		if e == nil {
			handler, e = KPHandler(bridge, KPOptions{Identity: s.ids, PublicReadOnly: true, PublicOrigin: s.origin, WebDir: s.webDir, KPOrigins: c.KPOrigins}, s.legacy, nil)
		}
		if e != nil {
			return e
		}
	}
	if s.bridge != nil {
		s.bridge.Retire()
	}
	s.bridge = bridge
	s.handler = handler
	s.activeRevision = rev
	s.statusError = ""
	return nil
}
func (s *KPSettings) Apply(revision string) (KPSettingsView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.apply(revision)
	if e != nil {
		s.statusError = e.Error()
	}
	return s.snapshot(), e
}

// Attach is called inside the existing public IP/device and read-only pipeline.
func (s *KPSettings) Attach(origin, webDir string, legacy http.Handler) http.Handler {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.origin = origin
	s.webDir = webDir
	s.legacy = legacy
	_, rev, e := s.read()
	if e == nil {
		e = s.apply(rev)
	}
	if e != nil {
		s.statusError = e.Error()
	}
	return s
}
func (s *KPSettings) SetListening(listening bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.listening = listening
}
func (s *KPSettings) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	h := s.handler
	hasError := s.statusError != ""
	origin, webDir := s.origin, s.webDir
	s.mu.RUnlock()
	// Public helper/error pages contain no identity or project data. Keeping
	// these exact assets available lets an inactive integration explain itself.
	if r.URL.Path == "/kp/kp_bridge.js" || r.URL.Path == "/kp/kp-fallback.html" || r.URL.Path == "/kp/kp-loading.html" {
		u, e := url.Parse(origin)
		if e != nil || u.Host == "" || !strings.EqualFold(r.Host, u.Host) || r.TLS == nil {
			writeError(w, 403, "origin_rejected", "监控地址或传输协议不匹配")
			return
		}
		if r.Method != "GET" && r.Method != "HEAD" {
			authMethodError(w)
			return
		}
		w.Header().Set("Cache-Control", "private, no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "base-uri 'self'; object-src 'none'")
		http.ServeFile(w, r, filepath.Join(webDir, strings.TrimPrefix(r.URL.Path, "/kp/")))
		return
	}
	if h == nil {
		code, message := "kp_disabled", "KP 接入未启用，请在开发态的登录与安全 → KP 接入中配置并应用"
		if hasError {
			code = "kp_configuration_error"
			message = "KP 配置未生效，请在开发态的 KP 接入中查看原因"
		}
		writeError(w, 503, code, message)
		return
	}
	h.ServeHTTP(w, r)
}
func (s *KPSettings) Check(ctx context.Context, revision string) (string, error) {
	s.mu.RLock()
	c, rev, e := s.read()
	if e == nil && rev != revision {
		e = errKPConflict
	}
	if e == nil {
		e = s.validate(c)
	}
	s.mu.RUnlock()
	if e != nil {
		return "", e
	}
	if !kpEnabled(c) {
		return "配置已保存为停用状态", nil
	}
	v, e := kpbridge.NewKingPortalVerifier(c.KPServer, c.KPProject, nil)
	if e != nil {
		return "", e
	}
	_, e = v.Verify(ctx, "", kpbridge.Bootstrap{IdentityProof: "hmi-connectivity-check-invalid-token"})
	var denied *kpbridge.Error
	if errors.As(e, &denied) && denied.Code == "identity_not_verified" {
		return "KP 核验接口可达，并拒绝无效令牌；真实账号登录需在 KP 画面验证", nil
	}
	if e == nil {
		return "", fmt.Errorf("KP 接口接受了无效检查令牌，请检查认证配置")
	}
	return "", fmt.Errorf("无法确认 KP 核验接口：%w", e)
}
func kpSettingsAPI(w http.ResponseWriter, r *http.Request, s *KPSettings, ids *identity.Service, a authorization.Actor, session identity.Session, local bool) {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	if !local || e != nil || !IsLoopbackHost(host) || session.Channel != "" || !a.Active() || !a.Grants.Manage() {
		writeError(w, 403, "permission_denied", "KP 接入仅允许本机管理员配置")
		return
	}
	if s == nil {
		writeError(w, 503, "kp_settings_unavailable", "当前服务不支持 KP 接入配置")
		return
	}
	if r.Method == "GET" {
		writeJSON(w, 200, s.Snapshot())
		return
	}
	if r.Method != "PUT" && r.Method != "POST" {
		w.Header().Set("Allow", "GET, PUT, POST")
		writeError(w, 405, "method_not_allowed", "仅支持读取、保存和应用")
		return
	}
	var result any
	if r.Method == "PUT" {
		var in KPSettingsInput
		if !decode(w, r, &in) {
			return
		}
		if e = ids.Record(a.ID, "kp.configure", "project", "attempt"); e == nil {
			result, e = s.Save(in)
		}
	} else {
		var in struct {
			Revision string `json:"revision"`
			Action   string `json:"action"`
		}
		if !decode(w, r, &in) {
			return
		}
		if in.Action == "check" {
			var message string
			message, e = s.Check(r.Context(), in.Revision)
			result = map[string]string{"message": message}
		} else if in.Action == "apply" {
			if e = ids.Record(a.ID, "kp.apply", "project", "attempt"); e == nil {
				result, e = s.Apply(in.Revision)
			}
		} else {
			e = fmt.Errorf("未知 KP 操作")
		}
	}
	if errors.Is(e, errKPConflict) {
		writeError(w, 409, "kp_config_conflict", e.Error())
		return
	}
	if e != nil {
		writeError(w, 422, "kp_configuration_error", e.Error())
		return
	}
	writeJSON(w, 200, result)
}

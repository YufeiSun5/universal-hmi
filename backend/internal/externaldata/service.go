// Package externaldata owns external history connections and independent views.
package externaldata

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

var ErrConflict = errors.New("配置已被修改，请刷新后重试")
var ErrMissing = errors.New("外数据资源不存在或未授权")

type Repository interface {
	LoadConfig(string, any) error
	SaveConfig(string, any) error
}
type Source struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Host             string `json:"host"`
	Port             int    `json:"port"`
	Database         string `json:"database"`
	Username         string `json:"username"`
	Encrypt          bool   `json:"encrypt"`
	TrustCertificate bool   `json:"trust_certificate"`
	UTCOffsetMinutes int    `json:"utc_offset_minutes"`
	Revision         int64  `json:"revision"`
	HasPassword      bool   `json:"has_password"`
}
type SourceChange struct {
	Source
	Password *string `json:"password,omitempty"`
}
type storedSource struct {
	Source
	Secret string `json:"secret"`
}
type Screen struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	SourceID string `json:"source_id"`
	Kind     string `json:"kind"` // hourly, detail, trend
	Revision int64  `json:"revision"`
}
type config struct {
	Sources []storedSource `json:"sources"`
	Screens []Screen       `json:"screens"`
}
type Service struct {
	mu    sync.Mutex
	repo  Repository
	key   cipher.AEAD
	slots chan struct{}
	open  openDatabase
}

func Open(repo Repository, dir string) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "connection.key")
	key, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		key = make([]byte, 32)
		if _, err = rand.Read(key); err != nil {
			return nil, err
		}
		f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return nil, e
		}
		_, err = f.Write(key)
		ce := f.Close()
		if err == nil {
			err = ce
		}
	}
	if err != nil {
		return nil, err
	}
	if len(key) != 32 {
		return nil, fmt.Errorf("外数据密钥无效")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Service{repo: repo, key: aead, slots: make(chan struct{}, 4), open: connect}, nil
}
func newID() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func engineering(ctx context.Context) bool {
	a, ok := authorization.FromContext(ctx)
	return !ok || a.Active() && a.Grants.Develop()
}
func mayRead(ctx context.Context, id string) bool {
	a, ok := authorization.FromContext(ctx)
	return !ok || a.Active() && (a.Grants.Develop() || slices.Contains(a.Grants.ExternalScreenIDs, id))
}
func (s *Service) load() (config, error) {
	c := config{Sources: []storedSource{}, Screens: []Screen{}}
	e := s.repo.LoadConfig("external_data_v1", &c)
	return c, e
}
func (s *Service) Sources(ctx context.Context) ([]Source, error) {
	if !engineering(ctx) {
		return nil, authorization.ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	out := []Source{}
	for _, v := range c.Sources {
		out = append(out, v.Source)
	}
	return out, e
}
func (s *Service) Screens(ctx context.Context) ([]Screen, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	out := []Screen{}
	a, managed := authorization.FromContext(ctx)
	for _, v := range c.Screens {
		if mayRead(ctx, v.ID) || managed && a.Active() && a.Grants.Manage() {
			out = append(out, v)
		}
	}
	return out, e
}
func validName(v string) bool {
	return strings.TrimSpace(v) != "" && len(v) <= 256 && !strings.ContainsAny(v, "\x00\r\n")
}
func (s *Service) SaveSource(ctx context.Context, in SourceChange) (Source, error) {
	if !engineering(ctx) {
		return Source{}, authorization.ErrDenied
	}
	v := in.Source
	v.Name = strings.TrimSpace(v.Name)
	v.Host = strings.TrimSpace(v.Host)
	if !validName(v.Name) || !validName(v.Database) || v.Username == "" || len(v.Username) > 128 || v.Port < 1 || v.Port > 65535 || v.UTCOffsetMinutes < -840 || v.UTCOffsetMinutes > 840 {
		return Source{}, fmt.Errorf("请填写名称、数据库、SQL登录账号、有效端口和时区")
	}
	if len(v.Host) > 253 || v.Host == "" || strings.ContainsAny(v.Host, " /\\;@?#\r\n\x00") || strings.Contains(v.Host, ":") && net.ParseIP(v.Host) == nil {
		return Source{}, fmt.Errorf("服务器应为主机名或IP，端口单独填写")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return Source{}, e
	}
	index := -1
	secret := ""
	for i, old := range c.Sources {
		if old.ID == v.ID {
			index = i
			secret = old.Secret
			if old.Revision != v.Revision {
				return Source{}, ErrConflict
			}
		}
	}
	if index < 0 {
		if v.ID != "" {
			return Source{}, ErrMissing
		}
		if len(c.Sources) >= 32 {
			return Source{}, fmt.Errorf("最多32个外部数据源")
		}
		v.ID = newID()
		v.Revision = 0
	}
	if in.Password != nil {
		if len(*in.Password) == 0 || len(*in.Password) > 1024 {
			return Source{}, fmt.Errorf("密码不能为空且最多1024字节")
		}
		nonce := make([]byte, s.key.NonceSize())
		if _, e = rand.Read(nonce); e != nil {
			return Source{}, e
		}
		secret = base64.StdEncoding.EncodeToString(s.key.Seal(nonce, nonce, []byte(*in.Password), []byte(v.ID)))
	}
	if secret == "" {
		return Source{}, fmt.Errorf("首次保存需要填写SQL登录密码")
	}
	v.HasPassword = true
	v.Revision++
	saved := storedSource{v, secret}
	if index < 0 {
		c.Sources = append(c.Sources, saved)
	} else {
		c.Sources[index] = saved
	}
	if e = s.repo.SaveConfig("external_data_v1", c); e != nil {
		return Source{}, e
	}
	return v, nil
}
func (s *Service) SaveScreen(ctx context.Context, v Screen) (Screen, error) {
	if !engineering(ctx) {
		return Screen{}, authorization.ErrDenied
	}
	v.Name = strings.TrimSpace(v.Name)
	if !validName(v.Name) || !slices.Contains([]string{"hourly", "detail", "trend"}, v.Kind) {
		return Screen{}, fmt.Errorf("请选择有效画面名称和类型")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return Screen{}, e
	}
	if !slices.ContainsFunc(c.Sources, func(x storedSource) bool { return x.ID == v.SourceID }) {
		return Screen{}, fmt.Errorf("请先保存数据源")
	}
	index := -1
	for i, old := range c.Screens {
		if old.ID == v.ID {
			index = i
			if old.Revision != v.Revision {
				return Screen{}, ErrConflict
			}
			if old.SourceID != v.SourceID || old.Kind != v.Kind {
				return Screen{}, fmt.Errorf("已有画面的数据源和类型不可替换，请新建画面并重新授权")
			}
		}
	}
	if index < 0 {
		if v.ID != "" {
			return Screen{}, ErrMissing
		}
		if len(c.Screens) >= 256 {
			return Screen{}, fmt.Errorf("最多256个外数据画面")
		}
		v.ID = newID()
		v.Revision = 0
	}
	v.Revision++
	if index < 0 {
		c.Screens = append(c.Screens, v)
	} else {
		c.Screens[index] = v
	}
	if e = s.repo.SaveConfig("external_data_v1", c); e != nil {
		return Screen{}, e
	}
	return v, nil
}
func (s *Service) Delete(ctx context.Context, kind, id string, revision int64) error {
	if !engineering(ctx) {
		return authorization.ErrDenied
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return e
	}
	if kind == "sources" {
		for i, v := range c.Sources {
			if v.ID == id {
				if v.Revision != revision {
					return ErrConflict
				}
				for _, screen := range c.Screens {
					if screen.SourceID == id {
						return fmt.Errorf("请先删除引用此数据源的画面")
					}
				}
				c.Sources = slices.Delete(c.Sources, i, i+1)
				return s.repo.SaveConfig("external_data_v1", c)
			}
		}
	} else {
		for i, v := range c.Screens {
			if v.ID == id {
				if v.Revision != revision {
					return ErrConflict
				}
				c.Screens = slices.Delete(c.Screens, i, i+1)
				return s.repo.SaveConfig("external_data_v1", c)
			}
		}
	}
	return ErrMissing
}
func (s *Service) source(ctx context.Context, id string, screen bool) (storedSource, Screen, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, e := s.load()
	if e != nil {
		return storedSource{}, Screen{}, e
	}
	var view Screen
	if screen {
		if !mayRead(ctx, id) {
			return storedSource{}, view, authorization.ErrDenied
		}
		for _, v := range c.Screens {
			if v.ID == id {
				view = v
				id = v.SourceID
				break
			}
		}
		if view.ID == "" {
			return storedSource{}, view, ErrMissing
		}
	} else if !engineering(ctx) {
		return storedSource{}, view, authorization.ErrDenied
	}
	for _, v := range c.Sources {
		if v.ID == id {
			return v, view, nil
		}
	}
	return storedSource{}, view, ErrMissing
}
func (s *Service) password(v storedSource) (string, error) {
	raw, e := base64.StdEncoding.DecodeString(v.Secret)
	if e != nil || len(raw) < s.key.NonceSize() {
		return "", fmt.Errorf("外数据凭据不可用，请重新保存密码")
	}
	n := s.key.NonceSize()
	plain, e := s.key.Open(nil, raw[:n], raw[n:], []byte(v.ID))
	if e != nil {
		return "", fmt.Errorf("外数据凭据不可用，请恢复原密钥或重新保存密码")
	}
	return string(plain), nil
}

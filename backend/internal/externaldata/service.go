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
type AlarmColumn struct {
	Key     string `json:"key"`
	Label   string `json:"label"`
	Visible bool   `json:"visible"`
}

// DisplayColumn changes presentation only; query values and authorization remain unchanged.
type DisplayColumn = AlarmColumn

var statisticsFieldKeys = []string{"date", "station", "label", "unit", "hour", "hour_usage", "hour_min", "hour_max", "hour_status", "day_usage", "day_min", "day_max", "day_status", "progress", "sample_min", "sample_max", "day_subtotal"}

func statisticsKeys(kind string) []string {
	keys := make([]string, 0, len(statisticsFieldKeys))
	for _, key := range statisticsFieldKeys {
		if kind == "energy" && (strings.HasPrefix(key, "hour") || slices.Contains([]string{"day_min", "day_max"}, key)) {
			continue
		}
		keys = append(keys, key)
	}
	if kind == "daily" {
		keys = append(keys, "day_record", "valid_hours", "day_status_code", "day_anomaly")
	}
	return keys
}

func validateStatisticsColumns(columns []DisplayColumn, kind string) error {
	if columns == nil {
		return nil
	}
	keys := statisticsKeys(kind)
	// Previously saved daily layouts remain editable without losing order or labels.
	if kind == "daily" && len(columns) == len(statisticsFieldKeys) {
		keys = statisticsFieldKeys
	}
	if kind == "energy" && len(columns) == len(statisticsFieldKeys)-4 {
		// Read old energy layouts without losing saved titles; the UI removes
		// the former hourly fields on its next explicit layout save.
		keys = nil
		for _, key := range statisticsFieldKeys {
			if !slices.Contains([]string{"hour_min", "hour_max", "day_min", "day_max"}, key) {
				keys = append(keys, key)
			}
		}
	}
	if !slices.Contains([]string{"hourly", "daily", "energy"}, kind) || len(columns) != len(keys) {
		return fmt.Errorf("统计列配置必须包含全部固定字段")
	}
	seen := map[string]bool{}
	visibleKeys := map[string]bool{}
	for i, c := range columns {
		columns[i].Label = strings.TrimSpace(c.Label)
		if !slices.Contains(keys, c.Key) || seen[c.Key] || !validName(columns[i].Label) {
			return fmt.Errorf("统计字段或列头无效")
		}
		seen[c.Key] = true
		visibleKeys[c.Key] = c.Visible
	}
	modes := []string{kind}
	if kind == "energy" {
		modes = []string{"current", "daily", "zones"}
	}
	for _, mode := range modes {
		visible := false
		for key, shown := range visibleKeys {
			if !shown || (mode == "daily" && strings.HasPrefix(key, "hour")) ||
				(mode == "hourly" && slices.Contains([]string{"day_usage", "day_min", "day_max"}, key)) ||
				(kind == "energy" && (strings.HasPrefix(key, "hour") || slices.Contains([]string{"day_min", "day_max"}, key))) ||
				(kind == "energy" && mode != "zones" && key == "day_subtotal") {
				continue
			}
			visible = true
		}
		if !visible {
			return fmt.Errorf("各查询方式至少保留一个可见字段")
		}
	}
	return nil
}

var alarmFieldKeys = []string{"event_time", "alarm_time", "tag", "event_type", "alarm_value", "resume_value", "operator", "description", "comment", "group", "alarm_type", "priority", "limit_value"}

func validateAlarmColumns(columns []AlarmColumn, kind string) error {
	if columns == nil {
		return nil
	}
	if kind != "alarm" || len(columns) != len(alarmFieldKeys) {
		return fmt.Errorf("报警列配置必须包含全部固定字段")
	}
	seen := map[string]bool{}
	visible := false
	for i, c := range columns {
		columns[i].Label = strings.TrimSpace(c.Label)
		if !slices.Contains(alarmFieldKeys, c.Key) || seen[c.Key] || !validName(columns[i].Label) {
			return fmt.Errorf("报警字段或列头无效")
		}
		seen[c.Key] = true
		visible = visible || c.Visible
	}
	if !visible {
		return fmt.Errorf("至少显示一个报警字段")
	}
	return nil
}

type Screen struct {
	StatisticsColumns []DisplayColumn `json:"statistics_columns,omitempty"`
	AlarmColumns      []AlarmColumn   `json:"alarm_columns,omitempty"`
	ID                string          `json:"id"`
	Name              string          `json:"name"`
	SourceID          string          `json:"source_id"`
	Kind              string          `json:"kind"` // hourly, detail, trend
	Revision          int64           `json:"revision"`
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
	return !ok || a.Active() && (a.ReadAllExternalScreens || a.Grants.Develop() || slices.Contains(a.Grants.ExternalScreenIDs, id))
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
	if err := validateAlarmColumns(v.AlarmColumns, v.Kind); err != nil {
		return Screen{}, err
	}
	if err := validateStatisticsColumns(v.StatisticsColumns, v.Kind); err != nil {
		return Screen{}, err
	}
	if !validName(v.Name) || !slices.Contains([]string{"hourly", "daily", "energy", "comparison", "detail", "trend", "standard", "alarm"}, v.Kind) {
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
			if v.AlarmColumns == nil {
				v.AlarmColumns = old.AlarmColumns
			}
			if v.StatisticsColumns == nil {
				v.StatisticsColumns = old.StatisticsColumns
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

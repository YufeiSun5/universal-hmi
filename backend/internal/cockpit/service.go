// Package cockpit owns the display settings and read-only projections for the
// large-screen heating cockpit.
package cockpit

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
)

const ConfigKey = "heating_cockpit_v1"

var ErrConflict = errors.New("驾驶舱配置已有更新，请重新打开")
var zoneCode = regexp.MustCompile(`^[0-9]{2}-[0-9]{3}-[0-9]{2}$`)

type Config struct {
	Revision       int64              `json:"revision"`
	Title          string             `json:"title"`
	EnergyScreen   string             `json:"energy_screen"`
	DelayMinutes   int                `json:"delay_minutes"`
	OfflineMinutes int                `json:"offline_minutes"`
	Latitude       *float64           `json:"latitude"`
	Longitude      *float64           `json:"longitude"`
	FocusRows      []string           `json:"focus_rows"`
	PowerRows      []string           `json:"power_rows"`
	ZoneCodes      map[string]string  `json:"zone_codes"`
	RatedMW        map[string]float64 `json:"rated_mw"`
}

type HistorySource interface {
	CockpitAccess(context.Context, string) (string, error)
	CockpitHistory(context.Context, string, string, []string, time.Time) (map[string]any, error)
}

type Runtime interface {
	SubscriptionSnapshot(context.Context, []string) (map[string]any, error)
}

type cachedSection struct {
	key   string
	value map[string]any
}

type Service struct {
	store    overview.Store
	overview *overview.Service
	history  HistorySource
	runtime  Runtime
	weather  func(context.Context, float64, float64, time.Time) (map[string]any, error)
	settings sync.Mutex
	mu       sync.Mutex
	cache    map[string]cachedSection
	status   map[string]cachedSection
	wake     chan struct{}
}

func New(store overview.Store, h HistorySource, rt Runtime, host, key string) *Service {
	return &Service{
		store: store, overview: overview.New(store), history: h, runtime: rt,
		weather: qweather(host, key), cache: map[string]cachedSection{},
		status: map[string]cachedSection{}, wake: make(chan struct{}, 1),
	}
}

func authorized(ctx context.Context, edit bool) bool {
	a, managed := authorization.FromContext(ctx)
	return !managed || a.Active() && a.Grants.AllStations &&
		(!edit || a.Grants.Develop() && !a.ReadOnly)
}

func (s *Service) config() (Config, error) {
	c := Config{
		Title: "庄河供热运行指挥中心", DelayMinutes: 3, OfflineMinutes: 5,
		FocusRows: []string{}, PowerRows: []string{}, ZoneCodes: map[string]string{},
	}
	err := s.store.LoadConfig(ConfigKey, &c)
	return c, err
}

func (s *Service) Get(ctx context.Context) (Config, error) {
	if !authorized(ctx, true) {
		return Config{}, authorization.ErrDenied
	}
	return s.config()
}

func (s *Service) Save(ctx context.Context, c Config) (Config, error) {
	if !authorized(ctx, true) {
		return Config{}, authorization.ErrDenied
	}
	s.settings.Lock()
	defer s.settings.Unlock()
	old, err := s.config()
	if err != nil {
		return Config{}, err
	}
	if c.Revision != old.Revision {
		return Config{}, ErrConflict
	}
	c.Title = strings.TrimSpace(c.Title)
	if c.Title == "" || len([]rune(c.Title)) > 22 || strings.ContainsAny(c.Title, "\x00\r\n") {
		return Config{}, errors.New("标题须为1至22个字符")
	}
	if c.DelayMinutes < 1 || c.OfflineMinutes <= c.DelayMinutes || c.OfflineMinutes > 1440 {
		return Config{}, errors.New("延迟阈值至少1分钟，离线阈值须更大且不超过1440分钟")
	}
	finite := func(v float64, limit float64) bool { return !math.IsNaN(v) && math.Abs(v) <= limit }
	if (c.Latitude == nil) != (c.Longitude == nil) ||
		c.Latitude != nil && (!finite(*c.Latitude, 90) || !finite(*c.Longitude, 180)) {
		return Config{}, errors.New("请同时填写有效的天气经纬度")
	}
	if c.EnergyScreen != "" {
		if _, err := s.history.CockpitAccess(ctx, c.EnergyScreen); err != nil {
			return Config{}, err
		}
	}
	v, err := s.overview.Get(ctx, nil)
	if err != nil {
		return Config{}, err
	}
	rows := map[string]overview.Row{}
	for _, row := range v.Rows {
		rows[row.ID] = row
	}
	for _, selected := range [][]string{c.FocusRows, c.PowerRows} {
		seen := map[string]bool{}
		for _, id := range selected {
			if rows[id].ID == "" || seen[id] {
				return Config{}, errors.New("驾驶舱使用的总览站区已移除或重复")
			}
			seen[id] = true
		}
	}
	if len(c.FocusRows) > 4 {
		return Config{}, errors.New("最多选择四个重点站区")
	}
	for id, zone := range c.ZoneCodes {
		if !slices.Contains(c.FocusRows, id) || !zoneCode.MatchString(zone) {
			return Config{}, errors.New("外部站区编码须对应所选重点站区，例如 01-001-01")
		}
	}
	groups := map[string]bool{}
	for _, id := range c.PowerRows {
		groups[powerGroup(rows[id])] = true
	}
	for name, rated := range c.RatedMW {
		if !groups[name] || rated <= 0 || !finite(rated, 100000) {
			return Config{}, errors.New("额定供热能力须对应参与汇总的站所，单位为 MW，数值须大于零")
		}
	}
	if !authorized(ctx, true) {
		return Config{}, authorization.ErrDenied
	}
	c.Revision++
	if err := s.store.SaveConfig(ConfigKey, c); err != nil {
		return Config{}, err
	}
	s.signal()
	return c, nil
}

func (s *Service) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

var cst = time.FixedZone("Asia/Shanghai", 8*60*60)

func (s *Service) refresh(ctx context.Context, now time.Time) {
	c, err := s.config()
	if err != nil {
		return
	}
	if c.EnergyScreen != "" {
		source, err := s.history.CockpitAccess(ctx, c.EnergyScreen)
		if err == nil {
			zoneSet := map[string]bool{}
			var zones []string
			for _, id := range c.FocusRows {
				if code := c.ZoneCodes[id]; code != "" && !zoneSet[code] {
					zoneSet[code] = true
					zones = append(zones, code)
				}
			}
			loc := now.In(cst)
			date := loc.Format("2006-01-02")
			base := fmt.Sprintf("%d/%s/%s/", c.Revision, source, date)
			for _, part := range []struct{ name, period string }{
				{"today", loc.Format("15:04")},
				{"yesterday", loc.Truncate(15 * time.Minute).Format("15:04")},
				{"week", date},
				{"zones", loc.Add(-7 * time.Minute).Format("2006-01-02/15")},
				{"trends", loc.Format("15:04")},
			} {
				s.update("history/"+part.name, base, part.period, func() (map[string]any, error) {
					return s.history.CockpitHistory(ctx, c.EnergyScreen, part.name, zones, now)
				})
			}
		}
	}
	if c.Latitude != nil && c.Longitude != nil && s.weather != nil {
		s.update("weather", fmt.Sprintf("%d/", c.Revision), now.UTC().Truncate(30*time.Minute).Format(time.RFC3339), func() (map[string]any, error) {
			return s.weather(ctx, *c.Latitude, *c.Longitude, now)
		})
	}
}

func (s *Service) update(section, base, period string, fetch func() (map[string]any, error)) {
	key := base + period
	s.mu.Lock()
	same := s.status[section].key == key
	s.mu.Unlock()
	if same {
		return
	}
	data, err := fetch()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.status[section] = cachedSection{key: key}
	if err == nil {
		s.cache[section] = cachedSection{key: key, value: data}
	} else {
		s.status[section] = cachedSection{key: key, value: map[string]any{"message": err.Error()}}
	}
}

// Run preloads the single configured engineering project. Serving any cached
// history still requires both the cockpit scope and the external screen grant.
func (s *Service) Run(ctx context.Context) {
	tick := time.NewTicker(12 * time.Second)
	defer tick.Stop()
	for {
		s.refresh(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		case <-s.wake:
		}
	}
}

func (s *Service) History(ctx context.Context) (map[string]any, error) {
	if !authorized(ctx, false) {
		return nil, authorization.ErrDenied
	}
	c, err := s.config()
	if err != nil {
		return nil, err
	}
	if c.EnergyScreen == "" {
		return map[string]any{"notice": "尚未配置能耗数据来源"}, nil
	}
	key, err := s.history.CockpitAccess(ctx, c.EnergyScreen)
	if err != nil {
		if errors.Is(err, authorization.ErrDenied) {
			return nil, err
		}
		return map[string]any{"notice": "能耗数据来源不可用"}, nil
	}
	base := fmt.Sprintf("%d/%s/%s/", c.Revision, key, time.Now().In(cst).Format("2006-01-02"))
	out := map[string]any{}
	warnings := map[string]string{}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, part := range []string{"today", "yesterday", "week", "zones", "trends"} {
		item := s.cache["history/"+part]
		if strings.HasPrefix(item.key, base) {
			if part == "trends" {
				out[part] = item.value["values"]
			} else {
				out[part] = item.value
			}
		}
		status := s.status["history/"+part]
		if strings.HasPrefix(status.key, base) && status.value != nil {
			warnings[part] = "统计暂未更新"
		}
	}
	if len(warnings) > 0 {
		out["warnings"] = warnings
		out["notice"] = "部分统计暂未更新"
	}
	return out, nil
}

func (s *Service) Weather(ctx context.Context) (map[string]any, error) {
	if !authorized(ctx, false) {
		return nil, authorization.ErrDenied
	}
	c, err := s.config()
	if err != nil {
		return nil, err
	}
	if c.Latitude == nil || c.Longitude == nil || s.weather == nil {
		return map[string]any{"notice": "尚未配置天气来源及位置"}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	base := fmt.Sprintf("%d/", c.Revision)
	item := s.cache["weather"]
	if strings.HasPrefix(item.key, base) {
		result := make(map[string]any, len(item.value)+1)
		for k, v := range item.value {
			result[k] = v
		}
		if status := s.status["weather"]; status.value != nil {
			result["notice"] = "预报暂未更新"
		}
		return result, nil
	}
	if status := s.status["weather"]; strings.HasPrefix(status.key, base) && status.value != nil {
		return map[string]any{"notice": "天气服务暂不可用"}, nil
	}
	return map[string]any{"notice": "正在加载预报"}, nil
}

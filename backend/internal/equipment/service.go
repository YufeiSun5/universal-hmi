// Package equipment owns the equipment register, independently of live control.
package equipment

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

var ErrMissing = errors.New("设备不存在或未授权")
var ErrConflict = errors.New("档案已被其他人修改，请重新打开后重试")

type Repository interface {
	LoadConfig(string, any) error
	SaveConfig(string, any) error
}
type Property struct {
	Name  string `json:"name"`
	Value string `json:"value"`
	Unit  string `json:"unit"`
}
type Photo struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	MIME string `json:"mime"`
}
type Device struct {
	ID           string     `json:"id"`
	Revision     int64      `json:"revision"`
	Station      string     `json:"station"`
	Site         string     `json:"site"`
	Code         string     `json:"code"`
	Name         string     `json:"name"`
	Category     string     `json:"category"`
	Status       string     `json:"status,omitempty"` // Legacy optional field; no operational state is inferred.
	Manufacturer string     `json:"manufacturer"`
	Model        string     `json:"model"`
	Serial       string     `json:"serial"`
	Installed    string     `json:"installed"`
	Location     string     `json:"location"`
	Notes        string     `json:"notes"`
	Properties   []Property `json:"properties"`
	Photos       []Photo    `json:"photos"`
	PhotoFit     string     `json:"photo_fit,omitempty"`
	Updated      string     `json:"updated"`
	Signals      Signals    `json:"signals"`
}
type Filter struct {
	Station, Site, Category, Status, Search, Location string
	Offset, Limit                                     int
}
type Place struct {
	Station string `json:"station"`
	Site    string `json:"site"`
	Count   int    `json:"count"`
}
type Page struct {
	Items      []Device       `json:"items"`
	Total      int            `json:"total"`
	Counts     map[string]int `json:"counts"`
	Places     []Place        `json:"places"`
	Categories []string       `json:"categories"`
}
type Service struct {
	mu          sync.Mutex
	repo        Repository
	dir         string
	stations    func() ([]string, error)
	ports       StatusPorts
	statusIndex map[string]Device
}

func Open(repo Repository, dir string, stations func() ([]string, error), ports ...StatusPorts) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Service{repo: repo, dir: dir, stations: stations}
	if len(ports) > 0 {
		s.ports = ports[0]
	}
	return s, nil
}
func (s *Service) load() ([]Device, error) {
	items := []Device{}
	err := s.repo.LoadConfig("equipment_register", &items)
	return items, err
}
func (s *Service) store(items []Device) error {
	if err := s.repo.SaveConfig("equipment_register", items); err != nil {
		return err
	}
	s.statusIndex = nil
	return nil
}
func allowed(ctx context.Context, station string, edit bool) bool {
	a, managed := authorization.FromContext(ctx)
	return !managed || a.Active() && a.Station(station) && (!edit || a.Grants.Develop())
}
func find(items []Device, id string) int {
	for i, d := range items {
		if d.ID == id {
			return i
		}
	}
	return -1
}
func uid() (string, error) {
	b := make([]byte, 16)
	_, e := rand.Read(b)
	return hex.EncodeToString(b), e
}
func (s *Service) List(ctx context.Context, f Filter) (Page, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := Page{Items: []Device{}, Counts: map[string]int{"all": 0, "active": 0, "standby": 0, "maintenance": 0, "retired": 0}, Places: []Place{}, Categories: []string{}}
	if a, ok := authorization.FromContext(ctx); ok && !a.Active() {
		return out, authorization.ErrDenied
	}
	if f.Offset < 0 || f.Limit < 1 || f.Limit > 100 || len(f.Search) > 256 || len(f.Location) > 256 {
		return out, fmt.Errorf("分页或搜索参数无效")
	}
	items, err := s.load()
	if err != nil {
		return out, err
	}
	places := map[[2]string]int{}
	cats := map[string]bool{}
	matches := []Device{}
	for _, d := range items {
		if !allowed(ctx, d.Station, false) {
			continue
		}
		places[[2]string{d.Station, d.Site}]++
		cats[d.Category] = true
		if f.Station != "" && d.Station != f.Station || f.Site != "" && d.Site != f.Site || f.Category != "" && d.Category != f.Category || f.Location != "" && !strings.Contains(strings.ToLower(d.Location), strings.ToLower(f.Location)) || f.Search != "" && !strings.Contains(strings.ToLower(strings.Join([]string{d.Name, d.Code, d.Model, d.Manufacturer, d.Serial, d.Location, d.Site}, " ")), strings.ToLower(f.Search)) {
			continue
		}
		out.Counts["all"]++
		out.Counts[d.Status]++
		if f.Status != "" && d.Status != f.Status {
			continue
		}
		matches = append(matches, visibleDevice(ctx, d))
	}
	sort.Slice(matches, func(i, j int) bool {
		return matches[i].Updated > matches[j].Updated || matches[i].Updated == matches[j].Updated && matches[i].ID < matches[j].ID
	})
	out.Total = len(matches)
	if f.Offset < len(matches) {
		end := min(f.Offset+f.Limit, len(matches))
		out.Items = matches[f.Offset:end]
	}
	for k, n := range places {
		out.Places = append(out.Places, Place{k[0], k[1], n})
	}
	sort.Slice(out.Places, func(i, j int) bool {
		a, b := out.Places[i], out.Places[j]
		return a.Station < b.Station || a.Station == b.Station && a.Site < b.Site
	})
	for c := range cats {
		out.Categories = append(out.Categories, c)
	}
	sort.Strings(out.Categories)
	return out, nil
}
func (s *Service) Get(ctx context.Context, id string) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	items, e := s.load()
	if e != nil {
		return Device{}, e
	}
	i := find(items, id)
	if i < 0 || !allowed(ctx, items[i].Station, false) {
		return Device{}, ErrMissing
	}
	return visibleDevice(ctx, items[i]), nil
}
func (s *Service) Save(ctx context.Context, d Device) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !allowed(ctx, d.Station, true) {
		return Device{}, authorization.ErrDenied
	}
	if err := s.validateSignals(ctx, d.Signals); err != nil {
		return Device{}, err
	}
	items, e := s.load()
	if e != nil {
		return Device{}, e
	}
	i := find(items, d.ID)
	if d.ID != "" && (i < 0 || !allowed(ctx, items[i].Station, true)) {
		return Device{}, ErrMissing
	}
	if i >= 0 {
		if d.Revision != items[i].Revision {
			return Device{}, ErrConflict
		}
		d.Photos = items[i].Photos
		if d.Status == "" {
			d.Status = items[i].Status
		}
	} else {
		if d.Revision != 0 {
			return Device{}, ErrConflict
		}
		d.Photos = []Photo{}
		if len(items) >= 5000 {
			return Device{}, fmt.Errorf("首版最多5000份设备档案")
		}
	}
	d.Name = strings.TrimSpace(d.Name)
	d.Code = strings.TrimSpace(d.Code)
	d.Site = strings.TrimSpace(d.Site)
	d.Category = strings.TrimSpace(d.Category)
	if d.Name == "" || d.Code == "" || d.Station == "" || d.Category == "" {
		return Device{}, fmt.Errorf("请填写设备名称、编号、站区和类别")
	}
	for _, v := range []string{d.Name, d.Code, d.Site, d.Station, d.Category, d.Manufacturer, d.Model, d.Serial, d.Location} {
		if len(v) > 256 || strings.ContainsRune(v, 0) {
			return Device{}, fmt.Errorf("字段过长或包含无效字符")
		}
	}
	if len(d.Notes) > 6000 || len(d.Properties) > 32 {
		return Device{}, fmt.Errorf("备注最多6000字节，属性最多32项")
	}
	if d.Status != "" && d.Status != "active" && d.Status != "standby" && d.Status != "maintenance" && d.Status != "retired" {
		return Device{}, fmt.Errorf("设备状态无效")
	}
	if d.PhotoFit != "" && d.PhotoFit != "contain" && d.PhotoFit != "cover" && d.PhotoFit != "fill" {
		return Device{}, fmt.Errorf("图片显示方式无效")
	}
	if d.Installed != "" {
		if _, e := time.Parse("2006-01-02", d.Installed); e != nil {
			return Device{}, fmt.Errorf("投运日期请使用 YYYY-MM-DD")
		}
	}
	names, e := s.stations()
	if e != nil {
		return Device{}, e
	}
	exists := false
	for _, n := range names {
		if n == d.Station {
			exists = true
		}
	}
	if !exists {
		return Device{}, fmt.Errorf("所属站区不存在")
	}
	props := map[string]bool{}
	for _, p := range d.Properties {
		if strings.TrimSpace(p.Name) == "" || props[p.Name] || len(p.Name) > 128 || len(p.Value) > 512 || len(p.Unit) > 64 {
			return Device{}, fmt.Errorf("属性名称不能为空或重复，属性内容不能超长")
		}
		props[p.Name] = true
	}
	for j, v := range items {
		if j != i && strings.EqualFold(v.Code, d.Code) {
			return Device{}, fmt.Errorf("设备编号已存在")
		}
	}
	if i < 0 {
		d.ID, e = uid()
		if e != nil {
			return Device{}, e
		}
	}
	d.Revision++
	d.Updated = time.Now().UTC().Format(time.RFC3339Nano)
	if d.Properties == nil {
		d.Properties = []Property{}
	}
	if i < 0 {
		items = append(items, d)
	} else {
		items[i] = d
	}
	if !allowed(ctx, d.Station, true) {
		return Device{}, authorization.ErrDenied
	}
	if e = s.store(items); e != nil {
		return Device{}, e
	}
	return d, nil
}

// Photos are decoded and re-encoded: extensions and supplied MIME are not trusted.
func (s *Service) AddPhoto(ctx context.Context, id string, rev int64, name string, data []byte) (Device, error) {
	if len(data) == 0 || len(data) > 2*1024*1024 {
		return Device{}, fmt.Errorf("图片须为PNG或JPEG，且不超过2 MiB")
	}
	cfg, format, e := image.DecodeConfig(bytes.NewReader(data))
	if e != nil || (format != "png" && format != "jpeg") || cfg.Width < 1 || cfg.Height < 1 || cfg.Width > 6000 || cfg.Height > 6000 || int64(cfg.Width)*int64(cfg.Height) > 16000000 {
		return Device{}, fmt.Errorf("图片格式或尺寸无效，最多1600万像素")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	items, e := s.load()
	if e != nil {
		return Device{}, e
	}
	i := find(items, id)
	if i < 0 || !allowed(ctx, items[i].Station, true) {
		return Device{}, ErrMissing
	}
	d := items[i]
	if d.Revision != rev {
		return Device{}, ErrConflict
	}
	if len(d.Photos) >= 6 {
		return Device{}, fmt.Errorf("每台设备最多6张图片")
	}
	if len(name) > 256 {
		return Device{}, fmt.Errorf("图片名称过长")
	}
	decoded, _, e := image.Decode(bytes.NewReader(data))
	if e != nil {
		return Device{}, fmt.Errorf("图片损坏")
	}
	var out bytes.Buffer
	if format == "png" {
		e = png.Encode(&out, decoded)
	} else {
		e = jpeg.Encode(&out, decoded, &jpeg.Options{Quality: 88})
	}
	if e != nil {
		return Device{}, e
	}
	if out.Len() > 8*1024*1024 {
		return Device{}, fmt.Errorf("处理后的图片过大")
	}
	photoID, e := uid()
	if e != nil {
		return Device{}, e
	}
	path := filepath.Join(s.dir, photoID)
	if e = os.WriteFile(path, out.Bytes(), 0600); e != nil {
		return Device{}, e
	}
	d.Photos = append(d.Photos, Photo{photoID, filepath.Base(name), "image/" + format})
	d.Revision++
	d.Updated = time.Now().UTC().Format(time.RFC3339Nano)
	items[i] = d
	if !allowed(ctx, d.Station, true) {
		os.Remove(path)
		return Device{}, authorization.ErrDenied
	}
	if e = s.store(items); e != nil {
		os.Remove(path)
		return Device{}, e
	}
	return d, nil
}
func (s *Service) Photo(ctx context.Context, id, photoID string) (Photo, []byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	items, e := s.load()
	if e != nil {
		return Photo{}, nil, e
	}
	i := find(items, id)
	if i < 0 || !allowed(ctx, items[i].Station, false) {
		return Photo{}, nil, ErrMissing
	}
	for _, p := range items[i].Photos {
		if p.ID == photoID {
			b, e := os.ReadFile(filepath.Join(s.dir, p.ID))
			return p, b, e
		}
	}
	return Photo{}, nil, ErrMissing
}
func (s *Service) RemovePhoto(ctx context.Context, id, photoID string, rev int64) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	items, e := s.load()
	if e != nil {
		return Device{}, e
	}
	i := find(items, id)
	if i < 0 || !allowed(ctx, items[i].Station, true) {
		return Device{}, ErrMissing
	}
	d := items[i]
	if d.Revision != rev {
		return Device{}, ErrConflict
	}
	found := false
	photos := []Photo{}
	for _, p := range d.Photos {
		if p.ID == photoID {
			found = true
		} else {
			photos = append(photos, p)
		}
	}
	if !found {
		return Device{}, ErrMissing
	}
	d.Photos = photos
	d.Revision++
	d.Updated = time.Now().UTC().Format(time.RFC3339Nano)
	items[i] = d
	if e = s.store(items); e != nil {
		return Device{}, e
	}
	// Unreferenced images are retained for backup/recovery; never publicly served.
	return d, nil
}

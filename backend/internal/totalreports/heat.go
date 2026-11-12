package totalreports

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
)

type HeatBinding struct {
	Column  int    `json:"column"`
	Station string `json:"station"`
	Point   string `json:"point"`
	Unit    string `json:"unit"`
}
type CounterReader interface {
	Screens(context.Context) ([]externaldata.Screen, error)
	DailyCounters(context.Context, string, string, string, []externaldata.CounterBinding) ([]externaldata.CounterReading, error)
}
type HeatSettings struct {
	Revision int64  `json:"revision"`
	Screen   string `json:"screen"`
}

func (s *Service) SetCounterReader(reader CounterReader) { s.reader = reader }
func (s *Service) HeatSettings(ctx context.Context) (HeatSettings, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return HeatSettings{}, e
	}
	var v HeatSettings
	e := s.db.QueryRowContext(ctx, `SELECT revision,value FROM total_report_settings WHERE key='heat_source'`).Scan(&v.Revision, &v.Screen)
	if e == sql.ErrNoRows {
		e = nil
	}
	return v, e
}
func (s *Service) HeatSources(ctx context.Context) ([]externaldata.Screen, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return nil, e
	}
	if s.reader == nil {
		return []externaldata.Screen{}, nil
	}
	all, e := s.reader.Screens(ctx)
	if e != nil {
		return nil, e
	}
	out := []externaldata.Screen{}
	for _, v := range all {
		if v.Kind == "standard" {
			out = append(out, v)
		}
	}
	return out, nil
}
func (s *Service) SaveHeatSettings(ctx context.Context, in HeatSettings) (HeatSettings, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return HeatSettings{}, e
	}
	sources, e := s.HeatSources(ctx)
	if e != nil {
		return HeatSettings{}, e
	}
	found := false
	for _, source := range sources {
		if source.ID == in.Screen {
			found = true
		}
	}
	if !found {
		return HeatSettings{}, fmt.Errorf("请选择有权访问的标准历史来源")
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return HeatSettings{}, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`INSERT INTO total_report_settings(key,revision,value) VALUES('heat_source',0,'') ON CONFLICT(key) DO NOTHING`); e != nil {
		return HeatSettings{}, e
	}
	res, e := tx.Exec(`UPDATE total_report_settings SET revision=revision+1,value=? WHERE key='heat_source' AND revision=?`, in.Screen, in.Revision)
	if e != nil {
		return HeatSettings{}, e
	}
	n, e := res.RowsAffected()
	if e != nil {
		return HeatSettings{}, e
	}
	if n != 1 {
		return HeatSettings{}, ErrConflict
	}
	in.Revision++
	return in, tx.Commit()
}

type HeatSync struct {
	From string `json:"from"`
	To   string `json:"to"`
	Auto bool   `json:"auto,omitempty"`
}
type heatCacheEntry struct {
	at     time.Time
	result HeatSyncResult
}
type HeatSyncResult struct {
	Revision int64 `json:"revision"`
	Readings int   `json:"readings"`
	Valid    int   `json:"valid"`
	Changed  int   `json:"changed"`
}

func (s *Service) SyncHeat(ctx context.Context, year int, in HeatSync) (HeatSyncResult, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return HeatSyncResult{}, e
	}
	if s.reader == nil {
		return HeatSyncResult{}, fmt.Errorf("后台表底读取未配置")
	}
	select {
	case s.syncSlots <- struct{}{}:
		defer func() { <-s.syncSlots }()
	default:
		return HeatSyncResult{}, fmt.Errorf("已有热量同步正在进行，请稍后重试")
	}
	d, e := s.Document(ctx, "heat", year)
	if e != nil {
		return HeatSyncResult{}, e
	}
	if len(d.Template.Bindings) == 0 {
		return HeatSyncResult{}, fmt.Errorf("热表尚未绑定累计测点")
	}
	zone := time.FixedZone("Beijing", 8*3600)
	from, e := time.ParseInLocation("2006-01-02", in.From, zone)
	if e != nil {
		return HeatSyncResult{}, fmt.Errorf("开始日期无效")
	}
	to, e := time.ParseInLocation("2006-01-02", in.To, zone)
	first := time.Date(year, 11, 4, 0, 0, 0, 0, zone)
	last := time.Date(year+1, 4, 5, 0, 0, 0, 0, zone)
	if e != nil || from.Before(first) || to.After(last) || to.Before(from) || to.After(s.now().In(zone)) {
		return HeatSyncResult{}, fmt.Errorf("请同步采暖季基准日至今天之间的日期")
	}
	settings, e := s.HeatSettings(ctx)
	if e != nil {
		return HeatSyncResult{}, e
	}
	source := settings.Screen
	if source == "" {
		sources, e := s.HeatSources(ctx)
		if e != nil {
			return HeatSyncResult{}, e
		}
		if len(sources) != 1 {
			return HeatSyncResult{}, fmt.Errorf("请由工程师选择唯一的热量历史来源")
		}
		source = sources[0].ID
	}
	bindings := []externaldata.CounterBinding{}
	cacheKey := fmt.Sprintf("%d/%s/%d/%s/%s", year, source, settings.Revision, in.From, in.To)
	if cached, ok := s.heatCache[cacheKey]; in.Auto && ok && s.now().Sub(cached.at) < 5*time.Minute {
		return cached.result, nil
	}
	columns := map[string]int{}
	for _, b := range d.Template.Bindings {
		bindings = append(bindings, externaldata.CounterBinding{Station: b.Station, Point: b.Point, Unit: b.Unit})
		columns[b.Station+"/"+b.Point] = b.Column
	}
	readings, e := s.reader.DailyCounters(ctx, source, in.From, in.To, bindings)
	if e != nil {
		return HeatSyncResult{}, e
	}
	if len(readings) != len(bindings)*(int(to.Sub(from)/(24*time.Hour))+1) {
		return HeatSyncResult{}, fmt.Errorf("后台返回表底数量不完整")
	}
	key, _ := documentKey("heat", year)
	tx, rev, _, e := s.lock(ctx, key)
	if e != nil {
		return HeatSyncResult{}, e
	}
	defer tx.Rollback()
	var savedRevision int64
	var savedSource string
	e = tx.QueryRow(`SELECT revision,value FROM total_report_settings WHERE key='heat_source'`).Scan(&savedRevision, &savedSource)
	if e != nil && e != sql.ErrNoRows {
		return HeatSyncResult{}, e
	}
	if savedRevision != settings.Revision || savedSource != settings.Screen {
		return HeatSyncResult{}, ErrConflict
	}
	changed := []Cell{}
	seen := map[string]bool{}
	valid := 0
	for _, r := range readings {
		col, exists := columns[r.Station+"/"+r.Point]
		date, err := time.ParseInLocation("2006-01-02", r.Date, zone)
		if !exists || err != nil || date.Before(from) || date.After(to) {
			return HeatSyncResult{}, fmt.Errorf("后台表底身份或日期不匹配")
		}
		a := address(d.Template.HeaderRows+int(date.Sub(first)/(24*time.Hour)), col)
		if seen[a] {
			return HeatSyncResult{}, fmt.Errorf("重复的后台表底")
		}
		seen[a] = true
		value := ""
		if r.Value != nil {
			value = *r.Value
			if !numeric(value) {
				return HeatSyncResult{}, fmt.Errorf("后台表底不是支持的有限数值")
			}
			valid++
		}
		var old string
		e = tx.QueryRow(`SELECT value FROM total_report_cells WHERE doc=? AND address=?`, key, a).Scan(&old)
		if e != nil && e != sql.ErrNoRows {
			return HeatSyncResult{}, e
		}
		if old != value {
			changed = append(changed, Cell{Address: a, Value: value, Revision: rev + 1, Actor: "source"})
		}
		raw, err := json.Marshal(r)
		if err != nil {
			return HeatSyncResult{}, err
		}
		if _, e = tx.Exec(`INSERT INTO total_report_readings(doc,address,data) VALUES(?,?,?) ON CONFLICT(doc,address) DO UPDATE SET data=excluded.data WHERE total_report_readings.data<>excluded.data`, key, a, string(raw)); e != nil {
			return HeatSyncResult{}, e
		}
	}
	if len(changed) > 0 {
		rev++
		for _, c := range changed {
			if _, e = tx.Exec(`INSERT INTO total_report_cells(doc,address,value,revision,actor) VALUES(?,?,?,?,?) ON CONFLICT(doc,address) DO UPDATE SET value=excluded.value,revision=excluded.revision,actor=excluded.actor`, key, c.Address, c.Value, rev, "source"); e != nil {
				return HeatSyncResult{}, e
			}
		}
		if _, e = tx.Exec(`UPDATE total_report_docs SET revision=? WHERE doc=?`, rev, key); e != nil {
			return HeatSyncResult{}, e
		}
	}
	if _, e = permission(ctx, "read"); e != nil {
		return HeatSyncResult{}, e
	}
	result := HeatSyncResult{rev, len(readings), valid, len(changed)}
	if e = tx.Commit(); e != nil {
		return HeatSyncResult{}, e
	}
	for k, v := range s.heatCache {
		if s.now().Sub(v.at) >= 5*time.Minute {
			delete(s.heatCache, k)
		}
	}
	s.heatCache[cacheKey] = heatCacheEntry{s.now(), result}
	return result, nil
}
func (s *Service) HeatReadings(ctx context.Context, year int) ([]map[string]any, error) {
	if _, e := permission(ctx, "read"); e != nil {
		return nil, e
	}
	key, e := documentKey("heat", year)
	if e != nil {
		return nil, e
	}
	rows, e := s.db.QueryContext(ctx, `SELECT address,data FROM total_report_readings WHERE doc=? ORDER BY address`, key)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var a, raw string
		if e = rows.Scan(&a, &raw); e != nil {
			return nil, e
		}
		var v map[string]any
		if e = json.Unmarshal([]byte(raw), &v); e != nil {
			return nil, e
		}
		v["address"] = a
		out = append(out, v)
	}
	return out, rows.Err()
}

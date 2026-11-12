package totalreports

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/xuri/excelize/v2"
)

type HistoryBinding struct {
	ID              string `json:"id"`
	Range           string `json:"range"`
	Screen          string `json:"screen"`
	Station         string `json:"station"`
	Point           string `json:"point"`
	Unit            string `json:"unit"`
	Mode            string `json:"mode"`
	Start           string `json:"start"` // ISO date; {year} and {nextyear} are explicit parameters.
	DateCell        string `json:"date_cell,omitempty"`
	Direction       string `json:"direction"` // down or right; repeated date-cell references move likewise.
	StepDays        int    `json:"step_days"`
	OffsetDays      int    `json:"offset_days"`
	Time            string `json:"time"`
	DurationMinutes int    `json:"duration_minutes"`
	WindowMinutes   int    `json:"window_minutes"`
}
type HistoryBindingChange struct {
	Expected int64          `json:"expected"`
	Binding  HistoryBinding `json:"binding"`
	Remove   bool           `json:"remove"`
	Confirm  bool           `json:"confirm"`
}
type HistoryPreview struct {
	Address    string  `json:"address"`
	From       string  `json:"from"`
	To         string  `json:"to"`
	Value      *string `json:"value"`
	SampleTime *string `json:"sample_time,omitempty"`
	Quality    *int64  `json:"quality,omitempty"`
}
type reportHistoryReader interface {
	ReportPoints(context.Context, string, string) ([]externaldata.Point, error)
	ReportValues(context.Context, externaldata.ReportValueRequest) ([]externaldata.ReportValue, error)
	Stations(context.Context, string) ([]externaldata.Station, error)
}
type cellRect struct{ r0, c0, r1, c1 int }

func parseRect(s string) (cellRect, error) {
	p := strings.Split(strings.ToUpper(strings.TrimSpace(s)), ":")
	if len(p) == 1 {
		p = append(p, p[0])
	}
	if len(p) != 2 {
		return cellRect{}, fmt.Errorf("请选择有效区域，例如F14:F165")
	}
	c, r, e := excelize.CellNameToCoordinates(p[0])
	if e != nil {
		return cellRect{}, e
	}
	c1, r1, e := excelize.CellNameToCoordinates(p[1])
	if e != nil || r1 < r || c1 < c || r1 > 1000 || c1 > 100 {
		return cellRect{}, fmt.Errorf("区域越界或顺序无效")
	}
	return cellRect{r - 1, c - 1, r1 - 1, c1 - 1}, nil
}
func (v cellRect) contains(r, c int) bool { return r >= v.r0 && r <= v.r1 && c >= v.c0 && c <= v.c1 }
func (v cellRect) size() int              { return (v.r1 - v.r0 + 1) * (v.c1 - v.c0 + 1) }
func (v cellRect) text() string           { return address(v.r0, v.c0) + ":" + address(v.r1, v.c1) }
func templateRows(t Template, year int) int {
	if t.Rows > 0 {
		return t.Rows
	}
	a, b := season(year)
	return t.HeaderRows + int(b.Sub(a)/(24*time.Hour)) + 2
}
func historyOwned(t Template, r, c int) bool {
	for _, b := range t.History {
		v, e := parseRect(b.Range)
		if e == nil && v.contains(r, c) {
			return true
		}
	}
	return false
}

func validateHistory(t Template, year int) error {
	if len(t.History) > 64 {
		return fmt.Errorf("每张报表最多64组历史绑定")
	}
	occupied := map[string]bool{}
	ids := map[string]bool{}
	for _, b := range t.History {
		v, e := parseRect(b.Range)
		if e != nil {
			return e
		}
		if b.ID == "" || len(b.ID) > 80 || ids[b.ID] || v.r1 >= templateRows(t, year) || v.c1 >= t.Columns || v.size() > 366 || b.Station == "" || len(b.Station) > 32 || b.Point == "" || len(b.Point) > 128 || b.Unit == "" || len(b.Unit) > 32 || len(b.Screen) > 100 {
			return fmt.Errorf("历史绑定身份、区域或测点无效")
		}
		ids[b.ID] = true
		if b.Direction != "down" && b.Direction != "right" {
			return fmt.Errorf("请选择向下或向右填充")
		}
		if b.Direction == "down" && v.c0 != v.c1 || b.Direction == "right" && v.r0 != v.r1 {
			return fmt.Errorf("每组绑定请选择一列或一行，可分别配置多组")
		}
		if b.StepDays < 0 || b.StepDays > 366 || b.OffsetDays < -366 || b.OffsetDays > 366 || b.WindowMinutes < 0 || b.WindowMinutes > 180 || b.DurationMinutes < 0 || b.DurationMinutes > 31*1440 {
			return fmt.Errorf("时间步长、偏移或容差超出范围")
		}
		clock, e := time.Parse("15:04", b.Time)
		if e != nil || clock.Format("15:04") != b.Time {
			return fmt.Errorf("请输入HH:mm格式的取数时间")
		}
		switch b.Mode {
		case "nearest":
		case "min", "max", "average":
			if b.DurationMinutes == 0 {
				return fmt.Errorf("区间统计时长须大于0")
			}
		case "daily_usage", "daily_subtotal":
			if b.Time != "00:00" || b.DurationMinutes != 1440 {
				return fmt.Errorf("已结算日值按00:00开始的完整自然日读取")
			}
		default:
			return fmt.Errorf("取值方式无效")
		}
		if b.DateCell != "" {
			c, r, e := excelize.CellNameToCoordinates(b.DateCell)
			if e != nil || r > templateRows(t, year) || c > t.Columns {
				return fmt.Errorf("日期引用无效")
			}
			for i := 0; i < v.size(); i++ {
				rr, cc := r-1, c-1
				if b.Direction == "down" {
					rr += i
				} else {
					cc += i
				}
				if rr >= templateRows(t, year) || cc >= t.Columns || historyOwned(t, rr, cc) {
					return fmt.Errorf("日期引用越界或依赖另一自动取数格")
				}
			}
		} else {
			if _, e = parseBindingDate(b.Start, year); e != nil {
				return e
			}
		}
		for r := v.r0; r <= v.r1; r++ {
			for c := v.c0; c <= v.c1; c++ {
				a := address(r, c)
				if occupied[a] {
					return fmt.Errorf("%s存在重复绑定", a)
				}
				occupied[a] = true
				for _, m := range t.Merges {
					if r >= m.R && r < m.R+m.RS && c >= m.C && c < m.C+m.CS && (r != m.R || c != m.C) {
						return fmt.Errorf("历史绑定不能写入合并区域的从属格")
					}
				}
			}
		}
	}
	return nil
}
func parseBindingDate(raw string, year int) (time.Time, error) {
	raw = strings.NewReplacer("{year}", strconv.Itoa(year), "{nextyear}", strconv.Itoa(year+1)).Replace(raw)
	z := time.FixedZone("Beijing", 8*3600)
	d, e := time.ParseInLocation("2006-01-02", raw, z)
	if e != nil || d.Format("2006-01-02") != raw || d.Year() < 2000 || d.Year() > 2101 {
		return time.Time{}, fmt.Errorf("日期应为YYYY-MM-DD，可使用{year}或{nextyear}")
	}
	return d, nil
}
func bindingTargets(d Document, b HistoryBinding) ([]string, []externaldata.ReportTarget, error) {
	v, e := parseRect(b.Range)
	if e != nil {
		return nil, nil, e
	}
	values := map[string]string{}
	for _, c := range d.Cells {
		values[c.Address] = c.Value
	}
	clock, e := time.Parse("15:04", b.Time)
	if e != nil {
		return nil, nil, e
	}
	addresses := []string{}
	targets := []externaldata.ReportTarget{}
	for i := 0; i < v.size(); i++ {
		r, c := v.r0, v.c0
		if b.Direction == "down" {
			r += i
		} else {
			c += i
		}
		raw := b.Start
		days := i*b.StepDays + b.OffsetDays
		if b.DateCell != "" {
			cc, rr, _ := excelize.CellNameToCoordinates(b.DateCell)
			if b.Direction == "down" {
				rr += i
			} else {
				cc += i
			}
			raw = values[address(rr-1, cc-1)]
			days = b.OffsetDays
			if n, err := strconv.ParseFloat(raw, 64); err == nil {
				stamp, err := excelize.ExcelDateToTime(n, false)
				if err != nil {
					return nil, nil, fmt.Errorf("日期单元格无效")
				}
				raw = stamp.Format("2006-01-02")
			}
		}
		stamp, err := parseBindingDate(raw, d.Year)
		if err != nil {
			return nil, nil, fmt.Errorf("%s：%w", address(r, c), err)
		}
		stamp = stamp.AddDate(0, 0, days).Add(time.Duration(clock.Hour()*60+clock.Minute()) * time.Minute)
		addresses = append(addresses, address(r, c))
		targets = append(targets, externaldata.ReportTarget{From: stamp.Format(time.RFC3339), To: stamp.Add(time.Duration(b.DurationMinutes) * time.Minute).Format(time.RFC3339)})
	}
	return addresses, targets, nil
}

func (s *Service) HistoryCatalog(ctx context.Context, screen, station string) (any, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return nil, e
	}
	reader, ok := s.reader.(reportHistoryReader)
	if !ok {
		return nil, fmt.Errorf("后台历史接口未配置")
	}
	if screen == "" {
		items, e := s.reader.Screens(ctx)
		if e != nil {
			return nil, e
		}
		out := []externaldata.Screen{}
		for _, v := range items {
			if v.Kind == "standard" || v.Kind == "daily" {
				out = append(out, v)
			}
		}
		return map[string]any{"sources": out}, nil
	}
	if station == "" {
		v, e := reader.Stations(ctx, screen)
		return map[string]any{"stations": v}, e
	}
	v, e := reader.ReportPoints(ctx, screen, station)
	return map[string]any{"points": v}, e
}
func (s *Service) previewBinding(ctx context.Context, d Document, b HistoryBinding) ([]HistoryPreview, error) {
	reader, ok := s.reader.(reportHistoryReader)
	if !ok {
		return nil, fmt.Errorf("后台历史接口未配置")
	}
	t := d.Template
	t.History = []HistoryBinding{b}
	if e := validateHistory(t, d.Year); e != nil {
		return nil, e
	}
	addresses, targets, e := bindingTargets(d, b)
	if e != nil {
		return nil, e
	}
	screen := b.Screen
	if screen == "" {
		settings, e := s.HeatSettings(ctx)
		if e != nil {
			return nil, e
		}
		screen = settings.Screen
		if screen == "" {
			sources, e := s.HeatSources(ctx)
			if e != nil {
				return nil, e
			}
			if len(sources) != 1 {
				return nil, fmt.Errorf("请在绑定中选择数据来源")
			}
			screen = sources[0].ID
		}
	}
	// Future readings remain missing and are never sent to a historical source.
	active := []externaldata.ReportTarget{}
	indices := []int{}
	out := make([]HistoryPreview, len(targets))
	for i, t := range targets {
		out[i] = HistoryPreview{Address: addresses[i], From: t.From, To: t.To}
		end, _ := time.Parse(time.RFC3339, t.To)
		begin, _ := time.Parse(time.RFC3339, t.From)
		if b.Mode == "nearest" {
			end = begin
		}
		if !end.After(s.now()) {
			active = append(active, t)
			indices = append(indices, i)
		}
	}
	if len(active) == 0 {
		return out, nil
	}
	values, e := reader.ReportValues(ctx, externaldata.ReportValueRequest{Screen: screen, Station: b.Station, Point: b.Point, Unit: b.Unit, Mode: b.Mode, WindowMinutes: b.WindowMinutes, Targets: active})
	if e != nil {
		return nil, e
	}
	if len(values) != len(active) {
		return nil, fmt.Errorf("历史读取结果不完整")
	}
	for j, v := range values {
		if v.Target != active[j].From || v.Value != nil && !numeric(*v.Value) {
			return nil, fmt.Errorf("历史返回身份或数值无效")
		}
		i := indices[j]
		out[i].Value = v.Value
		out[i].SampleTime = v.SampleTime
		out[i].Quality = v.Quality
	}
	return out, nil
}
func (s *Service) PreviewHistory(ctx context.Context, kind string, year int, b HistoryBinding) ([]HistoryPreview, error) {
	if _, e := permission(ctx, "template"); e != nil {
		return nil, e
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return nil, e
	}
	return s.previewBinding(ctx, d, b)
}

func (s *Service) designCheckpoint(tx *persistence.Tx, key, actor string, rev int64, t Template) error {
	if _, e := s.checkpoint(tx, key, actor, "报表配置修改前", rev, true); e != nil {
		return e
	}
	raw, e := json.Marshal(t)
	if e != nil {
		return e
	}
	_, e = tx.Exec(`INSERT INTO total_report_design_history(doc,revision,created,actor,data) VALUES(?,?,?,?,?) ON CONFLICT(doc,revision) DO NOTHING`, key, rev, s.now().Unix(), actor, string(raw))
	return e
}
func (s *Service) ensureNoLeases(tx *persistence.Tx, key string, addresses map[string]bool) error {
	rows, e := tx.Query(`SELECT address FROM total_report_locks WHERE doc=? AND expires>?`, key, s.now().Unix())
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var a string
		if e = rows.Scan(&a); e != nil {
			return e
		}
		if addresses == nil || addresses[a] {
			return fmt.Errorf("%w：%s正在编辑，请稍后重试", ErrLocked, a)
		}
	}
	return rows.Err()
}
func (s *Service) SaveHistoryBinding(ctx context.Context, kind string, year int, in HistoryBindingChange) (Saved, error) {
	actor, e := permission(ctx, "template")
	if e != nil {
		return Saved{}, e
	}
	if !in.Confirm {
		return Saved{}, fmt.Errorf("请先预览并确认受影响区域")
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return Saved{}, e
	}
	if !in.Remove {
		if _, e = s.previewBinding(ctx, d, in.Binding); e != nil {
			return Saved{}, e
		}
	}
	key, _ := documentKey(kind, year)
	tx, rev, t, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	if rev != in.Expected {
		return Saved{}, ErrConflict
	}
	before := t
	next := []HistoryBinding{}
	affected := map[string]bool{}
	add := func(b HistoryBinding) {
		v, _ := parseRect(b.Range)
		for r := v.r0; r <= v.r1; r++ {
			for c := v.c0; c <= v.c1; c++ {
				affected[address(r, c)] = true
			}
		}
	}
	for _, b := range t.History {
		if b.ID == in.Binding.ID {
			add(b)
		} else {
			next = append(next, b)
		}
	}
	if !in.Remove {
		next = append(next, in.Binding)
		add(in.Binding)
	}
	t.History = next
	if e = validateHistory(t, year); e != nil {
		return Saved{}, e
	}
	if e = s.ensureNoLeases(tx, key, affected); e != nil {
		return Saved{}, e
	}
	if e = s.designCheckpoint(tx, key, actor, rev, before); e != nil {
		return Saved{}, e
	}
	rev++
	changed := []Cell{}
	for a := range affected {
		f, e := readFormat(tx, key, a)
		if e != nil {
			return Saved{}, e
		}
		c := Cell{Address: a, Value: "", Revision: rev, Actor: "configuration", Format: f}
		if e = writeCell(tx, key, c); e != nil {
			return Saved{}, e
		}
		changed = append(changed, c)
		if _, e = tx.Exec(`DELETE FROM total_report_readings WHERE doc=? AND address=?`, key, a); e != nil {
			return Saved{}, e
		}
	}
	raw, _ := json.Marshal(t)
	if _, e = tx.Exec(`UPDATE total_report_docs SET revision=?,template=? WHERE doc=?`, rev, string(raw), key); e != nil {
		return Saved{}, e
	}
	if _, e = permission(ctx, "template"); e != nil {
		return Saved{}, e
	}
	return Saved{rev, changed}, tx.Commit()
}
func (s *Service) RefreshHistory(ctx context.Context, kind string, year int) (Saved, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if _, e := permission(ctx, "read"); e != nil {
		return Saved{}, e
	}
	select {
	case s.syncSlots <- struct{}{}:
		defer func() { <-s.syncSlots }()
	default:
		return Saved{}, fmt.Errorf("历史读取正在进行，请稍后重试")
	}
	d, e := s.Document(ctx, kind, year)
	if e != nil {
		return Saved{}, e
	}
	all := []HistoryPreview{}
	for _, b := range d.Template.History {
		v, e := s.previewBinding(ctx, d, b)
		if e != nil {
			return Saved{}, e
		}
		all = append(all, v...)
	}
	key, _ := documentKey(kind, year)
	tx, rev, t, e := s.lock(ctx, key)
	if e != nil {
		return Saved{}, e
	}
	defer tx.Rollback()
	if rev != d.Revision || digest(t) != digest(d.Template) {
		return Saved{}, ErrConflict
	}
	changes := []Cell{}
	for _, v := range all {
		value := ""
		if v.Value != nil {
			value = *v.Value
		}
		var old string
		e = tx.QueryRow(`SELECT value FROM total_report_cells WHERE doc=? AND address=?`, key, v.Address).Scan(&old)
		if e != nil && e != sql.ErrNoRows {
			return Saved{}, e
		}
		if old != value {
			f, e := readFormat(tx, key, v.Address)
			if e != nil {
				return Saved{}, e
			}
			changes = append(changes, Cell{Address: v.Address, Value: value, Revision: rev + 1, Actor: "source", Format: f})
		}
		raw, _ := json.Marshal(v)
		if _, e = tx.Exec(`INSERT INTO total_report_readings(doc,address,data) VALUES(?,?,?) ON CONFLICT(doc,address) DO UPDATE SET data=excluded.data`, key, v.Address, string(raw)); e != nil {
			return Saved{}, e
		}
	}
	if len(changes) > 0 {
		rev++
		for _, c := range changes {
			if e = writeCell(tx, key, c); e != nil {
				return Saved{}, e
			}
		}
		if _, e = tx.Exec(`UPDATE total_report_docs SET revision=? WHERE doc=?`, rev, key); e != nil {
			return Saved{}, e
		}
	}
	if _, e = permission(ctx, "read"); e != nil {
		return Saved{}, e
	}
	return Saved{rev, changes}, tx.Commit()
}

func legacyHistory(t Template, year int) []HistoryBinding {
	last := templateRows(t, year) - 1
	out := []HistoryBinding{}
	for _, b := range t.Bindings {
		out = append(out, HistoryBinding{ID: fmt.Sprintf("legacy_%d", b.Column), Range: address(t.HeaderRows, b.Column) + ":" + address(last, b.Column), Station: b.Station, Point: b.Point, Unit: b.Unit, Mode: "nearest", Start: "{year}-11-05", Direction: "down", StepDays: 1, Time: "00:00", WindowMinutes: 30})
	}
	return out
}

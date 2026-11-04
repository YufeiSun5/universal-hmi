package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Decimal values remain strings. Subtotal is diagnostic and is never promoted
// to a valid day usage when the database reports an incomplete day.
type Statistic struct {
	DayRecord     *string `json:"day_record,omitempty"`
	ValidHours    *string `json:"valid_hours,omitempty"`
	DayStatusCode *string `json:"day_status_code,omitempty"`
	DayAnomaly    *string `json:"day_anomaly,omitempty"`
	Station       string  `json:"station"`
	Name          string  `json:"name"`
	Metric        string  `json:"metric"`
	Label         string  `json:"label"`
	Unit          string  `json:"unit"`
	Date          string  `json:"date"`
	Hour          *string `json:"hour"`
	SampleMin     *string `json:"sample_min"`
	SampleMax     *string `json:"sample_max"`
	HourUsage     *string `json:"hour_usage"`
	HourMin       *string `json:"hour_min"`
	HourMax       *string `json:"hour_max"`
	HourStatus    *string `json:"hour_status"`
	DayUsage      *string `json:"day_usage"`
	DayMin        *string `json:"day_min"`
	DayMax        *string `json:"day_max"`
	DaySubtotal   *string `json:"day_subtotal"`
	DayStatus     *string `json:"day_status"`
	CurrentDay    bool    `json:"current_day"`
}

var beijing = time.FixedZone("Asia/Shanghai", 8*3600)
var siteCode = regexp.MustCompile(`^[0-9]{2}-[0-9]{3}$`)
var siteNames = map[string]string{
	"01-001": "中心站", "01-002": "景泰中央公园站", "01-003": "香港广场站", "01-004": "阳光壹佰站", "01-005": "华府怡景站",
	"02-001": "新北站", "02-002": "北站三号炉站", "02-003": "国奥首站", "02-004": "国奥一期站", "02-005": "国奥二期站",
	"03-001": "新西站", "03-002": "红光美苑站", "03-003": "红光美苑首站", "04-001": "新南站", "04-002": "金岳福里站", "04-003": "张屯站",
}

func siteName(code string) string {
	if n := siteNames[code]; n != "" {
		return n
	}
	return "站名待维护"
}
func energyStations(zones []Station) []Station {
	out := []Station{}
	seen := map[string]bool{}
	for _, z := range zones {
		if len(z.Code) >= 6 {
			code := z.Code[:6]
			if siteCode.MatchString(code) && !seen[code] {
				seen[code] = true
				out = append(out, Station{Code: code, Name: siteName(code)})
			}
		}
	}
	return out
}
func statisticsBounds(kind string, in Request, now time.Time) (time.Time, time.Time, string, error) {
	today := now.In(beijing).Format("2006-01-02")
	mode := kind
	if kind == "energy" {
		mode = in.Mode
		if mode == "" {
			mode = "current"
		}
		if mode == "hourly" {
			return time.Time{}, time.Time{}, mode, fmt.Errorf("能耗管理仅支持总览和按日查询，小时统计请使用历史模块的小时报")
		}
	}
	if mode != "current" && mode != "hourly" && mode != "daily" && mode != "zones" {
		return time.Time{}, time.Time{}, mode, fmt.Errorf("请选择有效统计方式")
	}
	start, end := in.Date, in.Date
	if mode == "current" {
		start = today
		end = today
	}
	if mode == "daily" && in.From != "" {
		start = in.From
		end = in.To
	}
	a, e := time.ParseInLocation("2006-01-02", start, beijing)
	b, e2 := time.ParseInLocation("2006-01-02", end, beijing)
	if e != nil || e2 != nil || start < periodStart || b.Before(a) || b.Sub(a) > 30*24*time.Hour || end > today || in.Offset != 0 || len(in.Station) > 32 || strings.Contains(in.Station, ",") || (kind != "energy" && strings.TrimSpace(in.Station) == "") || (kind == "energy" && in.Station != "" && !siteCode.MatchString(in.Station)) || (kind == "energy" && (mode == "hourly" || mode == "zones") && in.Station == "") {
		return a, b, mode, fmt.Errorf("请选择有效站点和2026-11-04至今天的日期，日查询最多31天，小时趋势与站区明细须选择单站")
	}
	return a, b, mode, nil
}

const statisticsProcedure = `EXEC dbo.usp_查询站区当前统计 @站区编码=@zones,@整站编码=@site,@按整站=@whole,@报表日期=@date,@逐小时=@hourly,@查询时刻UTC=@asof`

func (s *Service) queryStatistics(ctx context.Context, source storedSource, view Screen, in Request) (Result, error) {
	now := time.Now().UTC()
	start, end, mode, e := statisticsBounds(view.Kind, in, now)
	if e != nil {
		return Result{}, e
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, source)
	if e != nil {
		return Result{}, e
	}
	defer close()
	var zones, site any
	whole := view.Kind == "energy" && mode != "zones"
	if whole {
		if in.Station != "" {
			site = in.Station
		}
	} else {
		zones = in.Station
	}
	zoneMetrics := map[string]string{}
	if view.Kind == "energy" && mode == "zones" {
		rows, err := db.QueryContext(ctx, `SELECT s.StationCode,p.PointCode,w.输出列 FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId LEFT JOIN dbo.统计宽表列配置 w ON w.PointId=p.PointId AND w.StationId=s.StationId WHERE s.IsEnabled=1 AND LEFT(s.StationCode,6)=@site AND p.PointCode IN ('ER_TotalHeat','ER_MakeupFlowTotal','ER_ActiveEnergyTotal') ORDER BY s.StationCode,p.PointCode`, sql.Named("site", in.Station))
		if err != nil {
			return Result{}, statisticsError(ctx)
		}
		codes := []string{}
		seen := map[string]bool{}
		for rows.Next() {
			var code, point string
			var column sql.NullString
			if err = rows.Scan(&code, &point, &column); err != nil {
				break
			}
			if !strings.HasPrefix(code, in.Station+"-") || strings.Contains(code, ",") || len(codes) > 256 {
				err = fmt.Errorf("invalid zone")
				break
			}
			if !seen[code] {
				codes = append(codes, code)
				seen[code] = true
			}
			if column.Valid {
				zoneMetrics[code+"/"+column.String] = energyMetric(point)
			}
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
		if err != nil {
			return Result{}, statisticsError(ctx)
		}
		if len(codes) == 0 {
			return Result{}, fmt.Errorf("此站尚无可查询的水电热测点")
		}
		zones = strings.Join(codes, ",")
	}
	result := Result{Points: []Point{}, Rows: []Row{}, Statistics: []Statistic{}, UTCOffsetMinutes: 480, SourceRevision: source.Revision, ScreenRevision: view.Revision, StatisticsColumns: view.StatisticsColumns}
	seen := map[string]bool{}
	for day := start; !day.After(end); day = day.AddDate(0, 0, 1) {
		rows, err := db.QueryContext(ctx, statisticsProcedure, sql.Named("zones", zones), sql.Named("site", site), sql.Named("whole", whole), sql.Named("date", day.Format("2006-01-02")), sql.Named("hourly", mode == "hourly"), sql.Named("asof", now))
		if err != nil {
			return Result{}, statisticsError(ctx)
		}
		batch, err := scanStatistics(rows, whole, day.Format("2006-01-02"), now.In(beijing).Format("2006-01-02"))
		rows.Close()
		if err != nil {
			return Result{}, statisticsError(ctx)
		}
		for _, r := range batch {
			if view.Kind == "energy" {
				if whole {
					r.Metric = energyMetric(r.Label)
				} else {
					r.Metric = zoneMetrics[r.Station+"/"+r.Metric]
				}
				if r.Metric == "" {
					continue
				}
			}
			if in.Station != "" && ((whole && r.Station != in.Station) || (!whole && mode != "zones" && r.Station != in.Station) || (mode == "zones" && !strings.HasPrefix(r.Station, in.Station+"-"))) {
				return Result{}, statisticsError(ctx)
			}
			key := r.Date + "/" + r.Station + "/" + r.Metric
			if mode == "hourly" && r.Hour != nil {
				key += "/" + *r.Hour
			}
			if seen[key] {
				return Result{}, fmt.Errorf("数据库返回重复统计记录，请核对配置")
			}
			seen[key] = true
			result.Statistics = append(result.Statistics, r)
			if len(result.Statistics) > 25000 {
				return Result{}, fmt.Errorf("统计结果过大，请缩小范围")
			}
		}
	}
	if !mayRead(ctx, view.ID) {
		return Result{}, authorizationDenied()
	}
	sort.SliceStable(result.Statistics, func(i, j int) bool {
		a, b := result.Statistics[i], result.Statistics[j]
		return a.Date+a.Station+value(a.Hour)+a.Metric < b.Date+b.Station+value(b.Hour)+b.Metric
	})
	return result, nil
}
func energyMetric(s string) string {
	switch s {
	case "ER_ActiveEnergyTotal", "耗电量":
		return "electricity"
	case "ER_MakeupFlowTotal", "补水量":
		return "water"
	case "ER_TotalHeat", "一次网耗热量":
		return "heat"
	}
	return ""
}
func value(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
func statisticsError(ctx context.Context) error {
	if ctx.Err() != nil {
		return queryError(ctx)
	}
	return fmt.Errorf("统计查询失败，请核对KIOHistory六参数统计过程、统计配置和只读执行权限（不能用整点采样替代）")
}

func scanStatistics(rows *sql.Rows, whole bool, date, today string) ([]Statistic, error) {
	cols, e := rows.Columns()
	if e != nil {
		return nil, e
	}
	required := []string{"站区编码", "站区名称", "输出列", "测点", "单位", "当前小时起点", "最新参与采样时间", "当前小时差额", "当前小时最小值", "当前小时最大值", "当前小时状态", "今日有效差额小计", "今日最小值", "今日最大值", "今日状态"}
	if whole {
		required = []string{"整站编码", "指标", "单位", "当前小时起点", "成员最早最新采样时间", "成员最晚最新采样时间", "当前小时用量", "当前小时状态", "今日用量", "今日状态"}
	}
	colset := map[string]bool{}
	for _, c := range cols {
		colset[c] = true
	}
	for _, c := range required {
		if !colset[c] {
			return nil, fmt.Errorf("missing column %s", c)
		}
	}
	out := []Statistic{}
	for rows.Next() {
		vals := make([]any, len(cols))
		dest := make([]any, len(cols))
		for i := range vals {
			dest[i] = &vals[i]
		}
		if e = rows.Scan(dest...); e != nil {
			return nil, e
		}
		m := map[string]*string{}
		for i, c := range cols {
			if vals[i] == nil {
				continue
			}
			var v string
			switch x := vals[i].(type) {
			case time.Time:
				v = x.Format("2006-01-02T15:04:05.999999999") + "+08:00"
			case []byte:
				v = string(x)
			case string:
				v = x
			default:
				v = fmt.Sprint(x)
			}
			m[c] = &v
		}
		r := Statistic{Date: date, CurrentDay: date == today, Unit: value(m["单位"]), Hour: m["当前小时起点"], HourStatus: m["当前小时状态"], DayStatus: m["今日状态"]}
		if whole {
			r.Station = value(m["整站编码"])
			r.Name = siteName(r.Station)
			r.Label = value(m["指标"])
			r.Metric = r.Label
			r.HourUsage = m["当前小时用量"]
			r.DayUsage = m["今日用量"]
			r.SampleMin = m["成员最早最新采样时间"]
			r.SampleMax = m["成员最晚最新采样时间"]
		} else {
			r.Station = value(m["站区编码"])
			r.Name = value(m["站区名称"])
			r.Metric = value(m["输出列"])
			r.Label = value(m["测点"])
			r.HourUsage = m["当前小时差额"]
			r.HourMin = m["当前小时最小值"]
			r.HourMax = m["当前小时最大值"]
			r.DayUsage = m["今日有效差额小计"]
			r.DaySubtotal = r.DayUsage
			r.DayMin = m["今日最小值"]
			r.DayMax = m["今日最大值"]
			r.SampleMin = m["最新参与采样时间"]
			r.SampleMax = r.SampleMin
		}
		if r.Station == "" || r.Metric == "" || r.Hour == nil || !strings.HasPrefix(*r.Hour, date) {
			return nil, fmt.Errorf("invalid statistics identity or date")
		}
		if !whole && value(r.DayStatus) != "截至采样有效" {
			r.DayUsage = nil
		}
		out = append(out, r)
		if len(out) > 25000 {
			return nil, fmt.Errorf("statistics row limit")
		}
	}
	return out, rows.Err()
}

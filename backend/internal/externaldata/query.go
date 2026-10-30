package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"

	_ "github.com/microsoft/go-mssqldb"
)

type openDatabase func(context.Context, Source, string) (*sql.DB, error)

func connect(ctx context.Context, v Source, password string) (*sql.DB, error) {
	u := url.URL{Scheme: "sqlserver", Host: net.JoinHostPort(v.Host, strconv.Itoa(v.Port)), User: url.UserPassword(v.Username, password)}
	q := url.Values{"database": {v.Database}, "encrypt": {strconv.FormatBool(v.Encrypt)}, "TrustServerCertificate": {strconv.FormatBool(v.TrustCertificate)}, "connection timeout": {"8"}, "app name": {"Universal HMI external history"}, "ApplicationIntent": {"ReadOnly"}}
	u.RawQuery = q.Encode()
	db, e := sql.Open("sqlserver", u.String())
	if e != nil {
		return nil, e
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(time.Minute)
	if e = db.PingContext(ctx); e != nil {
		db.Close()
		return nil, e
	}
	return db, nil
}
func (s *Service) database(ctx context.Context, v storedSource) (*sql.DB, func(), error) {
	select {
	case s.slots <- struct{}{}:
	default:
		return nil, nil, fmt.Errorf("外数据查询繁忙，请稍后重试")
	}
	release := func() { <-s.slots }
	password, e := s.password(v)
	if e != nil {
		release()
		return nil, nil, e
	}
	db, e := s.open(ctx, v.Source, password)
	if e != nil {
		release()
		return nil, nil, fmt.Errorf("无法连接外部数据库，请检查服务器、端口、账号及证书设置")
	}
	return db, func() { db.Close(); release() }, nil
}
func queryError(ctx context.Context) error {
	if ctx.Err() != nil {
		return fmt.Errorf("外数据查询超时或已取消，请缩小查询范围")
	}
	return fmt.Errorf("外数据查询失败，请检查KIOHistory表结构和只读账号权限")
}

type Station struct {
	Code string `json:"code"`
	Name string `json:"name"`
}
type Point struct {
	Code   string `json:"code"`
	Name   string `json:"name"`
	Unit   string `json:"unit"`
	Column string `json:"-"`
}
type Row struct {
	TargetTime string    `json:"target_time"`
	SampleTime *string   `json:"sample_time"`
	Quality    *int64    `json:"quality"`
	Match      string    `json:"match"`
	Values     []*string `json:"values"`
}
type Result struct {
	Points           []Point `json:"points"`
	Rows             []Row   `json:"rows"`
	HasMore          bool    `json:"has_more"`
	Offset           int     `json:"offset"`
	UTCOffsetMinutes int     `json:"utc_offset_minutes"`
	SourceRevision   int64   `json:"source_revision"`
	ScreenRevision   int64   `json:"screen_revision"`
}
type Request struct {
	Station string `json:"station"`
	Date    string `json:"date"`
	From    string `json:"from"`
	To      string `json:"to"`
	Offset  int    `json:"offset"`
}

func (s *Service) Test(ctx context.Context, id string) error {
	v, _, e := s.source(ctx, id, false)
	if e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, v)
	if e != nil {
		return e
	}
	defer close()
	// The fixed schema is checked without reading history or executing a procedure.
	rows, e := db.QueryContext(ctx, "SELECT TOP (0) s.StationCode,p.PointCode,h.SampleTime,h.QualityCode,h.Value01,h.Value60 FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId JOIN dbo.StationSample h ON h.StationId=s.StationId")
	if e != nil {
		return queryError(ctx)
	}
	return rows.Close()
}
func (s *Service) Stations(ctx context.Context, id string) ([]Station, error) {
	v, _, e := s.source(ctx, id, true)
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, v)
	if e != nil {
		return nil, e
	}
	defer close()
	rows, e := db.QueryContext(ctx, "SELECT TOP (257) StationCode,StationName FROM dbo.Station WHERE IsEnabled=1 ORDER BY StationCode")
	if e != nil {
		return nil, queryError(ctx)
	}
	defer rows.Close()
	out := []Station{}
	for rows.Next() {
		var st Station
		if e = rows.Scan(&st.Code, &st.Name); e != nil {
			return nil, queryError(ctx)
		}
		out = append(out, st)
	}
	if rows.Err() != nil {
		return nil, queryError(ctx)
	}
	if len(out) > 256 {
		return nil, fmt.Errorf("数据源启用站区超过256个，请缩小数据源范围")
	}
	if !mayRead(ctx, id) {
		return nil, authorizationDenied()
	}
	return out, nil
}
func authorizationDenied() error { return authorization.ErrDenied }

func validColumn(v string) bool {
	if len(v) != 7 || !strings.HasPrefix(v, "Value") {
		return false
	}
	n, e := strconv.Atoi(v[5:])
	return e == nil && n >= 1 && n <= 60 && fmt.Sprintf("Value%02d", n) == v
}
func loadPoints(ctx context.Context, db *sql.DB, station string) ([]Point, error) {
	rows, e := db.QueryContext(ctx, `SELECT TOP (61) p.PointCode,p.PointName,COALESCE(p.Unit,''),p.SampleColumn,p.ValueType
 FROM dbo.Point p JOIN dbo.Station s ON s.StationId=p.StationId
 WHERE s.StationCode=@station AND s.IsEnabled=1 AND p.IsEnabled=1 AND p.DeviceId IS NULL AND p.SampleTable='StationSample' ORDER BY p.PointCode`, sql.Named("station", station))
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Point{}
	codes, columns := map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var p Point
		var kind string
		if e = rows.Scan(&p.Code, &p.Name, &p.Unit, &p.Column, &kind); e != nil {
			return nil, e
		}
		if !validColumn(p.Column) || strings.TrimSpace(p.Code) == "" || strings.TrimSpace(p.Name) == "" || !strings.Contains("NBE", kind) || len(kind) != 1 || codes[p.Code] || columns[p.Column] {
			return nil, fmt.Errorf("invalid mapping")
		}
		codes[p.Code] = true
		columns[p.Column] = true
		out = append(out, p)
	}
	if len(out) > 60 {
		return nil, fmt.Errorf("too many points")
	}
	return out, rows.Err()
}
func columns(points []Point) string {
	out := make([]string, len(points))
	for i, p := range points {
		out[i] = "CONVERT(varchar(64),sample.[" + p.Column + "])"
	}
	return strings.Join(out, ",")
}
func querySQL(kind string, points []Point) string {
	selectValues := columns(points)
	if kind == "hourly" {
		return `WITH Hours(n) AS (SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23)) x(n))
 SELECT DATEADD(hour,h.n,CONVERT(datetime2(3),@from)),sample.SampleTime,sample.QualityCode,` + selectValues + `
 FROM dbo.Station s CROSS JOIN Hours h
 OUTER APPLY (SELECT TOP (1) data.* FROM dbo.StationSample data
 WHERE data.StationId=s.StationId AND data.SampleTime>=DATEADD(minute,-30,DATEADD(hour,h.n,CONVERT(datetime2(3),@from))) AND data.SampleTime<=DATEADD(minute,30,DATEADD(hour,h.n,CONVERT(datetime2(3),@from)))
 ORDER BY ABS(DATEDIFF_BIG(millisecond,DATEADD(hour,h.n,CONVERT(datetime2(3),@from)),data.SampleTime)),data.SampleTime) sample
 WHERE s.IsEnabled=1 AND s.StationCode=@station ORDER BY h.n`
	}
	return `SELECT sample.SampleTime,sample.SampleTime,sample.QualityCode,` + selectValues + `
 FROM dbo.StationSample sample JOIN dbo.Station s ON s.StationId=sample.StationId
 WHERE s.IsEnabled=1 AND s.StationCode=@station AND sample.SampleTime>=CONVERT(datetime2(3),@from) AND sample.SampleTime<CONVERT(datetime2(3),@to)
 ORDER BY sample.SampleTime OFFSET @offset ROWS FETCH NEXT 501 ROWS ONLY`
}
func bounds(kind string, in Request, offset int) (time.Time, time.Time, error) {
	zone := time.FixedZone("source", offset*60)
	var from, to time.Time
	var e error
	if kind == "hourly" {
		from, e = time.ParseInLocation("2006-01-02", in.Date, zone)
		to = from.Add(24 * time.Hour)
	} else {
		from, e = time.ParseInLocation("2006-01-02T15:04", in.From, zone)
		if e == nil {
			to, e = time.ParseInLocation("2006-01-02T15:04", in.To, zone)
		}
	}
	if e != nil || from.Year() < 2000 || from.Year() > 2100 || to.After(time.Date(2101, 1, 1, 0, 0, 0, 0, zone)) || !to.After(from) || to.Sub(from) > 31*24*time.Hour || in.Offset < 0 || in.Offset > 100000 || in.Offset%500 != 0 || len(in.Station) > 32 || strings.TrimSpace(in.Station) == "" {
		return from, to, fmt.Errorf("请选择有效站区、2000–2100年日期和不超过31天的时间范围")
	}
	return from.UTC(), to.UTC(), nil
}
func (s *Service) Query(ctx context.Context, id string, in Request) (Result, error) {
	result := Result{Points: []Point{}, Rows: []Row{}}
	v, view, e := s.source(ctx, id, true)
	if e != nil {
		return result, e
	}
	from, to, e := bounds(view.Kind, in, v.UTCOffsetMinutes)
	if e != nil {
		return result, e
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, close, e := s.database(ctx, v)
	if e != nil {
		return result, e
	}
	defer close()
	points, e := loadPoints(ctx, db, in.Station)
	if e != nil {
		return result, queryError(ctx)
	}
	if len(points) == 0 {
		return result, fmt.Errorf("此站区不存在、未启用或没有有效的站区采样点定义")
	}
	args := []any{sql.Named("station", in.Station), sql.Named("from", from)}
	if view.Kind != "hourly" {
		args = append(args, sql.Named("to", to), sql.Named("offset", in.Offset))
	}
	rows, e := db.QueryContext(ctx, querySQL(view.Kind, points), args...)
	if e != nil {
		return result, queryError(ctx)
	}
	defer rows.Close()
	zone := time.FixedZone("source", v.UTCOffsetMinutes*60)
	for rows.Next() {
		var target time.Time
		var sample sql.NullTime
		var quality sql.NullInt64
		vals := make([]sql.NullString, len(points))
		dest := []any{&target, &sample, &quality}
		for i := range vals {
			dest = append(dest, &vals[i])
		}
		if e = rows.Scan(dest...); e != nil {
			return Result{}, queryError(ctx)
		}
		r := Row{TargetTime: target.In(zone).Format(time.RFC3339Nano), Match: "missing", Values: make([]*string, len(points))}
		if sample.Valid {
			ts := sample.Time.In(zone).Format(time.RFC3339Nano)
			r.SampleTime = &ts
			r.Match = "exact"
			if !sample.Time.Equal(target) {
				r.Match = "nearest"
			}
		}
		if quality.Valid {
			n := quality.Int64
			r.Quality = &n
		}
		if sample.Valid && quality.Valid && (quality.Int64 == 1 || quality.Int64 == 2) {
			for i, val := range vals {
				if val.Valid {
					value := val.String
					r.Values[i] = &value
				}
			}
		}
		result.Rows = append(result.Rows, r)
	}
	if rows.Err() != nil {
		return Result{}, queryError(ctx)
	}
	if !mayRead(ctx, id) {
		return Result{}, authorizationDenied()
	}
	if len(result.Rows) > 500 {
		result.HasMore = true
		result.Rows = result.Rows[:500]
	}
	result.Points = points
	result.Offset = in.Offset
	result.UTCOffsetMinutes = v.UTCOffsetMinutes
	result.SourceRevision = v.Revision
	result.ScreenRevision = view.Revision
	return result, nil
}

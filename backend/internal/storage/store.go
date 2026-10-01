package storage

import (
 "context"
 "database/sql"
 "encoding/json"
 "fmt"
 "math"
 "path/filepath"
 "os"
 "strings"
 "time"
 _ "modernc.org/sqlite"
)

type Sample struct {
 Seq int64 `json:"seq"`
 PointID string `json:"point_id"`
 Station string `json:"station"`
 Name string `json:"name"`
 Value any `json:"value"`
 Raw any `json:"raw"`
 Unit string `json:"unit"`
 Quality string `json:"quality"`
 SourceTime time.Time `json:"source_time"`
 ReceivedTime time.Time `json:"received_time"`
 Version string `json:"version"`
}
type Filter struct {
 PointID string
 Station string
 Quality string
 From int64
 To int64
 Min *float64
 Max *float64
 Before int64
 After int64
 Limit int
 Offset int
}
type Stats struct { Count int `json:"count"`; Min *float64 `json:"min"`; Max *float64 `json:"max"`; Mean *float64 `json:"mean"`; First int64 `json:"first"`; Last int64 `json:"last"` }
type Store struct{ DB *sql.DB }
func Open(dir string)(*Store,error){
 if err:=os.MkdirAll(dir,0700);err!=nil{return nil,err}
 db,err:=sql.Open("sqlite",filepath.Join(dir,"history.db"));if err!=nil{return nil,err}
 db.SetMaxOpenConns(1)
 for _,q:=range []string{
 "PRAGMA journal_mode=WAL","PRAGMA busy_timeout=3000",
 "CREATE TABLE IF NOT EXISTS samples(seq INTEGER PRIMARY KEY AUTOINCREMENT,point_id TEXT NOT NULL,station TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,raw TEXT NOT NULL,numeric REAL,unit TEXT NOT NULL,quality TEXT NOT NULL,source_time INTEGER NOT NULL,received_time INTEGER NOT NULL,version TEXT NOT NULL)",
 "CREATE INDEX IF NOT EXISTS sample_point_time ON samples(point_id,source_time)",
 "CREATE INDEX IF NOT EXISTS sample_station_time ON samples(station,source_time)",
 "CREATE TABLE IF NOT EXISTS config(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
 "CREATE TABLE IF NOT EXISTS executions(seq INTEGER PRIMARY KEY AUTOINCREMENT,at INTEGER NOT NULL,data TEXT NOT NULL)",
 }{if _,err=db.Exec(q);err!=nil{db.Close();return nil,err}}
 return &Store{db},nil
}
func(s *Store) Close()error{return s.DB.Close()}
func(s *Store) SaveConfig(key string,v any)error{
 b,err:=json.Marshal(v);if err!=nil{return err}
 _,err=s.DB.Exec("INSERT INTO config(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",key,string(b));return err
}
func(s *Store) LoadConfig(key string,v any)error{
 var data string;err:=s.DB.QueryRow("SELECT value FROM config WHERE key=?",key).Scan(&data)
 if err==sql.ErrNoRows{return nil};if err!=nil{return err};return json.Unmarshal([]byte(data),v)
}
func(s *Store) Append(ctx context.Context,rows []Sample)error{
 tx,err:=s.DB.BeginTx(ctx,nil);if err!=nil{return err};defer tx.Rollback()
 st,err:=tx.PrepareContext(ctx,"INSERT INTO samples(point_id,station,name,value,raw,numeric,unit,quality,source_time,received_time,version) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
 if err!=nil{return err};defer st.Close()
 for _,r:=range rows{
  value,err:=json.Marshal(r.Value);if err!=nil{return err};raw,err:=json.Marshal(r.Raw);if err!=nil{return err}
  var numeric any
  if n,ok:=r.Value.(float64);ok && !math.IsNaN(n)&&!math.IsInf(n,0){numeric=n}
  if _,err=st.ExecContext(ctx,r.PointID,r.Station,r.Name,string(value),string(raw),numeric,r.Unit,r.Quality,r.SourceTime.UnixMilli(),r.ReceivedTime.UnixMilli(),r.Version);err!=nil{return err}
 }
 return tx.Commit()
}
func where(f Filter)(string,[]any){
 clauses:=[]string{"1=1"};args:=[]any{}
 add:=func(q string,a any){clauses=append(clauses,q);args=append(args,a)}
 if f.PointID!=""{add("point_id=?",f.PointID)}
 if f.Station!=""{add("station=?",f.Station)}
 if f.Quality!=""{add("quality=?",f.Quality)}
 if f.From>0{add("source_time>=?",f.From)}
 if f.To>0{add("source_time<=?",f.To)}
 if f.Before!=0{add("seq<=?",f.Before)}
 if f.After>0{add("seq>?",f.After)}
 if f.Min!=nil{add("numeric>=?",*f.Min)}
 if f.Max!=nil{add("numeric<=?",*f.Max)}
 return strings.Join(clauses," AND "),args
}
func(s *Store) Query(ctx context.Context,f Filter)([]Sample,error){
 if f.Limit<=0||f.Limit>5000{f.Limit=1000};if f.Offset<0{f.Offset=0}
 w,args:=where(f);args=append(args,f.Limit,f.Offset)
 rows,err:=s.DB.QueryContext(ctx,"SELECT seq,point_id,station,name,value,raw,unit,quality,source_time,received_time,version FROM samples WHERE "+w+" ORDER BY seq ASC LIMIT ? OFFSET ?",args...)
 if err!=nil{return nil,err};defer rows.Close()
 out:=make([]Sample,0)
 for rows.Next(){
  var r Sample;var v,raw string;var src,recv int64
  if err:=rows.Scan(&r.Seq,&r.PointID,&r.Station,&r.Name,&v,&raw,&r.Unit,&r.Quality,&src,&recv,&r.Version);err!=nil{return nil,err}
  if err:=json.Unmarshal([]byte(v),&r.Value);err!=nil{return nil,err};if err:=json.Unmarshal([]byte(raw),&r.Raw);err!=nil{return nil,err}
  r.SourceTime=time.UnixMilli(src).UTC();r.ReceivedTime=time.UnixMilli(recv).UTC();out=append(out,r)
 }
 return out,rows.Err()
}
func(s *Store) Stats(ctx context.Context,f Filter)(Stats,error){
 w,args:=where(f);var out Stats;var min,max,mean sql.NullFloat64;var first,last sql.NullInt64
 err:=s.DB.QueryRowContext(ctx,"SELECT COUNT(*),MIN(numeric),MAX(numeric),AVG(numeric),MIN(source_time),MAX(source_time) FROM samples WHERE "+w,args...).Scan(&out.Count,&min,&max,&mean,&first,&last)
 if min.Valid{out.Min=&min.Float64};if max.Valid{out.Max=&max.Float64};if mean.Valid{out.Mean=&mean.Float64};if first.Valid{out.First=first.Int64};if last.Valid{out.Last=last.Int64};return out,err
}
func(s *Store) Boundary()(int64,error){var n int64;err:=s.DB.QueryRow("SELECT COALESCE(MAX(seq),0) FROM samples").Scan(&n);return n,err}
func(s *Store) Log(v any)error{
 b,err:=json.Marshal(v);if err!=nil{return err};_,err=s.DB.Exec("INSERT INTO executions(at,data) VALUES(?,?)",time.Now().UnixMilli(),string(b));return err
}
func(s *Store) Logs()(out []json.RawMessage,err error){
 out=make([]json.RawMessage,0);rows,err:=s.DB.Query("SELECT data FROM executions ORDER BY seq DESC LIMIT 200");if err!=nil{return nil,err};defer rows.Close()
 for rows.Next(){var data string;if err=rows.Scan(&data);err!=nil{return nil,err};out=append(out,json.RawMessage(data))};return out,rows.Err()
}
func(s *Store) Prune(ctx context.Context,days int)error{
 if days<1||days>3650{return fmt.Errorf("invalid retention")}
 _,err:=s.DB.ExecContext(ctx,"DELETE FROM samples WHERE seq IN (SELECT seq FROM samples WHERE source_time<? LIMIT 10000)",time.Now().AddDate(0,0,-days).UnixMilli());return err
}

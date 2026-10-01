package runtime
import(
 "context"
 "path/filepath"
 "testing"
 "time"
 "github.com/YufeiSun5/universal-hmi/backend/internal/points"
 "github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)
func setup(t *testing.T)(*Engine,*points.Service){
 t.Helper();dir:=t.TempDir();ps,err:=points.Open(filepath.Join(dir,"points.json"));if err!=nil{t.Fatal(err)}
 db,err:=storage.Open(dir);if err!=nil{t.Fatal(err)}
 e,err:=New(ps,db);if err!=nil{t.Fatal(err)}
 t.Cleanup(func(){e.Close();db.Close()});return e,ps
}
func point(t *testing.T,ps *points.Service,name string,writable bool)points.Definition{
 t.Helper();scale:=2.0;min,max:=0.0,100.0
 p,err:=ps.Create(points.CreateInput{Station:"IO-01",Name:name,DataType:"FLOAT",SourceType:"manual",ScaleFactor:&scale,Offset:10,Writable:writable,Min:&min,Max:&max,StaleMS:10000});if err!=nil{t.Fatal(err)};return p
}
func TestControlledWriteInverseRangeIdempotency(t *testing.T){
 e,ps:=setup(t);p:=point(t,ps,"setpoint",true);version,err:=e.Apply();if err!=nil{t.Fatal(err)}
 w:=Write{CommandID:"command-0001",PointID:p.ID,Value:50,Version:version}
 result,err:=e.Write(w);if err!=nil||result.State!="readback_confirmed"{t.Fatalf("%+v %v",result,err)}
 e.mu.Lock();sample:=e.live[p.ID];e.mu.Unlock()
 if sample.Raw!=20.0||sample.Value!=50.0{t.Fatalf("inverse conversion: %+v",sample)}
 w.Value=60;if _,err:=e.Write(w);err==nil{t.Fatal("command ID payload conflict accepted")}
 w.CommandID="command-0002";w.Value=101;if _,err:=e.Write(w);err==nil{t.Fatal("out of range accepted")}
 w.Value=30;w.Version="old";if _,err:=e.Write(w);err==nil{t.Fatal("stale config accepted")}
}
func TestRulesRequireGoodQualityAndHoldAndRecordEachAction(t *testing.T){
 e,ps:=setup(t);a:=point(t,ps,"input",false);b:=point(t,ps,"output",true);_,err:=e.Apply();if err!=nil{t.Fatal(err)}
 rule:=Rule{ID:"rule1",Name:"threshold",Enabled:true,Logic:"and",Conditions:[]Condition{{a.ID,">",30}},HoldMS:500,CooldownMS:1000,Trigger:"rising",Actions:[]Action{{"write",b.ID,50},{"snapshot","",0}}}
 if err:=e.SetRules([]Rule{rule});err!=nil{t.Fatal(err)}
 now:=time.Now()
 e.mu.Lock()
 e.ingest(a,20.0,"bad",now,now);e.evaluate(now)
 if e.live[b.ID].PointID!=""{t.Fatal("bad quality triggered")}
 e.ingest(a,20.0,"good",now,now);e.evaluate(now)
 if e.live[b.ID].PointID!=""{t.Fatal("hold ignored")}
 e.evaluate(now.Add(600*time.Millisecond))
 if e.live[b.ID].Value!=50.0{t.Fatal("rule not executed")}
 e.evaluate(now.Add(700*time.Millisecond));e.mu.Unlock()
 logs,err:=e.Store.Logs();if err!=nil{t.Fatal(err)}
 if len(logs)!=2{t.Fatalf("expected one command and one rule log, got %d",len(logs))}
 rows,err:=e.Store.Query(context.Background(),storage.Filter{PointID:b.ID});if err!=nil||len(rows)!=1{t.Fatalf("independent snapshot: %d %v",len(rows),err)}
}
func TestVirtualDependencyCycleRejectedWithoutChangingActiveVersion(t *testing.T){
 e,ps:=setup(t);a:=point(t,ps,"a",false);old,err:=e.Apply();if err!=nil{t.Fatal(err)}
 v,err:=ps.Create(points.CreateInput{Station:"IO-01",Name:"virtual",DataType:"FLOAT",SourceType:"virtual",Expression:"v[0]+1",Inputs:[]string{a.ID}});if err!=nil{t.Fatal(err)}
 if _,err=e.Apply();err!=nil{t.Fatal(err)}
 _,err=ps.Update(v.ID,points.CreateInput{Station:v.Station,Name:v.Name,DataType:"FLOAT",SourceType:"virtual",Expression:"v[0]+1",Inputs:[]string{v.ID}});if err!=nil{t.Fatal(err)}
 if _,err=e.Apply();err==nil{t.Fatal("cycle accepted")}
 if e.version==old{t.Fatal("valid activation did not advance version")}
}
func TestStaleInputAndOutOfOrderFrames(t *testing.T){
 e,ps:=setup(t);p:=point(t,ps,"input",false);e.Apply()
 now:=time.Now();e.mu.Lock();e.ingest(p,1.0,"good",now,now);e.ingest(p,9.0,"good",now.Add(-time.Second),now)
 if e.live[p.ID].Raw!=1.0{t.Fatal("old frame overwrote latest")}
 if e.good(p.ID,now.Add(11*time.Second)){t.Fatal("stale input remained good")};e.mu.Unlock()
}

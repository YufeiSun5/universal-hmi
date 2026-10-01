package acquisition

import (
 "encoding/json"
 "fmt"
 "strconv"
 "time"
 mqtt "github.com/eclipse/paho.mqtt.golang"
)

type Source struct{
 ID string `json:"id"`
 Name string `json:"name"`
 Broker string `json:"broker"`
 Topic string `json:"topic"`
 Protocol string `json:"protocol"`
}
type Raw struct { SourceID string; Topic string; Path string; Value any; Quality string; Time time.Time }
type Connection struct { Client mqtt.Client }
func Connect(s Source,submit func([]Raw),state func(string))(*Connection,error){
 opts:=mqtt.NewClientOptions().AddBroker(s.Broker).SetClientID("hmi-"+s.ID).
 SetConnectTimeout(5*time.Second).SetWriteTimeout(3*time.Second).
 SetAutoReconnect(false).SetConnectRetry(false).SetCleanSession(true).
 SetOrderMatters(false)
 opts.OnConnectionLost=func(_ mqtt.Client,err error){state("offline: "+err.Error())}
 opts.OnConnect=func(c mqtt.Client){
  token:=c.Subscribe(s.Topic,0,func(_ mqtt.Client,m mqtt.Message){
   if len(m.Payload())>1024*1024{state("payload too large");return}
   rows,err:=Decode(s.ID,m.Topic(),s.Protocol,m.Payload())
   if err!=nil{state("payload error: "+err.Error());return};submit(rows)
  })
  if !token.WaitTimeout(5*time.Second){state("subscribe timeout");return}
  if token.Error()!=nil{state("subscribe error: "+token.Error().Error());return};state("connected")
 }
 client:=mqtt.NewClient(opts);token:=client.Connect()
 if !token.WaitTimeout(6*time.Second){client.Disconnect(0);return nil,fmt.Errorf("connect timeout")}
 if token.Error()!=nil{return nil,token.Error()}
 return &Connection{client},nil
}
func(c *Connection) Close(){c.Client.Disconnect(100)}
func(c *Connection) Publish(topic string,value any)(string,error){
 b,err:=json.Marshal(value);if err!=nil{return "failed",err}
 if !c.Client.IsConnectionOpen(){return "failed",fmt.Errorf("source offline")}
 token:=c.Client.Publish(topic,1,false,b)
 if !token.WaitTimeout(3*time.Second){return "unknown",fmt.Errorf("publish confirmation timeout; do not retry automatically")}
 if err:=token.Error();err!=nil{return "failed",err}
 return "sent",nil // PUBACK confirms broker receipt only, never PLC execution.
}
func Decode(source,topic,protocol string,payload []byte)([]Raw,error){
 var doc map[string]json.RawMessage;if err:=json.Unmarshal(payload,&doc);err!=nil{return nil,err}
 out:=make([]Raw,0)
 appendRow:=func(path string,value any,quality string,at time.Time){out=append(out,Raw{source,topic,path,value,quality,at})}
 switch protocol{
 case "generic":
  var rows []struct{Path string `json:"path"`;Value any `json:"value"`;Quality string `json:"quality"`;Timestamp string `json:"timestamp"`}
  if err:=json.Unmarshal(doc["points"],&rows);err!=nil{return nil,err}
  if len(rows)>10000{return nil,fmt.Errorf("too many points")}
  for _,r:=range rows{at,err:=time.Parse(time.RFC3339Nano,r.Timestamp);if err!=nil{return nil,fmt.Errorf("source timestamp required")};q:="bad";if r.Quality=="good"{q="good"};appendRow(r.Path,r.Value,q,at)}
 case "kep":
  var rows []struct{ID string `json:"id"`;Value any `json:"v"`;Quality *bool `json:"q"`;Time int64 `json:"t"`}
  if err:=json.Unmarshal(doc["values"],&rows);err!=nil{return nil,err}
  if len(rows)>10000{return nil,fmt.Errorf("too many points")}
  for _,r:=range rows{q:="bad";if r.Quality!=nil&&*r.Quality{q="good"};if r.Time<=0{return nil,fmt.Errorf("source timestamp required")};appendRow(r.ID,r.Value,q,time.UnixMilli(r.Time))}
 case "kingio":
  var rows []map[string]any;if err:=json.Unmarshal(doc["Objs"],&rows);err!=nil{return nil,err}
  if len(rows)>10000{return nil,fmt.Errorf("too many points")}
  for _,r:=range rows{
   path,_:=r["N"].(string);q:="bad";quality,_:=number(r["3"]);if quality==192{q="good"}
   timestamp,ok:=number(r["2"]);if !ok||timestamp<=0{return nil,fmt.Errorf("source timestamp required")};if timestamp<1e12{timestamp*=1000}
   appendRow(path,r["1"],q,time.UnixMilli(int64(timestamp)))
  }
 default:return nil,fmt.Errorf("unsupported protocol")
 }
 return out,nil
}
func number(v any)(float64,bool){switch n:=v.(type){case float64:return n,true;case string:f,e:=strconv.ParseFloat(n,64);return f,e==nil};return 0,false}

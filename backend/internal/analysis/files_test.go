package analysis
import(
 "bytes"
 "context"
 "path/filepath"
 "testing"
 "time"
 "os"
 "github.com/xuri/excelize/v2"
 "github.com/YufeiSun5/universal-hmi/backend/internal/storage"
 "github.com/YufeiSun5/universal-hmi/backend/internal/points"
)
func TestExcelImportFilteredReportRoundtrip(t *testing.T){
 dir:=t.TempDir();db,err:=storage.Open(dir);if err!=nil{t.Fatal(err)};defer db.Close()
 ps,_:=points.Open(filepath.Join(dir,"points.json"));service,err:=New(db,ps,filepath.Join(dir,"exports"));if err!=nil{t.Fatal(err)};defer service.Close()
 book:=excelize.NewFile()
 for cell,value:=range map[string]any{"A1":"UTC time","B1":"value","A2":"2026-10-01T00:00:00Z","B2":12.5,"A3":"2026-10-01T00:01:00Z","B3":25.0}{if err:=book.SetCellValue("Sheet1",cell,value);err!=nil{t.Fatal(err)}}
 buffer,err:=book.WriteToBuffer();book.Close();if err!=nil{t.Fatal(err)}
 upload,err:=service.Upload(bytes.NewReader(buffer.Bytes()),"sample.xlsx");if err!=nil{t.Fatal(err)}
 mapping:=Mapping{SessionID:upload["session_id"].(string),Sheet:"Sheet1",TimeColumn:0,ValueColumn:1,Header:true,Station:"Imported",Name:"=unsafe()",Unit:"bar"}
 preview,err:=service.Preview(mapping,false);if err!=nil||preview.Count!=2||len(preview.Errors)!=0{t.Fatalf("%+v %v",preview,err)}
 result,err:=service.Import(context.Background(),mapping);if err!=nil{t.Fatal(err)}
 min:=20.0;filter:=storage.Filter{PointID:result["point_id"].(string),Min:&min}
 job,err:=service.Export(filter,"xlsx");if err!=nil{t.Fatal(err)}
 deadline:=time.Now().Add(5*time.Second)
 for time.Now().Before(deadline){
  jobs:=service.Jobs()
  for _,j:=range jobs{if j.ID==job.ID&&j.State=="failed"{t.Fatal(j.Message)};if j.ID==job.ID&&j.State=="completed"{
   path,_,err:=service.File(j.ID);if err!=nil{t.Fatal(err)}
   output,err:=excelize.OpenFile(path);if err!=nil{t.Fatal(err)};defer output.Close()
   rows,err:=output.GetRows("Sheet1");if err!=nil||len(rows)!=2||rows[1][4]!="25"{t.Fatalf("export filter mismatch: %+v %v",rows,err)}
   formula,_:=output.GetCellFormula("Sheet1","C2");if formula!=""{t.Fatal("external name became formula")}
   if _,err:=os.Stat(path);err!=nil{t.Fatal(err)};return
  }}
  time.Sleep(10*time.Millisecond)
 };t.Fatal("export did not finish")
}
func TestInvalidRowsBlockImport(t *testing.T){
 dir:=t.TempDir();db,_:=storage.Open(dir);defer db.Close();ps,_:=points.Open(filepath.Join(dir,"points.json"));s,_:=New(db,ps,filepath.Join(dir,"exports"));defer s.Close()
 upload,err:=s.Upload(bytes.NewBufferString("time,value\nwrong,12\n2026-10-01T00:00:00Z,nan\n"),"sample.csv");if err!=nil{t.Fatal(err)}
 m:=Mapping{SessionID:upload["session_id"].(string),Sheet:"CSV",TimeColumn:0,ValueColumn:1,Header:true,Station:"s",Name:"p"}
 preview,err:=s.Preview(m,false);if err!=nil||len(preview.Errors)!=2{t.Fatalf("%+v %v",preview,err)}
 if _,err:=s.Import(context.Background(),m);err==nil{t.Fatal("invalid rows imported")}
}

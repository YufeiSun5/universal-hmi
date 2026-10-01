"""Real HTTP/MQTT/file flow; localhost fixtures only."""
import datetime
import json
import pathlib
import subprocess
import time
import urllib.request
import zipfile
import io

BASE = "http://127.0.0.1:18080"
def request(method, path, data=None):
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(BASE + path, payload, {"Content-Type":"application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)
def wait(predicate, timeout=10):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError("condition timed out")
source = {"id":"fixture-source","name":"Packed 10 stations","broker":"tcp://127.0.0.1:18884","topic":"fixture/packed","protocol":"generic"}
request("PUT","/api/v1/sources",{"items":[source]})
points=[]
for i in range(1,11):
    p=request("POST","/api/v1/points",{"station":f"MQTT-{i:02d}","name":"Temperature","source_type":"mqtt","data_type":"FLOAT","unit":"C","source_id":source["id"],"topic":source["topic"],"source_path":f"IO{i}.temperature","scale_factor":2,"offset":10,"stale_ms":5000})
    points.append(p)
output=request("POST","/api/v1/points",{"station":"MQTT-01","name":"Output","source_type":"manual","data_type":"FLOAT","writable":True,"min":0,"max":100})
virtual=request("POST","/api/v1/points",{"station":"MQTT-01","name":"Average","source_type":"virtual","data_type":"FLOAT","expression":"(v[0]+v[1])/2","inputs":[p["id"] for p in points[:2]]})
version=request("POST","/api/v1/apply")["version"]
request("POST","/api/v1/sources/fixture-source/connect")
policy={"enabled":True,"interval_ms":200,"retention_days":30,"changed_only":False,"point_ids":[]}
request("PUT","/api/v1/storage",policy)
rule={"id":"fixture-rule","name":"Two-condition storage/write","enabled":True,"logic":"and","trigger":"rising","hold_ms":200,"cooldown_ms":1000,
      "conditions":[{"point_id":points[0]["id"],"op":">","value":40},{"point_id":points[1]["id"],"op":">=","value":50}],
      "actions":[{"type":"write","point_id":output["id"],"value":66},{"type":"snapshot","point_id":"","value":0}]}
request("PUT","/api/v1/rules",{"items":[rule]})
def publish(quality):
    now=datetime.datetime.now(datetime.timezone.utc).isoformat()
    doc={"points":[{"path":f"IO{i}.temperature","value":20+i,"quality":quality,"timestamp":now} for i in range(1,11)]}
    subprocess.run(["mosquitto_pub","-h","127.0.0.1","-p","18884","-t",source["topic"],"-m",json.dumps(doc)],check=True)
publish("bad")
time.sleep(.5)
assert not request("GET","/api/v1/executions")["items"],"Bad quality triggered a physical action"
publish("good")
def check():
    values={v["point_id"]:v for v in request("GET","/api/v1/runtime")["values"]}
    return values.get(output["id"],{}).get("value")==66
wait(check)
runtime=request("GET","/api/v1/runtime")
values={v["point_id"]:v for v in runtime["values"]}
assert len({p["station"] for p in points})==10
assert values[points[0]["id"]]["value"]==52
assert values[virtual["id"]]["value"]==53
executions=request("GET","/api/v1/executions")["items"]
assert len([v for v in executions if v["type"]=="rule"])==1
history=request("GET","/api/v1/history?point_id="+points[0]["id"]+"&quality=good")
assert history["stats"]["count"]>=1
assert all(r["value"]==52 for r in history["items"])
job=request("POST","/api/v1/export?format=xlsx&point_id="+points[0]["id"]+"&quality=good")
complete=wait(lambda:next((j for j in request("GET","/api/v1/jobs")["items"] if j["id"]==job["id"] and j["state"]=="completed"),None))
with urllib.request.urlopen(BASE+"/api/v1/jobs/"+job["id"]+"/file") as response:
    workbook=response.read()
with zipfile.ZipFile(io.BytesIO(workbook)) as archive:
    assert "xl/worksheets/sheet1.xml" in archive.namelist()
    assert b"<v>52</v>" in archive.read("xl/worksheets/sheet1.xml")
request("POST","/api/v1/sources/fixture-source/disconnect")
request("PUT","/api/v1/rules",{"items":[]})
request("PUT","/api/v1/storage",{**policy,"enabled":False})
print("PASS: one packed MQTT source -> 10 station mappings -> scaled/virtual values -> quality-gated AND event -> inverse local write and snapshot -> independent history -> filtered XLSX")

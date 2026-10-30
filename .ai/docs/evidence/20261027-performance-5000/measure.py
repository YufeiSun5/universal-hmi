from pathlib import Path
import ctypes as C,ctypes.wintypes as W,datetime,json,math,os,secrets,socket,struct,subprocess,threading,time,urllib.request,urllib.error
ROOT=Path('D:/DEV_D/KPimport'); OUT=ROOT/'.local/perf-5000'; BASE='http://127.0.0.1:18157'; PID=71612
DOCKER='C:/Program Files/Docker/Docker/resources/bin/docker.exe'
admin=''; viewer=''; stop_publish=threading.Event(); publish_stats={'cycles':0,'samples':0,'errors':[],'payload_bytes':0}
def api(method,path,body=None,token=None,raw=False):
    headers={'Content-Type':'application/json','Origin':BASE}
    if token is None: token=admin
    if token: headers['Authorization']='Bearer '+token
    data=None if body is None else json.dumps(body,separators=(',',':')).encode()
    r=urllib.request.urlopen(urllib.request.Request(BASE+path,data=data,headers=headers,method=method),timeout=30)
    payload=r.read()
    return payload if raw else json.loads(payload)
def pg(sql):
    return subprocess.check_output([DOCKER,'exec','postgres','psql','-U','postgres','-d','hmi_perf_5000_20261027','-Atc',sql],encoding='utf-8').strip()
def pct(values,p):
    if not values:return None
    return sorted(values)[min(len(values)-1,math.ceil(len(values)*p)-1)]
def summary(values):
    return {'n':len(values),'p50':pct(values,.5),'p95':pct(values,.95),'max':max(values) if values else None}
class PMC(C.Structure):
    _fields_=[('cb',W.DWORD),('PageFaultCount',W.DWORD)]+[(n,C.c_size_t) for n in ['PeakWorkingSetSize','WorkingSetSize','QuotaPeakPagedPoolUsage','QuotaPagedPoolUsage','QuotaPeakNonPagedPoolUsage','QuotaNonPagedPoolUsage','PagefileUsage','PeakPagefileUsage']]
k=C.WinDLL('kernel32',use_last_error=True); ps=C.WinDLL('psapi',use_last_error=True)
k.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD]; k.OpenProcess.restype=W.HANDLE
k.GetProcessTimes.argtypes=[W.HANDLE]+[C.POINTER(W.FILETIME)]*4
ps.GetProcessMemoryInfo.argtypes=[W.HANDLE,C.POINTER(PMC),W.DWORD]
handle=k.OpenProcess(0x0410,False,PID)
assert handle
def process():
    times=[W.FILETIME() for _ in range(4)]
    assert k.GetProcessTimes(handle,*[C.byref(t) for t in times])
    cpu=sum((t.dwHighDateTime<<32)+t.dwLowDateTime for t in times[2:])/1e7
    mem=PMC();mem.cb=C.sizeof(mem);assert ps.GetProcessMemoryInfo(handle,C.byref(mem),mem.cb)
    return cpu,mem.WorkingSetSize/1048576
def encstr(s):
    b=s.encode();return struct.pack('!H',len(b))+b
def packet(sock,kind,data):
    n=len(data);length=b''
    while True:
        digit=n%128;n//=128;length+=bytes([digit|(128 if n else 0)])
        if not n:break
    sock.sendall(bytes([kind])+length+data)
def exact(sock,n):
    parts=[]
    while n:
        b=sock.recv(n)
        if not b:raise RuntimeError('MQTT closed')
        parts.append(b);n-=len(b)
    return b''.join(parts)
def recv(sock):
    kind=exact(sock,1)[0];n=0;m=1
    while True:
        b=exact(sock,1)[0];n+=(b&127)*m
        if b<128:break
        m*=128
    return kind,exact(sock,n)
def publisher():
    try:
        with socket.create_connection(('127.0.0.1',18897),timeout=10) as sock:
            packet(sock,0x10,encstr('MQTT')+bytes([4,2,0,60])+encstr('hmi-perf-publisher'))
            kind,data=recv(sock);assert kind==0x20 and data==b'\x00\x00',(kind,data)
            seq=0
            while not stop_publish.is_set():
                started=time.monotonic();seq+=1
                timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')
                payload=json.dumps({'PVs':{'2':timestamp,'3':192},'Objs':[{'N':f'P{i:05d}','1':i+seq/1000,'2':0} for i in range(5000)]},separators=(',',':')).encode()
                packet(sock,0x32,encstr('perf/values')+struct.pack('!H',(seq%65534)+1)+payload)
                kind,data=recv(sock);assert kind==0x40,(kind,data)
                publish_stats.update(cycles=seq,samples=seq*5000,payload_bytes=len(payload))
                stop_publish.wait(max(0,1-(time.monotonic()-started)))
    except Exception as e:
        publish_stats['errors'].append(repr(e))
class Reader:
    def __init__(self):
        self.frames=0;self.bytes=0;self.times=[];self.sizes=[];self.status=None;self.error=None;self.stop=threading.Event();self.thread=threading.Thread(target=self.run,daemon=True);self.response=None
    def run(self):
        try:
            self.response=urllib.request.urlopen(urllib.request.Request(BASE+'/api/v1/runtime/events',headers={'Authorization':'Bearer '+viewer}),timeout=12)
            self.status=self.response.status
            while not self.stop.is_set():
                line=self.response.readline()
                if not line:break
                if line.startswith(b'data: '):
                    self.frames+=1;self.bytes+=len(line);self.times.append(time.monotonic());self.sizes.append(len(line))
        except urllib.error.HTTPError as e:self.status=e.code
        except Exception as e:
            if not self.stop.is_set():self.error=type(e).__name__+':'+str(e)
        finally:
            if self.response:self.response.close()
    def close(self):self.stop.set()
def phase(count,history,seconds=25):
    api('PUT','/api/v1/storage',{'enabled':history,'interval_ms':1000,'changed_only':False,'retention_days':1})
    rows_before=int(pg('SELECT count(*) FROM samples'))
    readers=[Reader() for _ in range(count)]
    for reader in readers:reader.thread.start()
    time.sleep(2)
    begin=time.monotonic();cpu0,mem=process();hcpu=time.process_time();samples=[];http=[];ages=[];queues=[];storage_errors=set();errors=[]
    initial=[(r.frames,r.bytes) for r in readers]
    while time.monotonic()-begin<seconds:
        cpu,rss=process();samples.append((time.monotonic()-begin,cpu-cpu0,rss))
        t=time.monotonic()
        try:
            runtime=api('GET','/api/v1/runtime');http.append((time.monotonic()-t)*1000)
            queues.append(runtime['queue']['depth'])
            if runtime.get('storage_error'):storage_errors.add(runtime['storage_error'])
            values=runtime['values'];st=datetime.datetime.fromisoformat(values[0]['source_time'].replace('Z','+00:00'))
            ages.append((datetime.datetime.now(datetime.timezone.utc)-st).total_seconds()*1000)
        except Exception as e:errors.append(str(e))
        time.sleep(max(0,1-(time.monotonic()-t)))
    elapsed=time.monotonic()-begin;cpu1,rss=process()
    frames=sum(r.frames-a for r,(a,b) in zip(readers,initial));byte_count=sum(r.bytes-b for r,(a,b) in zip(readers,initial))
    statuses={str(status):sum(r.status==status for r in readers) for status in set(r.status for r in readers)}
    gaps=[(b-a)*1000 for r in readers for a,b in zip(r.times,r.times[1:]) if a>=begin]
    frame_sizes=[size for r in readers for t,size in zip(r.times,r.sizes) if t>=begin]
    for reader in readers:reader.close()
    for reader in readers:reader.thread.join(timeout=15)
    runtime=api('GET','/api/v1/runtime')
    rows_after=int(pg('SELECT count(*) FROM samples'))
    result={'requested_streams':count,'history_1hz_all_points':history,'measured_seconds':elapsed,'statuses':statuses,'active_reader_threads_after_close':sum(r.thread.is_alive() for r in readers),'backend_cpu_percent_one_core':(cpu1-cpu0)/elapsed*100,'backend_cpu_percent_machine':(cpu1-cpu0)/elapsed*100/os.cpu_count(),'backend_rss_mib_peak':max([rss]+[x[2] for x in samples]),'harness_cpu_percent_one_core':(time.process_time()-hcpu)/elapsed*100,'runtime_http_ms':summary(http),'latest_value_age_ms':summary(ages),'sse_frame_gap_ms':summary(gaps),'sse_frame_bytes':summary(frame_sizes),'sse_frames':frames,'sse_total_mbit_s':byte_count*8/elapsed/1e6,'history_rows_before':rows_before,'history_rows_after':rows_after,'history_rows_per_second_approx':(rows_after-rows_before)/(elapsed+2),'queue_depth_max':max(queues) if queues else None,'queue_final':runtime['queue'],'source_metrics_final':runtime['source_metrics'],'storage_errors':list(storage_errors),'request_errors':errors,'stream_errors':[r.error for r in readers if r.error]}
    print(json.dumps({'phase':count,'history':history,'statuses':statuses,'cpu_one_core':round(result['backend_cpu_percent_one_core'],1),'rss_mib':round(result['backend_rss_mib_peak'],1),'http_p95_ms':round(result['runtime_http_ms']['p95'] or 0,1),'sse_mbit_s':round(result['sse_total_mbit_s'],1),'history_rows':rows_after-rows_before,'storage_errors':list(storage_errors)},ensure_ascii=False),flush=True)
    return result
def setup():
    global admin,viewer
    credentials={'username':'perf-engineer','password':secrets.token_urlsafe(24)}
    api('POST','/api/v1/auth/setup',credentials,token='')
    admin=api('POST','/api/v1/auth/login',{**credentials,'issue_token':True},token='')['bearer_token']
    reader={'username':'perf-viewer','password':secrets.token_urlsafe(24)}
    api('POST','/api/v1/security/users',{**reader,'grants':{'roles':['viewer'],'all_stations':True}})
    viewer=api('POST','/api/v1/auth/login',{**reader,'issue_token':True},token='')['bearer_token']
    (OUT/'credentials.json').write_text(json.dumps({'admin':credentials,'reader':reader,'admin_token':admin,'reader_token':viewer}),encoding='utf-8')
    (OUT/'login.js').write_text('async()=>{const r=await fetch("/api/v1/auth/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify('+json.dumps(credentials)+')});if(!r.ok)throw Error("fixture login failed");location.reload();return {ok:true};}',encoding='utf-8')
    sources=[{'id':'perf','name':'Isolated performance MQTT','broker':'tcp://127.0.0.1:18897','topic':'perf/values','protocol':'kingio','client_id':'perf','writer':'perf-fixture','ack_timeout_ms':2000}]
    api('PUT','/api/v1/sources',{'items':sources})
    definitions=[{'station':f'PERF-{i//500+1:02d}','name':f'Variable {i:05d}','source_type':'mqtt','data_type':'FLOAT','unit':'kPa','source_id':'perf','source_path':f'P{i:05d}','topic':'perf/values','stale_ms':5000} for i in range(5000)]
    start=time.monotonic();items=api('POST','/api/v1/points/batch',{'items':definitions})['items'];assert len(items)==5000
    created=time.monotonic()-start
    api('POST','/api/v1/apply');api('POST','/api/v1/sources/perf/connect')
    return created
def main():
    created=setup();pub=threading.Thread(target=publisher,daemon=True);pub.start()
    try:
        for _ in range(20):
            runtime=api('GET','/api/v1/runtime')
            if len(runtime['values'])==5000 and all(v['quality']=='good' for v in runtime['values']):break
            time.sleep(1)
        else:raise RuntimeError('MQTT did not populate all 5000 points')
        result={'source_sha256':'54e7b9a7c8d6760386c3158bfa008999555c7f23a6ffbc2d751a2c66974248a2','backend_pid':PID,'point_count':5000,'stations':10,'points_per_station':500,'mqtt_hz':1,'broker':'isolated EMQX 4.3.11 Docker; loopback; QoS1','database':'isolated PostgreSQL database hmi_perf_5000_20261027','client_model':'concurrent authenticated all-station viewer SSE connections, one shared test account; not 50 rendered browser tabs','machine_logical_cpus':os.cpu_count(),'create_5000_seconds':created,'phases':[]}
        for count,history in [(1,False),(10,False),(32,False),(50,False),(1,True),(32,True)]:
            result['phases'].append(phase(count,history))
            result['publisher']=publish_stats.copy()
            (OUT/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        api('PUT','/api/v1/storage',{'enabled':False,'interval_ms':1000,'changed_only':False,'retention_days':1})
        stop_publish.set();pub.join(timeout=12)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            runtime=api('GET','/api/v1/runtime')
            if runtime['queue']['processed_samples']==publish_stats['samples']:break
            time.sleep(.2)
        result['publisher']=publish_stats.copy();result['settled_queue']=runtime['queue'];result['settled_source_metrics']=runtime['source_metrics'];result['history_total_rows']=int(pg('SELECT count(*) FROM samples'));result['history_total_bytes']=int(pg("SELECT pg_total_relation_size('samples')"));result['completed_at']=datetime.datetime.now().isoformat()
        (OUT/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print('MEASUREMENT_COMPLETE',flush=True)
    finally:stop_publish.set();pub.join(timeout=12)
if __name__=='__main__':main()

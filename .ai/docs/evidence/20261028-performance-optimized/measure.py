from pathlib import Path
import ctypes as C,ctypes.wintypes as W,datetime,json,math,os,secrets,socket,struct,subprocess,threading,time,urllib.request,urllib.error,http.client,functools
ROOT=Path('D:/DEV_D/KPimport');OUT=ROOT/'.local/perf-optimized';BASE='http://127.0.0.1:18158'
DOCKER='C:/Program Files/Docker/Docker/resources/bin/docker.exe'
ADMIN='';DATA={};STOP=threading.Event()
def api(method,path,body=None,token=None,source=None):
    headers={'Content-Type':'application/json','Origin':BASE}
    if token is None:token=ADMIN
    if token:headers['Authorization']='Bearer '+token
    request=urllib.request.Request(BASE+path,data=None if body is None else json.dumps(body,separators=(',',':')).encode(),headers=headers,method=method)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    if source:
        class SourceHTTP(urllib.request.HTTPHandler):
            def http_open(self,req):return self.do_open(functools.partial(http.client.HTTPConnection,source_address=(source,0)),req)
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),SourceHTTP())
    with opener.open(request,timeout=30) as response:return json.load(response)
def pg(sql):return subprocess.check_output([DOCKER,'exec','postgres','psql','-U','postgres','-d','hmi_perf_optimized_20261028','-Atc',sql],encoding='utf-8').strip()
def save(): (OUT/'fixture.json').write_text(json.dumps(DATA),encoding='utf-8')
def summary(values):
    values=sorted(values)
    return {'n':len(values),'p50':values[len(values)//2] if values else None,'p95':values[min(len(values)-1,math.ceil(len(values)*.95)-1)] if values else None,'max':max(values) if values else None}
class PMC(C.Structure):
    _fields_=[('cb',W.DWORD),('PageFaultCount',W.DWORD)]+[(n,C.c_size_t) for n in ['PeakWorkingSetSize','WorkingSetSize','QuotaPeakPagedPoolUsage','QuotaPagedPoolUsage','QuotaPeakNonPagedPoolUsage','QuotaNonPagedPoolUsage','PagefileUsage','PeakPagefileUsage']]
k=C.WinDLL('kernel32',use_last_error=True);ps=C.WinDLL('psapi',use_last_error=True)
k.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];k.OpenProcess.restype=W.HANDLE
k.GetProcessTimes.argtypes=[W.HANDLE]+[C.POINTER(W.FILETIME)]*4
ps.GetProcessMemoryInfo.argtypes=[W.HANDLE,C.POINTER(PMC),W.DWORD]
PID=int((OUT/'server.pid').read_text().strip());handle=k.OpenProcess(0x0410,False,PID);assert handle
def process():
    times=[W.FILETIME() for _ in range(4)];assert k.GetProcessTimes(handle,*[C.byref(t) for t in times])
    cpu=sum((t.dwHighDateTime<<32)+t.dwLowDateTime for t in times[2:])/1e7
    mem=PMC();mem.cb=C.sizeof(mem);assert ps.GetProcessMemoryInfo(handle,C.byref(mem),mem.cb)
    return cpu,mem.WorkingSetSize/1048576
def enc(s):
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
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')
class Gateway:
    def __init__(self):
        at=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=157)).isoformat(timespec='milliseconds')
        self.rows=[{'N':f'P{i:05d}','1':float(i),'2':at,'3':192} for i in range(5000)]
        self.change_count=0;self.silent=False;self.omit=None;self.bad=None;self.seq=0;self.messages=0;self.samples=0;self.queries=0;self.acks=0;self.errors=[];self.ready=threading.Event();self.thread=threading.Thread(target=self.run,daemon=True)
    def send(self,sock,indices):
        rows=[]
        for i in indices:
            if i!=self.omit:rows.append({**self.rows[i],'3':0 if i==self.bad else 192})
        payload=json.dumps({'Objs':rows},separators=(',',':')).encode()
        assert len(payload)<1048576
        self.messages+=1;packet(sock,0x32,enc('perf/values')+struct.pack('!H',self.messages%65534+1)+payload);self.samples+=len(rows)
    def run(self):
        try:
            with socket.create_connection(('127.0.0.1',18898),timeout=5) as sock:
                packet(sock,0x10,enc('MQTT')+bytes([4,2,0,60])+enc('hmi-optimized-fixture'))
                assert recv(sock)==(0x20,b'\x00\x00')
                packet(sock,0x82,b'\x00\x01'+enc('Query_AllKIOTags_perf')+b'\x00')
                assert recv(sock)[0]==0x90
                sock.settimeout(.1);self.ready.set();next_change=time.monotonic()+1
                while not STOP.is_set():
                    if time.monotonic()>=next_change:
                        next_change=time.monotonic()+1;self.seq+=1
                        if self.change_count and not self.silent:
                            indices=[(self.seq*self.change_count+i)%5000 for i in range(self.change_count)]
                            at=utc()
                            for i in indices:self.rows[i]['1']=i+self.seq/1000;self.rows[i]['2']=at
                            self.send(sock,indices)
                    try:kind,data=recv(sock)
                    except socket.timeout:continue
                    if kind==0x40:self.acks+=1
                    elif kind>>4==3:
                        n=struct.unpack('!H',data[:2])[0];topic=data[2:2+n].decode();payload=data[2+n:]
                        assert topic=='Query_AllKIOTags_perf' and payload==b''
                        self.queries+=1
                        if not self.silent:self.send(sock,range(5000))
        except Exception as err:self.errors.append(repr(err));self.ready.set()
class Reader:
    def __init__(self,token,ids):
        self.token=token;self.ids=ids;self.frames=0;self.bytes=0;self.times=[];self.sizes=[];self.values=0;self.status=None;self.errors=[];self.epoch=None;self.sequence=0;self.state={};self.stopping=threading.Event();self.expired=threading.Event();self.thread=threading.Thread(target=self.run,daemon=True)
    def run(self):
        try:
            request=urllib.request.Request(BASE+'/api/v1/runtime/events?protocol=delta&ids='+','.join(self.ids),headers={'Authorization':'Bearer '+self.token})
            with urllib.request.urlopen(request,timeout=10) as response:
                self.status=response.status;event=''
                while not self.stopping.is_set():
                    line=response.readline()
                    if not line:break
                    if line.startswith(b'event: '):event=line[7:].strip().decode()
                    if line.startswith(b'data: '):
                        if event=='session-expired':self.expired.set();break
                        frame=json.loads(line[6:]);assert event=='runtime-delta'
                        assert frame['sequence']==self.sequence+1
                        if frame['kind']=='reset':self.state={}
                        else:assert self.epoch==frame['epoch']
                        self.epoch=frame['epoch'];self.sequence=frame['sequence']
                        for row in frame['values']:
                            pid=row['point_id'];assert pid in self.ids
                            self.state[pid]={**self.state.get(pid,{}),**row}
                        for pid in frame['removed']:self.state.pop(pid,None)
                        self.frames+=1;self.bytes+=len(line);self.values+=len(frame['values']);self.times.append(time.monotonic());self.sizes.append(len(line))
        except urllib.error.HTTPError as err:self.status=err.code
        except Exception as err:
            if not self.stopping.is_set():self.errors.append(repr(err))
    def close(self):self.stopping.set();self.thread.join(timeout=12)
def setup():
    global ADMIN,DATA
    file=OUT/'fixture.json'
    if file.exists():DATA=json.loads(file.read_text(encoding='utf-8'));ADMIN=DATA['admin_token'];return
    owner={'username':'perf-engineer','password':secrets.token_urlsafe(24)}
    api('POST','/api/v1/auth/setup',owner,token='')
    ADMIN=api('POST','/api/v1/auth/login',{**owner,'issue_token':True},token='')['bearer_token']
    DATA={'admin':owner,'admin_token':ADMIN,'users':[]};save()
    definitions=[{'station':f'PERF-{i//500+1:02d}','name':f'Variable {i:05d}','source_type':'mqtt','data_type':'FLOAT','unit':'kPa','source_id':'perf','source_path':f'P{i:05d}','topic':'perf/values','stale_ms':5000} for i in range(5000)]
    DATA['points']=api('POST','/api/v1/points/batch',{'items':definitions})['items'];save()
    api('POST','/api/v1/apply')
    api('PUT','/api/v1/sources',{'items':[{'id':'perf','name':'Isolated KIO fixture','broker':'tcp://127.0.0.1:18898','topic':'perf/values','protocol':'kingio','client_id':'perf','refresh_ms':2000}]})
    for i in range(50):
        credential={'username':f'perf-viewer-{i:02d}','password':secrets.token_urlsafe(24)}
        user=api('POST','/api/v1/security/users',{**credential,'grants':{'roles':['viewer'],'all_stations':True}})
        # Actual loopback source addresses avoid the per-IP login throttle,
        # without trusting spoofed proxy headers or weakening authentication.
        token=api('POST','/api/v1/auth/login',{**credential,'issue_token':True},token='',source=f'127.0.0.{i+2}')['bearer_token']
        DATA['users'].append({'id':user['id'],**credential,'token':token});save()
    print('50 independent authenticated users ready',flush=True)
def wait_for(predicate,timeout=12):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        state=api('GET','/api/v1/runtime')
        if predicate(state):return state
        time.sleep(.2)
    raise AssertionError('runtime condition timed out')
def phase(gateway,changes,history,seconds=15):
    gateway.change_count=changes
    api('PUT','/api/v1/storage',{'enabled':history,'interval_ms':1000,'changed_only':False,'retention_days':1})
    readers=[Reader(user['token'],[p['id'] for p in DATA['points'][i*100:(i+1)*100]]) for i,user in enumerate(DATA['users'])]
    for reader in readers:reader.thread.start()
    time.sleep(2)
    assert all(r.status==200 and len(r.state)==100 for r in readers),[(r.status,len(r.state),r.errors) for r in readers]
    begin=time.monotonic();cpu0,_=process();before=api('GET','/api/v1/runtime')['storage_queue']['committed_samples'];initial=[(r.bytes,r.values) for r in readers]
    http=[];rss=[];errors=set()
    while time.monotonic()-begin<seconds:
        start=time.monotonic();runtime=api('GET','/api/v1/runtime');http.append((time.monotonic()-start)*1000);rss.append(process()[1])
        if runtime['storage_error']:errors.add(runtime['storage_error'])
        time.sleep(max(0,1-(time.monotonic()-start)))
    elapsed=time.monotonic()-begin;cpu1,_=process()
    result={'changed_points_per_second':changes,'requested_sessions':50,'connected':sum(r.status==200 for r in readers),'history_all_5000_each_second':history,'measured_seconds':elapsed,'sse_mbit_s':sum(r.bytes-a for r,(a,b) in zip(readers,initial))*8/elapsed/1e6,'changed_entries_per_second':sum(r.values-b for r,(a,b) in zip(readers,initial))/elapsed,'runtime_http_ms':summary(http),'backend_cpu_machine_percent':(cpu1-cpu0)/elapsed*100/os.cpu_count(),'rss_mib_peak':max(rss),'frame_gap_ms':summary([(b-a)*1000 for r in readers for a,b in zip(r.times,r.times[1:]) if a>=begin]),'storage_committed_samples':runtime['storage_queue']['committed_samples']-before,'storage_errors':list(errors),'stream_errors':[x for r in readers for x in r.errors]}
    for reader in readers:reader.stopping.set()
    for reader in readers:reader.thread.join(timeout=12)
    assert all(not r.thread.is_alive() for r in readers)
    assert not result['stream_errors'] and not errors
    if history:assert result['storage_committed_samples']>=5000*(seconds-2)
    print(json.dumps(result),flush=True);return result
def main():
    setup();assert len(DATA['users'])==50
    gateway=Gateway();gateway.thread.start();assert gateway.ready.wait(10) and not gateway.errors
    result={'backend_pid':PID,'point_count':5000,'independent_accounts':50,'subscription_points_per_session':100,'database':'hmi_perf_optimized_20261028','mqtt_broker':'EMQX 4.3.11 isolated loopback 18898','client_model':'50 real authenticated SSE sessions; not 50 rendered browsers','source_pattern':'first/requested full set; partial changes every second; explicit full refresh every 2s','phases':[]}
    def report(): (OUT/'results.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    try:
        api('POST','/api/v1/sources/perf/disconnect')
        api('POST','/api/v1/sources/perf/connect')
        runtime=wait_for(lambda r:len(r['values'])==5000 and all(v['quality']=='good' for v in r['values']))
        assert gateway.queries>=1
        assert datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(runtime['values'][0]['source_time'].replace('Z','+00:00'))>datetime.timedelta(seconds=150)
        result['old_constant_source_time_confirmed']=True;report()
        if os.environ.get('PERF_RESUME'):
            result=json.loads((OUT/'results.json').read_text(encoding='utf-8'))
        for changes,history in ([] if os.environ.get('PERF_RESUME') else [(50,False),(100,False),(500,False),(5000,False),(5000,True)]):
            result['phases'].append(phase(gateway,changes,history));report()
        api('PUT','/api/v1/storage',{'enabled':False,'interval_ms':1000,'changed_only':False,'retention_days':1});gateway.change_count=0
        # A full query reply missing one tag cannot refresh that missing tag.
        missing=DATA['points'][4999]['id'];gateway.omit=4999
        wait_for(lambda r:next(v for v in r['values'] if v['point_id']==missing)['quality']=='stale')
        result['incomplete_reply_expires_missing_tag']=True;gateway.omit=None
        wait_for(lambda r:all(v['quality']=='good' for v in r['values']))
        gateway.bad=4999
        wait_for(lambda r:next(v for v in r['values'] if v['point_id']==missing)['quality']=='bad')
        result['bad_quality_propagates']=True;gateway.bad=None
        wait_for(lambda r:all(v['quality']=='good' for v in r['values']))
        gateway.silent=True
        wait_for(lambda r:all(v['quality']=='stale' for v in r['values']))
        result['broker_connected_silence_expires']=True;gateway.silent=False
        wait_for(lambda r:all(v['quality']=='good' for v in r['values']))
        before_queries=gateway.queries
        api('POST','/api/v1/sources/perf/disconnect');api('POST','/api/v1/sources/perf/connect')
        wait_for(lambda r:all(v['quality']=='good' for v in r['values']))
        assert gateway.queries>before_queries;result['reconnect_requests_full']=True
        user=DATA['users'][-1];reader=Reader(user['token'],[missing]);reader.thread.start()
        deadline=time.monotonic()+5
        while reader.frames<1 and time.monotonic()<deadline:time.sleep(.05)
        assert reader.status==200 and reader.frames>=1
        current=next(u for u in api('GET','/api/v1/security/users')['items'] if u['id']==user['id'])
        api('PUT','/api/v1/security/users/'+user['id'],{'username':user['username'],'version':current['version'],'disabled':True,'grants':{'roles':['viewer'],'all_stations':True}})
        assert reader.expired.wait(3);reader.close();result['live_session_revocation']=True
        gateway.silent=True;STOP.set();gateway.thread.join(timeout=6)
        runtime=wait_for(lambda r:r['queue']['depth']==0 and r['queue']['processed_samples']==r['queue']['accepted_samples'])
        result['settled_queue']=runtime['queue'];result['settled_source_metrics']=runtime['source_metrics'];result['storage_queue']=runtime['storage_queue'];result['history_rows']=int(pg('SELECT count(*) FROM samples'));result['gateway']={k:getattr(gateway,k) for k in ['messages','samples','queries','acks','errors']}
        assert not gateway.errors and runtime['queue']['dropped_samples']==0
        assert runtime['storage_queue']['failed_samples']==0
        result['completed_at']=utc();report();print('PERFORMANCE_VERIFIED',flush=True)
    finally:STOP.set();gateway.thread.join(timeout=6)
if __name__=='__main__':main()

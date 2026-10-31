import http.server,json,os,re,socket,subprocess,sys,threading,time,urllib.request
from pathlib import Path
work=Path(__file__).resolve().parent; root=work.parents[1]
bundle=Path(json.loads((work/'install-result.json').read_text())['payload'])
mode=sys.argv[1]; assert mode in ('conflict','free')
view='gis' if mode=='conflict' else 'process'
fixture=None
class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data=b'{"service":"unrelated-port-fixture","status":"ok"}'
        self.send_response(200);self.end_headers();self.wfile.write(data)
    def log_message(self,*args):pass
with socket.socket() as probe:
    assert probe.connect_ex(('127.0.0.1',18080))!=0,'Existing port owner: refuse fixture/reuse'
if mode=='conflict':
    fixture=http.server.ThreadingHTTPServer(('127.0.0.1',18080),Fixture)
    threading.Thread(target=fixture.serve_forever,daemon=True).start()
appdata=work/'isolated-appdata'; env=dict(os.environ,LOCALAPPDATA=str(appdata),HMI_LIFECYCLE_TRACE='1')
shortcut=json.loads((work/'shortcuts.json').read_text(encoding='utf-8-sig'))[view]
assert str(bundle/'Start-Trial.ps1').lower() in shortcut['Arguments'].lower()
def get(port,path):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}'+path,timeout=4) as r:return r.read()
try:
    with (work/f'{mode}-desktop.log').open('w') as log:
        proc=subprocess.Popen('"'+shortcut['TargetPath']+'" '+shortcut['Arguments'],cwd=shortcut['WorkingDirectory'],env=env,stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW)
        deadline=time.monotonic()+45; backend_pid=None;port=None
        while time.monotonic()<deadline:
            assert proc.poll() is None,'Launcher exited before readiness'
            command="Get-CimInstance Win32_Process -Filter \"Name='universal-hmi-server.exe'\" | Select-Object ProcessId,ExecutablePath | ConvertTo-Json -Compress"
            output=subprocess.check_output(['powershell','-NoProfile','-Command',command],creationflags=subprocess.CREATE_NO_WINDOW).decode('utf-8-sig').strip()
            processes=json.loads(output) if output else [];processes=processes if isinstance(processes,list) else [processes]
            own=[p for p in processes if p.get('ExecutablePath','').lower()==str(bundle/'universal-hmi-server.exe').lower()]
            if len(own)==1:
                backend_pid=own[0]['ProcessId']
                netstat=subprocess.check_output(['netstat','-ano','-p','tcp'],creationflags=subprocess.CREATE_NO_WINDOW).decode(errors='replace')
                for line in netstat.splitlines():
                    fields=line.split()
                    if len(fields)==5 and fields[-1]==str(backend_pid) and fields[3]=='LISTENING' and fields[1].startswith('127.0.0.1:'):
                        port=int(fields[1].split(':')[-1])
            if port:
                try:
                    health=json.loads(get(port,'/health'))
                    if health.get('service')=='universal-hmi':break
                except Exception:pass
            time.sleep(.25)
        else:raise RuntimeError('Backend readiness timeout')
        assert (port!=18080)==(mode=='conflict'),port
        screens=json.loads(get(port,'/api/v1/screens?all=true'));assert len(screens['items'])==2
        for path,rel in [('/','web/index.html'),('/gis/map.html','web/gis/map.html'),('/main.dart.js','web/main.dart.js')]:
            assert get(port,path)==(bundle/rel).read_bytes(),path
        if fixture:assert json.loads(get(18080,'/health'))['service']=='unrelated-port-fixture'
        print(json.dumps({'mode':mode,'backend_pid':backend_pid,'port':port,'awaiting':'native UI verification and normal close'}),flush=True)
        code=proc.wait(timeout=600);assert code==0,code
        with socket.socket() as probe:assert probe.connect_ex(('127.0.0.1',port))!=0,'Owned backend remains'
        if fixture:assert json.loads(get(18080,'/health'))['service']=='unrelated-port-fixture'
        result={'mode':mode,'port':port,'exit_code':code,'owned_backend_stopped':True,'unrelated_listener_preserved':mode=='conflict','web_and_gis_bytes_verified':True,'screens':len(screens['items'])}
        (work/f'{mode}-smoke.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
finally:
    if fixture:fixture.shutdown();fixture.server_close()

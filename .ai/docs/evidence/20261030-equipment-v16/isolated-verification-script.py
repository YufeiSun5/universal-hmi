import argparse,hashlib,json,os,shutil,subprocess,sys,time,winreg,urllib.request,http.cookiejar,secrets,socket
import urllib.error
from pathlib import Path
root=Path(__file__).resolve().parents[2]
work=root/'.local/full-v16-installer-verification'
manifest_path=root/'dist/installers/full-20261029-v16/Universal-HMI-20261029-Full-v16-Setup.manifest.json'
key=r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}_is1'
ps=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inventory(p):return {x.relative_to(p).as_posix():sha(x) for x in p.rglob('*') if x.is_file()}
def run_setup(exe,log,directory=None,reset=False):
 args=[str(exe),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',f'/LOG={log}']
 if directory:args.append(f'/DIR={directory}')
 if reset:args.append('/RESETV10=1')
 isolated=(work/'isolated-appdata').resolve()
 assert isolated == (root/'.local/full-v16-installer-verification/isolated-appdata').resolve()
 # Inno's {localappdata} is a Windows known folder, independent of this env var.
 # Pin detection and maintenance to the same explicitly isolated project.
 if any(v in exe.name for v in ('Full-v15-Setup','Full-v16-Setup')):
  args.append(f'/PROJECTROOT={isolated / "UniversalHMI/project"}')
 env=dict(os.environ,LOCALAPPDATA=str(isolated))
 result=subprocess.run(args,timeout=900,env=env)
 assert result.returncode==0,result.returncode
 if 'Full-v16-Setup' in exe.name:
  setup_log=log.read_text(encoding='utf-8-sig',errors='replace')
  assert 'CurStepChanged raised an exception' not in setup_log and 'Runtime error (at ' not in setup_log, 'Setup reported a maintenance exception despite exit code 0; preserve logs'
def load():return json.loads((work/'state.json').read_text(encoding='utf-8'))

def authenticated_api(url, credentials):
 opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
 request=urllib.request.Request(url+'/api/v1/auth/login',json.dumps(credentials).encode(),{'Content-Type':'application/json','Origin':url},method='POST')
 with opener.open(request,timeout=15) as response: session=json.load(response)
 assert session['authenticated']
 def call(method,path,body=None):
  data=None if body is None else json.dumps(body).encode()
  req=urllib.request.Request(url+path,data,{'Content-Type':'application/json','Origin':url,'X-CSRF-Token':session['csrf_token']},method=method)
  try:
   with opener.open(req,timeout=30) as response:return json.load(response)
  except urllib.error.HTTPError as error:
   detail=error.read().decode('utf-8',errors='replace')
   print(f'{method} {path} returned HTTP {error.code}: {detail[:500]}',file=sys.stderr,flush=True)
   raise
 return call

def point_digest(call):
 points=call('GET','/api/v1/points')['items']
 assert len(points)==5019, f'Expected 5019 synthetic points, got {len(points)}'
 return hashlib.sha256(json.dumps(points,sort_keys=True,ensure_ascii=False).encode()).hexdigest()

def rejected(call,method,path,body,expected):
 try: call(method,path,body)
 except urllib.error.HTTPError as error:
  assert error.code==expected, f'{path}: expected HTTP {expected}, got {error.code}'
 else: raise AssertionError(f'{path}: request unexpectedly succeeded')

def table_hashes(state):
 project=Path(state['appdata'])/'UniversalHMI/project'
 private=json.loads((project/'private-settings.json').read_text(encoding='utf-8-sig'))
 env=dict(os.environ,PGPASSWORD=private['adminPassword'])
 result={}
 for table in ['users','stations','audit','mfa','recovery','custom_roles','user_role_policy','samples','executions','config','documents']:
  query="SELECT json_build_object('count',count(*),'digest',md5(coalesce(string_agg(row_to_json(t)::text,E'\\n' ORDER BY row_to_json(t)::text),''))) FROM "+table+' t'
  result[table]=json.loads(subprocess.check_output([str(Path(state['payload'])/'postgresql/bin/psql.exe'),'-X','-w','-h','127.0.0.1','-p',str(private['pgPort']),'-U','hmi_admin','-d','universal_hmi','-Atc',query],env=env,encoding='utf-8'))
 return result
def launcher(state,view='runtime',stop=False):
 env=dict(os.environ,LOCALAPPDATA=state['appdata'])
 args=[str(ps),'-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',str(Path(state['payload'])/'Start-HMI.ps1'),'-View',view,'-NoUI']
 if stop:args.append('-Stop')
 with (work/('launch-'+('stop' if stop else view)+'.log')).open('wb') as log:
  result=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=160,creationflags=subprocess.CREATE_NO_WINDOW)
 assert result.returncode==0,result.returncode

def assert_isolated_stopped(state,project):
 assert project.resolve()==(work/'isolated-appdata/UniversalHMI/project').resolve()
 private=json.loads((project/'private-settings.json').read_text(encoding='utf-8-sig'))
 assert private['httpPort']==18084 and private['pgPort']==55436
 for port in (private['httpPort'],private['pgPort']):
  with socket.socket() as sock:
   try: sock.bind(('127.0.0.1',port))
   except OSError as error: raise RuntimeError(f'Isolated port {port} still occupied; retain both project copies') from error
 pgctl=Path(state['payload'])/'postgresql/bin/pg_ctl.exe'
 status=subprocess.run([str(pgctl),'status','-D',str(project/'postgres-data')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW)
 assert status.returncode==3, 'PostgreSQL stop not confirmed; retain both project copies'

def pg_query(state,query):
 project=Path(state['appdata'])/'UniversalHMI/project';private=json.loads((project/'private-settings.json').read_text(encoding='utf-8-sig'));env=dict(os.environ,PGPASSWORD=private['adminPassword'])
 return subprocess.check_output([str(Path(state['payload'])/'postgresql/bin/psql.exe'),'-X','-w','-h','127.0.0.1','-p',str(private['pgPort']),'-U','hmi_admin','-d','universal_hmi','-v','ON_ERROR_STOP=1','-Atc',query],env=env,encoding='utf-8').strip()

def save(state):
 (work/'state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding='utf-8')

def maintenance_inventory(state):
 parent=Path(state['appdata'])/'UniversalHMI'
 return {n:inventory(parent/n) if (parent/n).exists() else {} for n in ('project-maintenance','project-backups')}

def shortcuts(state,restore=False):
 desktop=Path(state['folders']['desktop']);programs=Path(state['folders']['programs'])
 candidates=list(desktop.glob('Universal HMI*.lnk'))
 for group in ('Universal HMI','Universal HMI 测试版'):candidates+=list((programs/group).glob('*'))
 if restore:
  for p in candidates:
   if p.is_file() and str(p) not in state['saved_shortcuts']:p.unlink()
  for name,index in state['saved_shortcuts'].items():
   p=Path(name);p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(work/'shortcuts-before'/index,p);assert sha(p)==sha(work/'shortcuts-before'/index)
 else:
  state['saved_shortcuts']={}
  for i,p in enumerate(candidates):
   if p.is_file():shutil.copy2(p,work/'shortcuts-before'/str(i));state['saved_shortcuts'][str(p)]=str(i)

def equipment_snapshot(state):
 project=Path(state['appdata'])/'UniversalHMI/project'
 return {'raw_config':pg_query(state,"SELECT value FROM config WHERE key='equipment_register'"),'photos':inventory(project/'equipment/photos'),'navigation_rows':pg_query(state,"SELECT count(*) FROM config WHERE key='equipment_navigation'")}

def seed_legacy_equipment(state):
 project=Path(state['appdata'])/'UniversalHMI/project';photos=project/'equipment/photos';photos.mkdir(parents=True,exist_ok=True)
 inputs=[('legacy-png',root/'app/assets/process/examples/inline-pump-v1.png','image/png'),('legacy-jpeg',root/'examples/gis-flight/moon-albedo.jpg','image/jpeg')]
 devices=[]
 for index,(pid,source,mime) in enumerate(inputs):
  assert source.exists();shutil.copy2(source,photos/pid)
  device={'id':'legacy-equipment-'+str(index),'revision':1,'station':'CrossStationReview','site':'Legacy Area','code':'LEGACY-'+str(index),'name':('测试泵示意图（非现场照片）' if index==0 else 'JPEG解码保留校验（非展示设备）'),'category':'pump','properties':[{'name':'test','value':'preserve','unit':''}],'photos':[{'id':pid,'name':source.name,'mime':mime}],'updated':'2026-10-30T00:00:00Z'}
  if index==1:device['signals']={'running':{'point_id':'pt_fc26e12e140bb6b123f157d8','expression':'v > 0'}}
  assert 'photo_fit' not in device;devices.append(device)
 raw=json.dumps(devices,ensure_ascii=True,separators=(',',':'));escaped=raw.replace("'","''")
 pg_query(state,"INSERT INTO config(key,value) VALUES('equipment_register','"+escaped+"') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
 assert pg_query(state,"SELECT count(*) FROM config WHERE key='equipment_navigation'")=='0'
 state['equipment_before']=equipment_snapshot(state)

mode=sys.argv[1]
if mode=='prepare':
 assert not work.exists(),'New fixture directory required'
 try:
  with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key):raise RuntimeError('Existing installer registration; refuse')
 except FileNotFoundError:pass
 for port in (18084,55436):
  with socket.socket() as sock:sock.bind(('127.0.0.1',port))
 work.mkdir();(work/'shortcuts-before').mkdir()
 folders=json.loads(subprocess.check_output([str(ps),'-NoProfile','-Command',"[pscustomobject]@{desktop=[Environment]::GetFolderPath('Desktop');programs=[Environment]::GetFolderPath('Programs')}|ConvertTo-Json -Compress"],encoding='utf-8-sig'))
 state={'folders':folders,'installed':str(work/'installed'),'appdata':str(work/'isolated-appdata')};shortcuts(state);save(state)
 project=Path(state['appdata'])/'UniversalHMI/project';shutil.copytree(root/'.local/full-v15-installer-verification/isolated-appdata/UniversalHMI/project',project)
 private=json.loads((project/'private-settings.json').read_text(encoding='utf-8-sig'));assert private['httpPort']==18084 and private['pgPort']==55436
 old=root/'dist/installers/full-20261029-v15/Universal-HMI-20261029-Full-v15-Setup.exe';run_setup(old,work/'old-install.log',Path(state['installed']));meta=json.loads(old.with_suffix('.manifest.json').read_text());state['payload']=str(Path(state['installed'])/'versions'/meta['payload_id']);save(state);launcher(state)
 credentials=json.loads((project/'test-account.json').read_text());api=authenticated_api('http://127.0.0.1:18084',credentials)
 state['mock_point_id']='pt_fc26e12e140bb6b123f157d8';assert len(api('GET','/api/v1/points')['items'])==5019
 assert api('POST','/api/v1/points/'+state['mock_point_id']+'/sample',{'value':42.5})['accepted']
 seed_legacy_equipment(state)
 state['synthetic_points_digest']=point_digest(api);state['source_configuration']=api('GET','/api/v1/runtime')['sources'];state['screens']=api('GET','/api/v1/screens?all=true');state['before_navigation']=api('GET','/api/v1/navigation')
 time.sleep(1);state['before_tables']=table_hashes(state);assert state['before_tables']['samples']['count']>=1
 state['maintenance_before']=maintenance_inventory(state);state['remote_hash']=sha(project/'remote-access.json');save(state);launcher(state,stop=True);assert_isolated_stopped(state,project);shortcuts(state,True)
 print('PASS v15 baseline prepared:5019 points,all=true baseline screens,recent history; stopped,original shortcuts restored',flush=True)
elif mode=='upgrade':
 state=load();project=Path(state['appdata'])/'UniversalHMI/project';meta=json.loads(manifest_path.read_text());exe=Path(meta['installer']);assert sha(exe)==meta['sha256'];assert meta['upgrade_policy']=='preserve-only' and meta['installer_invokes_project_reset'] is False
 run_setup(exe,work/'new-install.log',Path(state['installed']));state['payload']=str(Path(state['installed'])/'versions'/meta['payload_id']);save(state)
 assert maintenance_inventory(state)==state['maintenance_before'];launcher(state);assert equipment_snapshot(state)==state['equipment_before'];assert table_hashes(state)==state['before_tables'],'Upgrade changed PostgreSQL table hashes'
 credentials=json.loads((project/'test-account.json').read_text());api=authenticated_api('http://127.0.0.1:18084',credentials);assert point_digest(api)==state['synthetic_points_digest'];assert api('GET','/api/v1/screens?all=true')==state['screens'];assert api('GET','/api/v1/navigation')==state['before_navigation'];assert api('GET','/api/v1/runtime')['sources']==state['source_configuration'];assert sha(project/'remote-access.json')==state['remote_hash']
 # Refresh only mock current value, never any physical source.
 assert api('POST','/api/v1/points/'+state['mock_point_id']+'/sample',{'value':42.5})['accepted']
 payload=Path(state['payload']);app=json.loads((payload/'build-manifest.json').read_text());assert all(sha(payload/n)==v for n,v in app['artifacts'].items());dep=json.loads((payload/'deployment-manifest.json').read_text());assert all(sha(payload/'postgresql'/n)==v for n,v in dep['postgresql_files'].items());assert dep['upgrade_policy']=='preserve-only' and dep['installer_invokes_project_reset'] is False
 state['upgrade_verified']=True;save(state);(work/'browser-review-ready.json').write_text(json.dumps({'url':'http://127.0.0.1:18084','credentials_file':str(project/'test-account.json'),'screen_id':'cross-station-review','mock_point_id':state['mock_point_id'],'expected_value':42.5,'expected_owner':'CrossStationReview','business_station':'CrossStationReview','fixture_only':True},indent=2));print('PASS ordinary upgrade; browser gate ready, server retained until root review complete',flush=True)
elif mode=='cleanup':
 state=load();assert (work/'stop-mock-feed').exists(), 'Stop mock feed only after root browser approval';project=Path(state['appdata'])/'UniversalHMI/project';launcher(state,stop=True);assert_isolated_stopped(state,project);before=inventory(project)
 uninstaller=Path(state['installed'])/'unins000.exe';subprocess.run([str(uninstaller),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',f'/LOG={work/"uninstall.log"}'],check=True,timeout=300);assert inventory(project)==before;shortcuts(state,True)
 report={'status':'passed','ordinary_upgrade':True,'automatic_process_import':False,'variables_preserved':5019,'screens_preserved':len(state.get('all_screens',state['screens'])['items']),'bindings_preserved':True,'sources_preserved':True,'tables_before':state['before_tables'],'no_reset_invoked':maintenance_inventory(state)==state['maintenance_before'],'shortcuts_restored':True,'isolated_ports_stopped':True,'uninstall_project_bytes_unchanged':True};(work/'result.json').write_text(json.dumps(report,indent=2));print('Cleanup passed; original shortcuts restored')
else:raise ValueError(mode)

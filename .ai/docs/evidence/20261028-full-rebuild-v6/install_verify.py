import argparse,hashlib,json,os,shutil,subprocess,sys,time,winreg,urllib.request,secrets
from pathlib import Path
root=Path(__file__).resolve().parents[2]
work=root/'.local/full-v6-installer-verification'
manifest_path=root/'dist/installers/full-20261028-v6/Universal-HMI-20261028-Full-v6-Setup.manifest.json'
key=r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}_is1'
ps=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inventory(p):return {x.relative_to(p).as_posix():sha(x) for x in p.rglob('*') if x.is_file()}
def run_setup(exe,log,directory=None):
 args=[str(exe),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',f'/LOG={log}']
 if directory:args.append(f'/DIR={directory}')
 result=subprocess.run(args,timeout=300)
 assert result.returncode==0,result.returncode
def load():return json.loads((work/'state.json').read_text(encoding='utf-8'))

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
mode=sys.argv[1]
if mode=='install':
 try:
  with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key):raise RuntimeError('User installation already exists; refuse registration overwrite')
 except FileNotFoundError:pass
 work.mkdir(parents=True,exist_ok=False)
 backup=work/'shortcuts-before';backup.mkdir()
 command="[pscustomobject]@{desktop=[Environment]::GetFolderPath('Desktop');programs=[Environment]::GetFolderPath('Programs')} | ConvertTo-Json -Compress"
 folders=json.loads(subprocess.check_output([str(ps),'-NoProfile','-Command',command],encoding='utf-8-sig'))
 saved={}
 candidates=list(Path(folders['desktop']).glob('Universal HMI*.lnk'))
 for group in ['Universal HMI','Universal HMI 测试版']:
  candidates+=list((Path(folders['programs'])/group).glob('*'))
 for i,p in enumerate(candidates):
  if p.is_file():shutil.copy2(p,backup/str(i));saved[str(p)]=str(i)
 appdata=work/'isolated-appdata';legacy=appdata/'universal-hmi-mqtt-gis-trial-20261026-v2'
 shutil.copytree(root/'.local/installer-trial-20261026-v3/isolated-appdata/universal-hmi-mqtt-gis-trial-20261026-v2',legacy)
 before=inventory(legacy)
 shutil.copytree(root/'.local/lazy-installer-verification/isolated-appdata/UniversalHMI/project',appdata/'UniversalHMI/project')
 installed=work/'installed'
 state={'saved_shortcuts':saved,'folders':folders,'installed':str(installed),'appdata':str(appdata),'legacy_inventory':before}
 (work/'state.json').write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
 run_setup(root/'dist/installers/update-20261028/Universal-HMI-20261028-PG-Setup.exe',work/'old-install.log',installed)
 assert inventory(legacy)==before
 oldmeta=json.loads((root/'dist/installers/update-20261028/Universal-HMI-20261028-PG-Setup.manifest.json').read_text(encoding='utf-8'))
 state['payload']=str(installed/'versions'/oldmeta['payload_id'])
 (work/'state.json').write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
 launcher(state)
 project=Path(state['appdata'])/'UniversalHMI/project'
 url=json.loads((project/'ready.json').read_text(encoding='utf-8-sig'))['url']
 password=secrets.token_urlsafe(24)
 request=urllib.request.Request(url+'/api/v1/auth/setup',json.dumps({'username':'upgrade-check','password':password}).encode(),{'Content-Type':'application/json','Origin':url},method='POST')
 with urllib.request.urlopen(request,timeout=15) as response:assert json.load(response)['created']
 (project/'test-account.json').write_text(json.dumps({'username':'upgrade-check','password':password}),encoding='utf-8')
 state['before_tables']=table_hashes(state)
 assert state['before_tables']['users']['count']==1
 launcher(state,stop=True)
 (work/'state.json').write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
 deadline=time.time()+900
 while not manifest_path.exists():
  assert time.time()<deadline,'Timed out waiting for the completed installer build'
  time.sleep(5)
 run_setup(root/'dist/installers/full-20261028-v6/Universal-HMI-20261028-Full-v6-Setup.exe',work/'new-install.log',installed)
 assert inventory(legacy)==before
 with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key) as registration:
  assert winreg.QueryValueEx(registration,'DisplayVersion')[0]=='0.1.0.6'
 meta=json.loads(manifest_path.read_text(encoding='utf-8'));payload=installed/'versions'/meta['payload_id']
 app=json.loads((payload/'build-manifest.json').read_text(encoding='utf-8'))
 for name,checksum in app['artifacts'].items():assert sha(payload/name)==checksum,name
 deployment=json.loads((payload/'deployment-manifest.json').read_text(encoding='utf-8'))
 assert sha(payload/'Start-HMI.ps1')==deployment['launcher_sha256']
 for name,checksum in deployment['postgresql_files'].items():assert sha(payload/'postgresql'/name)==checksum,name
 assert all(sha(root/name)==checksum for name,checksum in deployment['packaging_sources'].items())
 for name in ['GIS 展示','工艺图展示','MQTT 开发配置']:assert not (Path(folders['desktop'])/f'Universal HMI - {name}.lnk').exists()
 for name in ['运行态','开发态']:assert (Path(folders['desktop'])/f'Universal HMI - {name}.lnk').exists()
 command="$shell=New-Object -ComObject WScript.Shell; Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Desktop')) -Filter 'Universal HMI*.lnk' | ForEach-Object { $s=$shell.CreateShortcut($_.FullName); [pscustomobject]@{Name=$_.Name;Target=$s.TargetPath;Arguments=$s.Arguments} } | ConvertTo-Json -Compress"
 links=json.loads(subprocess.check_output([str(ps),'-NoProfile','-Command',command],encoding='utf-8-sig'))
 for link in links:
  if link['Name'] in ['Universal HMI - 运行态.lnk','Universal HMI - 开发态.lnk']:assert str(payload) in link['Arguments'],link
 state['payload']=str(payload);state['verified_application_files']=len(app['artifacts']);state['verified_pg_files']=len(deployment['postgresql_files'])
 (work/'state.json').write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
 print(json.dumps({k:v for k,v in state.items() if k in ['payload','installed','verified_application_files','verified_pg_files']},ensure_ascii=False),flush=True)
elif mode in ['runtime','developer','stop']:
 state=load()
 launcher(state,mode if mode!='stop' else 'runtime',mode=='stop')
 if mode!='stop':assert table_hashes(state)==state['before_tables'],'Upgrade changed existing PostgreSQL tables'
 if mode=='developer':
  project=Path(state['appdata'])/'UniversalHMI/project'
  url=json.loads((project/'ready.json').read_text(encoding='utf-8-sig'))['url']
  for asset in ['/main.dart.js','/flutter_bootstrap.js','/gis/orbital-scene.js','/gis/stations.js','/gis/tour.js','/gis/flight.js','/gis/flight.css','/gis/map.html']:
   with urllib.request.urlopen(url+asset,timeout=15) as response:assert response.read()==(Path(state['payload'])/'web'/asset.lstrip('/')).read_bytes()
  credentials=json.loads((project/'test-account.json').read_text())
  request=urllib.request.Request(url+'/api/v1/auth/login',json.dumps(credentials).encode(),{'Content-Type':'application/json','Origin':url},method='POST')
  with urllib.request.urlopen(request,timeout=15) as response:assert json.load(response)['authenticated']
  state['existing_account_login']=True;state['served_web_gis_bytes_verified']=True
  (work/'state.json').write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
 print(mode+' launch complete',flush=True)
elif mode=='uninstall':
 state=load();project=Path(state['appdata'])/'UniversalHMI/project'
 launcher(state,stop=True)
 before=inventory(project)
 run_setup(Path(state['installed'])/'unins000.exe',work/'uninstall.log')
 assert inventory(project)==before,'Uninstall changed project or PostgreSQL data'
 legacy=Path(state['appdata'])/'universal-hmi-mqtt-gis-trial-20261026-v2'
 assert inventory(legacy)==state['legacy_inventory']
 try:
  with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key):raise RuntimeError('Registration was not removed')
 except FileNotFoundError:pass
 for path,name in state['saved_shortcuts'].items():
  p=Path(path);p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(work/'shortcuts-before'/name,p)
  assert sha(p)==sha(work/'shortcuts-before'/name)
 report={'previous_pg_installer_upgrade':True,'existing_account_login':state.get('existing_account_login',False),'served_web_gis_bytes_verified':state.get('served_web_gis_bytes_verified',False),'existing_pg_tables_unchanged':state['before_tables'],'application_files_verified':state['verified_application_files'],'pg_files_verified':state['verified_pg_files'],'legacy_unchanged':True,'uninstall_preserves_pg_and_keys':True,'original_shortcuts_restored':True}
 (work/'result.json').write_text(json.dumps(report,indent=2),encoding='utf-8');print(json.dumps(report),flush=True)
else:raise ValueError(mode)

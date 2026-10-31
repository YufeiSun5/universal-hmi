from pathlib import Path
import sys,os,subprocess,json,hashlib,shutil,time
root=Path('D:/DEV_D/KPimport');work=root/'.local/full-rebuild-20261028-v6'
sys.path.insert(0,str(root/'ci'))
from build_release import sources
before=sources()
assert before==json.loads((work/'source-files.json').read_text(encoding='utf-8'))
(work/'source-files.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
report={'source_sha256':hashlib.sha256(json.dumps(before,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'steps':[],'started':time.time()}
previous=json.loads((work/'build-result.json').read_text(encoding='utf-8'))
shutil.copy2(work/'build-result.json',work/'first-attempt-result.json')
report=previous
def run(name,args,cwd=root):
 if any(step['name']==name and step['exit_code']==0 for step in report['steps']):return
 print('START '+name,flush=True)
 started=time.time()
 with (work/(name+'.log')).open('w',encoding='utf-8') as stream:
  result=subprocess.run([str(x) for x in args],cwd=cwd,stdout=stream,stderr=subprocess.STDOUT)
 report['steps'].append({'name':name,'exit_code':result.returncode,'seconds':round(time.time()-started,2)})
 (work/'build-result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 if result.returncode:
  print((work/(name+'.log')).read_text(encoding='utf-8')[-6000:],flush=True)
  raise SystemExit(result.returncode)
 print('PASS '+name,flush=True)
flutter=shutil.which('flutter');go=shutil.which('go');dart=shutil.which('dart');py=sys.executable
run('go-version',[go,'version'])
run('go-mod-verify',[go,'mod','verify'],root/'backend')
run('go-test',[go,'test','-mod=readonly','./...'],root/'backend')
run('go-vet',[go,'vet','-mod=readonly','./...'],root/'backend')
run('flutter-pub',[flutter,'pub','get','--enforce-lockfile'],root/'app')
run('dart-format',[dart,'format','--output=none','--set-exit-if-changed','lib','test','integration_test','test_driver'],root/'app')
run('flutter-analyze',[flutter,'analyze','--no-pub'],root/'app')
run('flutter-test',[flutter,'test','--no-pub','test'],root/'app')
run('packaging-tests',[py,'-m','unittest','discover','-s','ci','-p','test_installers.py'])
run('gis-resource-tests',[py,'-m','unittest','discover','-s','ci','-p','test_stage_gis.py'])
run('gis-tour-tests',['node','ci/test_gis_tour.cjs'])
assert before==sources(),'Sources changed during tests'
# Keep prior output for recovery; compile both targets into fresh directories.
for target in ['windows','web']:
 source=(root/'app/build'/target).resolve();saved=(work/('prior-'+target)).resolve()
 assert source.is_relative_to((root/'app/build').resolve()) and saved.is_relative_to(work.resolve())
 if source.exists():shutil.move(str(source),str(saved))
run('go-build',[go,'build','-mod=readonly','-o',root/'dist/universal-hmi-server.exe','./cmd/server'],root/'backend')
run('windows-build',[py,'ci/build_release.py','windows'])
run('web-build',[py,'ci/build_release.py','web','--gis-site',root/'.local/gis-flight-demo/site-lod'])
run('package-desktop',[py,'ci/package_desktop.py','windows'])
run('package-final',[py,'ci/package_final.py','--targets','windows','--stage-local'])
assert before==sources(),'Sources changed during build'
bundle=root/'dist/Universal-HMI-Full-20261028-v6'
shutil.copytree(root/'dist/windows',bundle)
run('installer-build',[py,'ci/build_windows_lazy.py','--bundle',bundle,'--postgres-zip',root/'.local/postgresql-package/postgresql-18.6-5-windows-x64-binaries.zip','--compiler',root/'.local/toolchains/inno-setup-6.7.3/ISCC.exe','--output',root/'dist/installers/full-20261028-v6'])
assert before==sources(),'Sources changed during packaging'
report['complete']=True;report['completed']=time.time()
(work/'build-result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('COMPLETE '+report['source_sha256'],flush=True)

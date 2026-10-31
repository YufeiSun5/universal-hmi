from pathlib import Path
import sys,json,shutil,subprocess,time
root=Path('D:/DEV_D/KPimport');work=root/'.local/full-rebuild-20261028-v6';bundle=root/'dist/Universal-HMI-Full-20261028-v6'
sys.path.insert(0,str(root/'ci'))
from build_release import sha256,sources
assert sources()==json.loads((work/'source-files.json').read_text())
manifest=json.loads((bundle/'build-manifest.json').read_text())
shutil.copytree(root/'.ai/docs/licenses',bundle/'licenses')
for p in (bundle/'licenses').rglob('*'):
 if p.is_file():manifest['artifacts'][p.relative_to(bundle).as_posix()]=sha256(p)
(bundle/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
start=time.time()
with (work/'installer-build-retry.log').open('w',encoding='utf-8') as log:
 result=subprocess.run([sys.executable,'ci/build_windows_lazy.py','--bundle',str(bundle),'--postgres-zip',str(root/'.local/postgresql-package/postgresql-18.6-5-windows-x64-binaries.zip'),'--compiler',str(root/'.local/toolchains/inno-setup-6.7.3/ISCC.exe'),'--output',str(root/'dist/installers/full-20261028-v6')],stdout=log,stderr=subprocess.STDOUT)
assert result.returncode==0,(work/'installer-build-retry.log').read_text()[-3000:]
assert sources()==json.loads((work/'source-files.json').read_text())
report=json.loads((work/'build-result.json').read_text());report['steps'].append({'name':'installer-build-with-license-notices','exit_code':0,'seconds':round(time.time()-start,2)})
report['complete']=True;report['completed']=time.time();(work/'build-result.json').write_text(json.dumps(report,indent=2))
print('COMPLETE '+report['source_sha256'],flush=True)

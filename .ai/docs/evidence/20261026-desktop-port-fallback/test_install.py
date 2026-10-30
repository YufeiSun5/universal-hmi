import json, os, shutil, subprocess, sys, winreg
from pathlib import Path
work=Path(__file__).resolve().parent; root=work.parents[1]
sys.path.insert(0,str(root/'ci'))
from build_installers import verify_bundle
from build_release import sha256
key=r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}_is1'
try:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key):
        raise RuntimeError('Existing user installation: refuse test registration overwrite')
except FileNotFoundError: pass
installed=work/'installed'; assert not installed.exists()
appdata=work/'isolated-appdata'; data=appdata/'universal-hmi-mqtt-gis-trial-20261026-v2'
shutil.copytree(root/'.local/mqtt-trial-gis-20261026/extras/example-project',data)
(data/'upgrade-preserve.txt').write_text('Existing v2 user data must survive upgrade and uninstall.')
def inventory(): return {str(p.relative_to(data)):sha256(p) for p in data.rglob('*') if p.is_file()}
before=inventory()
for version in ('v2','v3'):
    setup=root/f'dist/installers/Universal-HMI-MQTT-GIS-20261026-{version}-Setup.exe'
    result=subprocess.run([str(setup),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',f'/DIR={installed}',f'/LOG={work / (version+"-install.log")}'])
    assert result.returncode==0, result.returncode
    assert inventory()==before,'Existing data modified by installation'
manifest=json.loads((root/'dist/Universal-HMI-MQTT-GIS-Trial-20261026-v3/build-manifest.json').read_text())
payload=installed/'versions'/manifest['source_sha256'][:24]
verify_bundle(payload,'windows')
assert sha256(payload/'build-manifest.json')==sha256(root/'dist/Universal-HMI-MQTT-GIS-Trial-20261026-v3/build-manifest.json')
result={'installed':str(installed),'payload':str(payload),'payload_files_verified':len(manifest['artifacts'])+1,'v2_to_v3_upgrade':True,'existing_data_preserved':True}
(work/'install-result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result),flush=True)

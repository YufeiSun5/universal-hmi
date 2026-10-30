import hashlib, json, subprocess, time
from pathlib import Path
work = Path(__file__).resolve().parent
root = work.parents[1]
installed = (work/'installed').resolve()
assert installed.is_relative_to((root/'.local/installer-trial-20261026-v3').resolve())
assert installed.name == 'installed'
data = work/'isolated-appdata/universal-hmi-mqtt-gis-trial-20261026-v2'
assert data.is_dir()
def inventory():
    return {p.relative_to(data).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in data.rglob('*') if p.is_file()}
before = inventory()
assert before
uninstaller = installed/'unins000.exe'
assert uninstaller.is_file()
result = subprocess.run([str(uninstaller), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', f'/LOG={work/"uninstall.log"}'])
assert result.returncode == 0, result.returncode
deadline=time.monotonic()+30
while installed.exists() and time.monotonic()<deadline:
    time.sleep(.2)
assert not installed.exists(), 'Installer-owned directory remains'
assert inventory() == before, 'App data changed during uninstall'
evidence={'exit_code':0,'installed_files_removed':True,'data_preserved':True,'data_file_count':len(before)}
(work/'uninstall-result.json').write_text(json.dumps(evidence,indent=2),encoding='utf-8')
print(json.dumps(evidence),flush=True)

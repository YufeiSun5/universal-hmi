"""Package a built static site and server; never include the source-image cache."""
import argparse
import hashlib
from pathlib import Path
import zipfile

p = argparse.ArgumentParser()
p.add_argument('--site', type=Path, required=True)
p.add_argument('--server', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
site, server, output = a.site.resolve(), a.server.resolve(), a.output.resolve()
if not (site / 'imagery/manifest.json').is_file() or not server.is_file():
    raise SystemExit('Build the imagery and server first')
if output.is_relative_to(site):
    raise SystemExit('Archive must be outside the public site')
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    z.write(server, 'Start-GIS.exe')
    for path in sorted(site.rglob('*')):
        if path.is_file():
            z.write(path, 'site/' + path.relative_to(site).as_posix())
    for path in Path(__file__).parent.iterdir():
        if path.is_file() and path.suffix in ('.py','.go','.js','.css','.html','.md','.txt','.json','.svg','.png'):
            z.write(path, 'source/' + path.name)
    for name in ('README.md', 'THIRD_PARTY_NOTICES.txt', 'verification.json'):
        z.write(Path(__file__).with_name(name), name)
output.with_suffix('.sha256').write_text(hashlib.sha256(output.read_bytes()).hexdigest() + '  ' + output.name + '\n')
print(output)

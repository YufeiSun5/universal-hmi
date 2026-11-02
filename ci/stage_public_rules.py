"""Vendor pinned request-only CRS assets from checksum-verified Go module ZIPs.

Response inspection is deliberately absent: it would buffer SSE and imports
response-only signatures unnecessary for request admission. Never alters AV.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / 'backend/internal/publicguard/rules'
MODULES = {
    'github.com/corazawaf/coraza-coreruleset/crs/v4': ('v4.30.0', 'h1:XMYT7VOFM2VrpIKMUn4vFWyoFNYg1ZaYiexs76AmxzQ='),
    'github.com/corazawaf/coraza-coreruleset/coraza/v3': ('v3.8.1', 'h1:Cd5JFZKRA22dh5coq5cBK/0mMEBvAkYjSvaxy+nkXYA='),
}

def verified_zip(cache, module, version, expected):
    archive = cache / 'cache/download' / module / '@v' / (version + '.zip')
    source = zipfile.ZipFile(archive)
    lines = []
    for name in sorted(source.namelist()):
        if not name.endswith('/'):
            lines.append(hashlib.sha256(source.read(name)).hexdigest()+'  '+name+'\n')
    actual = 'h1:'+base64.b64encode(hashlib.sha256(''.join(lines).encode()).digest()).decode()
    assert actual == expected, 'Upstream module archive checksum mismatch'
    return source, expected

def stage(cache):
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = {'schema':1, 'scope':'request-only; no response rules', 'modules':{}, 'files':{}}
    for module, (version, expected) in MODULES.items():
        source, checksum = verified_zip(cache, module, version, expected)
        manifest['modules'][module] = {'version':version, 'go_sum':checksum}
        prefix = f'{module}@{version}/'
        files = {name[len(prefix):]:name for name in source.namelist() if name.startswith(prefix) and not name.endswith('/')}
        if module.endswith('/crs/v4'):
            chosen = [n for n in files if n.startswith('rules/@owasp_crs/REQUEST-') and n.endswith('.conf')]
            chosen.append('rules/@crs-setup.conf.example')
            # Resolve every data-file reference made by request rules only.
            data = set()
            for name in chosen:
                text = source.read(files[name]).decode()
                data.update(re.findall(r'\b[\w.-]+\.data\b', text))
            chosen += ['rules/@owasp_crs/'+name for name in sorted(data)]
            chosen += ['LICENSE', 'rules/LICENSE']
            destinations = {n:(n.removeprefix('rules/')) for n in chosen}
            destinations['LICENSE'] = 'LICENSE-CRS.txt'
            destinations['rules/LICENSE'] = 'LICENSE-CRS-rules.txt'
        else:
            destinations = {'files/@coraza.conf-recommended':'@coraza.conf-recommended', 'LICENSE':'LICENSE-Coraza-config.txt'}
        for name, relative in destinations.items():
            assert name in files, f'Missing upstream request asset: {name}'
            content = source.read(files[name])
            target = DEST / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            manifest['files'][relative] = {'sha256':hashlib.sha256(content).hexdigest(), 'module':module, 'path':name}
        source.close()
    (DEST/'provenance.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
    print(f'Verified {len(manifest["files"])} request-rule/config/license files')

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module-cache', type=Path, required=True)
    stage(parser.parse_args().module_cache)

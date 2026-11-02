"""Stage real runtime license texts before calculating the desktop inventory."""
import json
from pathlib import Path
import shutil
import subprocess

from common import ROOT


def copy_text(source, target):
    # Go's module cache is read-only; release staging must remain rebuildable.
    if target.exists():
        target.chmod(0o666)
    shutil.copyfile(source, target)


def stage(bundle):
    destination = Path(bundle) / 'licenses'
    destination.mkdir(parents=True, exist_ok=True)
    output = subprocess.check_output(
        ['go', 'list', '-mod=readonly', '-deps', '-json', './cmd/server',
         './cmd/certificate', './cmd/service-host', './cmd/rebuild'],
        cwd=ROOT / 'backend', text=True, encoding='utf-8')
    decoder = json.JSONDecoder()
    modules = {}
    while output.strip():
        record, end = decoder.raw_decode(output.lstrip())
        output = output.lstrip()[end:]
        module = record.get('Module', {})
        if module.get('Version') and module.get('Dir'):
            modules[module['Path'] + '@' + module['Version']] = Path(module['Dir'])
    inventory = []
    for name, directory in sorted(modules.items()):
        texts = [p for p in directory.iterdir() if p.is_file()
                 and p.name.upper().split('.')[0] in ('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'AUTHORS', 'PATENTS')]
        assert texts, 'Runtime module lacks license text: ' + name
        target = destination / 'go-modules' / name
        target.mkdir(parents=True, exist_ok=True)
        for text in texts:
            copy_text(text, target / text.name)
        inventory.append({'module': name, 'files': [p.name for p in texts]})
    go_root = Path(subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip())
    copy_text(go_root / 'LICENSE', destination / 'Go-LICENSE.txt')
    rules = ROOT / 'backend/internal/publicguard/rules'
    for text in rules.rglob('*'):
        if text.is_file() and (text.name.upper().startswith(('LICENSE', 'NOTICE')) or text.name.lower() == 'provenance.json'):
            target = destination / 'publicguard' / text.relative_to(rules)
            target.parent.mkdir(parents=True, exist_ok=True)
            copy_text(text, target)
    (destination / 'RUNTIME-NOTICES.txt').write_text(
        'Go runtime and actually linked Go module license texts are included here.\n'
        'Flutter/Dart dependency notices: data/flutter_assets/NOTICES.Z.\n'
        'OWASP CRS and Coraza configuration provenance/license texts: publicguard/.\n'
        'App-local Microsoft VC++ runtime is copied only from the installed release redist.\n'
        'Redistributable list: https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution\n'
        'Microsoft runtime files remain subject to the applicable Visual Studio license terms.\n', encoding='utf-8')
    (destination / 'go-runtime-modules.json').write_text(json.dumps(inventory, indent=2) + '\n', encoding='utf-8')
    return len(modules)

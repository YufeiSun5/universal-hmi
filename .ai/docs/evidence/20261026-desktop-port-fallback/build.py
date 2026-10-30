import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'ci'))
from build_installers import verify_bundle
from build_release import sha256

bundle = ROOT / 'dist/Universal-HMI-MQTT-GIS-Trial-20261026-v3'
output = ROOT / 'dist/installers'
output.mkdir(exist_ok=True)
manifest = verify_bundle(bundle, 'windows')
from build_release import sources
assert manifest['source_files'] == sources()

template = (ROOT / 'packaging/windows.iss').read_text(encoding='utf-8')
template = template.replace('{{7A47C722-492D-4D71-9093-A0F1F17C2842}', '{{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}')
template = template.replace('AppName=Universal HMI', 'AppName=Universal HMI MQTT GIS Trial')
template = template.replace('AppVerName=Universal HMI {#ProductVersion}', 'AppVerName=Universal HMI MQTT GIS Trial 2026.10.26 v3')
template = template.replace('DefaultDirName={localappdata}\\Programs\\Universal HMI', 'DefaultDirName={localappdata}\\Programs\\Universal HMI MQTT GIS Trial')
template = template.replace('OutputBaseFilename=universal-hmi-windows-x64-setup', 'OutputBaseFilename=Universal-HMI-MQTT-GIS-20261026-v3-Setup')
template = template.replace('MinVersion=10.0', 'MinVersion=10.0.17763')
template = template.replace('InfoBeforeFile=README.txt', 'InfoBeforeFile=INSTALL.txt')
template = template.replace('Source: "README.txt"; DestDir:', 'Source: "INSTALL.txt"; DestDir:')
begin, rest = template.split('[Icons]\n', 1)
_, code = rest.split('[Code]\n', 1)
icons = []
for view, label in [('gis', 'GIS 展示'), ('process', '工艺图展示'), ('developer', 'MQTT 开发配置')]:
    for location in ['{userprograms}\\Universal HMI 测试版', '{userdesktop}']:
        icons.append('Name: "' + location + '\\Universal HMI - ' + label + '"; Filename: "{sys}\\WindowsPowerShell\\v1.0\\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\\versions\\{#PayloadId}\\Start-Trial.ps1"" -View ' + view + '"; WorkingDir: "{app}\\versions\\{#PayloadId}"; IconFilename: "{app}\\versions\\{#PayloadId}\\universal_hmi.exe"')
icons.append('Name: "{userprograms}\\Universal HMI 测试版\\卸载 Universal HMI 测试版"; Filename: "{uninstallexe}"')
template = begin + '[Icons]\n' + '\n'.join(icons) + '\n\n[Code]\n' + code
recipe = WORK / 'windows-trial.iss'
recipe.write_text(template, encoding='utf-8-sig')
(WORK / 'INSTALL.txt').write_text('''Universal HMI MQTT + GIS + Process Trial - 2026-10-26 v3

Windows 10 version 1809 or later, x64. Installs for the current user.
Includes the verified v3 desktop app, Go backend, offline GIS and Web resources.
Creates desktop / Start menu shortcuts for GIS, Process and MQTT configuration.
Use one entry at a time. Port 18080 is preferred; if another program occupies it,
the desktop backend selects a free port and the client / GIS follow automatically.

Microsoft Edge WebView2 Runtime must already be installed. As requested, this
installer does not bundle, download or install WebView2. If another PC needs it,
install the Microsoft Evergreen WebView2 Runtime separately:
https://developer.microsoft.com/microsoft-edge/webview2/

The first launch seeds an unbound example project in:
%LOCALAPPDATA%\\universal-hmi-mqtt-gis-trial-20261026-v2
Existing data is preserved. Uninstall removes program files and shortcuts only.
Example stations and instruments are not live measurements. Configure MQTT and
bind your points from the MQTT developer shortcut; read the bundled README.txt.

This is an unsigned internal trial build. No application starts during setup.
No production connections or device writes are configured by the installer.
''', encoding='utf-8')
compiler = ROOT / '.local/toolchains/inno-setup-6.7.3/ISCC.exe'
subprocess.run([str(compiler), '/Qp', f'/DBundleDir={bundle}', f'/DOutputDir={output}',
                '/DProductVersion=0.1.0.2', '/DProductFileVersion=0.1.0.2',
                f'/DPayloadId={manifest["source_sha256"][:24]}', str(recipe)], check=True)
verify_bundle(bundle, 'windows')
setup = output / 'Universal-HMI-MQTT-GIS-20261026-v3-Setup.exe'
evidence = {'schema': 1, 'installer': str(setup), 'size_bytes': setup.stat().st_size,
            'sha256': sha256(setup), 'payload_source_sha256': manifest['source_sha256'],
            'payload_git_revision': manifest['git_revision'], 'payload_files': len(manifest['artifacts']) + 1,
            'bundle_manifest_sha256': sha256(bundle / 'build-manifest.json'),
            'recipe_sha256': sha256(recipe), 'compiler_sha256': sha256(compiler),
            'signed': False, 'webview2': 'external prerequisite; not bundled or installed'}
(output / 'Universal-HMI-MQTT-GIS-20261026-v3-Setup.manifest.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
(output / 'Universal-HMI-MQTT-GIS-20261026-v3-Setup.sha256.txt').write_text(evidence['sha256'] + '  ' + setup.name + '\n', encoding='utf-8')
print(json.dumps(evidence), flush=True)

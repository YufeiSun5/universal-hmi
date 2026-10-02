"""Install release artifacts into isolated locations and exercise bundled Web.

These are automated native-runner checks, not a claim of manual OS/DPI testing.
No production data, credentials, network bindings or firewall changes are used.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from common import ROOT


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True)


def get(path):
    with urllib.request.urlopen('http://127.0.0.1:18080' + path, timeout=2) as response:
        return response.status, response.read()


def verify_web(binary, web, data):
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1', 18080)) != 0, 'Refusing to reuse or replace occupied fixture port 18080'
    process = subprocess.Popen([str(binary), '--data-dir', str(data), '--web-dir', str(web)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise AssertionError(f'Installed backend exited: {process.communicate()[1].decode(errors="replace")}')
            try:
                status, body = get('/health')
                assert status == 200 and json.loads(body)['service'] == 'universal-hmi'
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.2)
        assert get('/')[1] == (web / 'index.html').read_bytes()
        for name in ('flutter_bootstrap.js', 'main.dart.js'):
            assert get('/' + name)[1] == (web / name).read_bytes()
        assert get('/api/v1/runtime')[0] == 200
        # A same-host process must still reject hostile DNS/Host requests.
        request = urllib.request.Request('http://127.0.0.1:18080/health', headers={'Host': 'untrusted.example'})
        try:
            urllib.request.urlopen(request, timeout=2)
            raise AssertionError('Host restriction missing')
        except urllib.error.HTTPError as error:
            assert error.code == 403
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise AssertionError('Installed backend did not exit within ten seconds')


def verify_desktop_startup(binary, web, temporary):
    """Prove the installed desktop starts its sidecar; forced fixture cleanup.

Normal-close lifecycle is a separate native test, never inferred here.
"""
    environment = dict(os.environ)
    home = temporary / 'desktop-home'
    home.mkdir()
    environment.update(HOME=str(home), XDG_DATA_HOME=str(home / 'data'),
                       LOCALAPPDATA=str(home / 'AppData/Local'), APPDATA=str(home / 'AppData/Roaming'))
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1', 18080)) != 0, 'Fixture port occupied'
    process = subprocess.Popen([str(binary)], env=environment,
                               start_new_session=os.name != 'nt',
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 30
        while True:
            assert process.poll() is None, 'Installed desktop exited before sidecar readiness'
            try:
                assert json.loads(get('/health')[1])['service'] == 'universal-hmi'
                assert get('/main.dart.js')[1] == (web / 'main.dart.js').read_bytes()
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.2)
    finally:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True)
        else:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            if os.name != 'nt':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
        deadline = time.monotonic() + 10
        while True:
            with socket.socket() as probe:
                if probe.connect_ex(('127.0.0.1', 18080)) != 0:
                    break
            if time.monotonic() >= deadline:
                raise AssertionError('Owned fixture backend was not cleaned up')
            time.sleep(.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=('linux', 'windows', 'macos'))
    parser.add_argument('--skip-desktop', action='store_true', help='Headless install/backend checks only; no claim of GUI startup')
    args = parser.parse_args()
    evidence = ROOT / 'dist/installer-evidence'
    evidence.mkdir(parents=True, exist_ok=True)
    installers = ROOT / 'dist/installers'
    with tempfile.TemporaryDirectory(prefix='hmi-installed-') as temporary:
        temp = Path(temporary)
        data = temp / 'user-data'
        data.mkdir()
        sentinel = data / 'retained-user-file.txt'
        sentinel.write_text('user data must survive application replacement and removal')
        prefix = temp / 'installed'
        if args.target == 'linux':
            installer = installers / 'universal-hmi-linux-x64.install.pyz'
            run(sys.executable, installer, '--prefix', prefix)
            # Also inspect the actual Debian installable layout on its target OS.
            run('dpkg-deb', '--info', installers / 'universal-hmi-linux-x64.deb')
            run('dpkg-deb', '--extract', installers / 'universal-hmi-linux-x64.deb', temp / 'deb-extracted')
            candidates = list(prefix.rglob('universal-hmi-server'))
            assert len(candidates) == 1, candidates
            binary = candidates[0]
            web = binary.parent / 'web'
        elif args.target == 'windows':
            installer = installers / 'universal-hmi-windows-x64-setup.exe'
            run(installer, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', f'/DIR={prefix}', f'/LOG={evidence / "install.log"}')
            candidates = list((prefix / 'versions').rglob('universal-hmi-server.exe'))
            assert len(candidates) == 1, candidates
            binary, web = candidates[0], candidates[0].parent / 'web'
        else:
            image = installers / 'universal-hmi-macos-universal.dmg'
            mount = temp / 'mounted'
            run('hdiutil', 'attach', image, '-readonly', '-nobrowse', '-mountpoint', mount)
            try:
                shutil.copytree(mount / 'Universal HMI.app', prefix / 'Universal HMI.app', symlinks=True)
            finally:
                run('hdiutil', 'detach', mount)
            app = prefix / 'Universal HMI.app'
            binary, web = app / 'Contents/MacOS/universal-hmi-server', app / 'Contents/Resources/web'
            run('lipo', '-verify_arch', 'arm64', 'x86_64', binary)
        assert binary.is_file() and (web / 'main.dart.js').is_file()
        verify_web(binary, web, data)
        desktop = binary.parent / ('universal_hmi.exe' if args.target == 'windows' else 'universal_hmi')
        if not args.skip_desktop:
            verify_desktop_startup(desktop, web, temp)
        if args.target == 'linux':
            run(sys.executable, installer, '--prefix', prefix)
            verify_web(binary, web, data)
            run(prefix / 'uninstall-universal-hmi')
        elif args.target == 'windows':
            run(installer, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', f'/DIR={prefix}')
            verify_web(binary, web, data)
            uninstall = list(prefix.glob('unins*.exe'))
            assert len(uninstall) == 1
            run(uninstall[0], '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
            deadline = time.monotonic() + 15
            while binary.exists() and time.monotonic() < deadline:
                time.sleep(.1)
        else:
            # macOS drag-and-drop update/removal is owned solely by this fixture.
            replacement = temp / 'replacement.app'
            shutil.copytree(app, replacement, symlinks=True)
            shutil.rmtree(app)
            replacement.rename(app)
            verify_web(binary, web, data)
            shutil.rmtree(app)
        assert sentinel.read_text().startswith('user data must survive')
        assert not binary.exists(), 'Uninstallation left the application executable'
        result = {'target': args.target, 'installed_backend_and_web': 'passed', 'installed_desktop_sidecar_startup': 'skipped' if args.skip_desktop else 'passed', 'desktop_cleanup': 'not launched' if args.skip_desktop else 'forced fixture process-tree cleanup, not normal-close evidence', 'update_and_uninstall': 'passed', 'external_user_data_preserved': True, 'native_manual_ui_test': 'not performed by this script'}
        (evidence / f'{args.target}-installation.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()

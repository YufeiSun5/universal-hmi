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
from build_installers import verify_bundle
from build_release import sha256

SYSTEM_DEB_ROOT = Path('/')
SYSTEM_DEB_PATHS = (
    Path("/opt/universal-hmi"), Path("/usr/bin/universal-hmi"),
    Path("/usr/share/applications/universal-hmi.desktop"),
    Path("/usr/share/icons/hicolor/scalable/apps/universal-hmi.svg"),
    Path("/usr/share/doc/universal-hmi"),
)


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



def require_system_deb(condition, message):
    if not condition:
        raise ValueError(message)


def check_system_deb_environment(target, environment=None):
    environment = os.environ if environment is None else environment
    require_system_deb(target == 'linux' and sys.platform == 'linux',
                       '--system-deb is supported only for Linux')
    require_system_deb(environment.get('GITHUB_ACTIONS') == 'true'
                       and environment.get('RUNNER_ENVIRONMENT') == 'github-hosted'
                       and environment.get('RUNNER_OS') == 'Linux',
                       '--system-deb requires an explicit GitHub-hosted Linux CI job; local/system installs are refused')


def inspect_deb_tree(root, manifest, expected_manifest_hash):
    """Reject unexpected package paths or integration bytes before sudo."""
    payload = root / 'opt/universal-hmi'
    verify_bundle(payload, 'linux', manifest['git_revision'])
    require_system_deb(sha256(payload / 'build-manifest.json') == expected_manifest_hash,
                       'Debian payload manifest differs from verified bundle')
    integrations = {
        'usr/share/applications/universal-hmi.desktop': ROOT / 'packaging/universal-hmi.desktop',
        'usr/share/icons/hicolor/scalable/apps/universal-hmi.svg': ROOT / 'packaging/universal-hmi.svg',
        'usr/share/doc/universal-hmi/README.txt': ROOT / 'packaging/README.txt',
    }
    expected = {'opt/universal-hmi/' + name for name in manifest['artifacts']}
    expected |= {'opt/universal-hmi/build-manifest.json', 'usr/bin/universal-hmi'} | set(integrations)
    actual = set()
    for path in root.rglob('*'):
        require_system_deb(not path.is_symlink(), 'Debian package contains an unexpected symlink')
        if not path.is_dir():
            require_system_deb(path.is_file(), 'Debian package contains a special file')
            actual.add(path.relative_to(root).as_posix())
    require_system_deb(actual == expected, 'Debian package contains unexpected or missing installation paths')
    for relative, source in integrations.items():
        require_system_deb((root / relative).read_bytes() == source.read_bytes(),
                           f'Debian integration file differs: {relative}')
    require_system_deb((root / 'usr/bin/universal-hmi').read_bytes()
                       == b'#!/bin/sh\nexec /opt/universal-hmi/universal_hmi "$@"\n',
                       'Debian launcher differs from the verified wrapper')
    return integrations


def verify_system_deb(installer, temporary, evidence, *, skip_desktop=False):
    """Real dpkg lifecycle, exclusively on an explicitly opted-in hosted runner.

    The second installation uses the same version to verify reinstall semantics;
    it is deliberately not described as a cross-version data migration test.
    """
    check_system_deb_environment('linux')
    temporary.mkdir()
    record_path = evidence / 'linux-system-deb.json'
    log_path = evidence / 'linux-system-deb.log'
    result = {'target': 'linux', 'package_manager': 'dpkg', 'first_install': 'not run',
              'same_version_reinstall': 'not run', 'cross_version_migration': 'not tested',
              'installed_backend_and_web': 'not run', 'system_launcher_sidecar_startup': 'not run',
              'remove': 'not run', 'synthetic_user_data_preserved': False,
              'desktop_cleanup': 'forced fixture process-tree cleanup; not normal-close evidence'}

    def save():
        record_path.write_text(json.dumps(result, indent=2) + '\n')

    def command(*arguments, check=True):
        arguments = [str(argument) for argument in arguments]
        completed = subprocess.run(arguments, check=False, capture_output=True, text=True,
                                   env={**os.environ, 'LC_ALL': 'C'})
        with log_path.open('a', encoding='utf-8') as log:
            log.write('$ ' + ' '.join(arguments) + '\n' + completed.stdout + completed.stderr
                      + f'\nexit={completed.returncode}\n')
        if check and completed.returncode:
            raise subprocess.CalledProcessError(completed.returncode, arguments,
                                                output=completed.stdout, stderr=completed.stderr)
        return completed

    def package_status():
        query = command('dpkg-query', '--show', '--showformat=${db:Status-Status}\t${Version}\t${Architecture}\n',
                        'universal-hmi', check=False)
        if query.returncode == 1 and not query.stdout.strip() and 'no packages found matching universal-hmi' in query.stderr:
            return None
        require_system_deb(query.returncode == 0, 'Cannot establish existing dpkg package state')
        fields = query.stdout.strip('\n').split('\t')
        require_system_deb(len(fields) == 3, 'Unexpected dpkg status format')
        return {'status': fields[0], 'version': fields[1], 'architecture': fields[2]}

    # Establish ownership before invoking privileged commands. No pre-existing
    # package (including a removed/config-files record) may be replaced.
    require_system_deb(package_status() is None, 'Refusing to replace an existing universal-hmi dpkg record')
    for path in SYSTEM_DEB_PATHS:
        require_system_deb(not os.path.lexists(path), f'Refusing to replace existing system path: {path}')
    bundle = ROOT / 'dist/linux'
    manifest = verify_bundle(bundle, 'linux')
    bundle_hash = sha256(bundle / 'build-manifest.json')
    installer_record = json.loads((installer.parent / 'installer-manifest-linux.json').read_text())
    require_system_deb(installer_record.get('bundle_manifest_sha256') == bundle_hash
                       and installer_record.get('artifacts', {}).get(installer.name) == sha256(installer),
                       'Debian installer provenance or checksum differs')
    fields = command('dpkg-deb', '--field', installer, 'Package', 'Version', 'Architecture').stdout
    metadata = dict(line.split(': ', 1) for line in fields.splitlines() if ': ' in line)
    require_system_deb(metadata.get('Package') == 'universal-hmi' and metadata.get('Architecture') == 'amd64'
                       and metadata.get('Version') == installer_record.get('version'),
                       'Unexpected Debian package identity, architecture or version')
    expected_version = metadata['Version']
    extracted, control = temporary / 'extracted', temporary / 'control'
    command('dpkg-deb', '--extract', installer, extracted)
    command('dpkg-deb', '--control', installer, control)
    require_system_deb({path.name for path in control.iterdir()} == {'control'}
                       and (control / 'control').is_file() and not (control / 'control').is_symlink(),
                       'Unexpected Debian maintainer scripts or control files')
    integrations = inspect_deb_tree(extracted, manifest, bundle_hash)
    data = temporary / 'synthetic-data/universal-hmi'
    data.mkdir(parents=True)
    sentinel = data / 'retained-user-file.txt'
    sentinel.write_text('synthetic user data must survive dpkg reinstall and remove')
    before_data = sentinel.read_bytes()
    binary, web = SYSTEM_DEB_ROOT / 'opt/universal-hmi/universal-hmi-server', SYSTEM_DEB_ROOT / 'opt/universal-hmi/web'
    launcher = SYSTEM_DEB_ROOT / 'usr/bin/universal-hmi'
    attempted = False
    main_error = None

    def verify_installed():
        require_system_deb(package_status() == {'status': 'installed', 'version': expected_version, 'architecture': 'amd64'},
                           'dpkg did not configure the expected package')
        installed = SYSTEM_DEB_ROOT / 'opt/universal-hmi'
        verify_bundle(installed, 'linux', manifest['git_revision'])
        require_system_deb(sha256(installed / 'build-manifest.json') == bundle_hash,
                           'System-installed manifest differs')
        require_system_deb(launcher.read_bytes() == (extracted / 'usr/bin/universal-hmi').read_bytes()
                           and os.access(launcher, os.X_OK), 'System launcher differs or is not executable')
        for relative in integrations:
            require_system_deb((SYSTEM_DEB_ROOT / relative).read_bytes() == (extracted / relative).read_bytes(),
                               f'System integration file differs: {relative}')
        verify_web(binary, web, data)
        require_system_deb(sentinel.read_bytes() == before_data, 'Synthetic user data changed during install')

    try:
        attempted = True
        command('sudo', '-n', 'dpkg', '--install', installer)
        verify_installed()
        result['first_install'] = 'passed'
        result['installed_backend_and_web'] = 'passed'
        save()
        if not skip_desktop:
            # Separate HOME/XDG data from the rootless test and from runner data.
            verify_desktop_startup(launcher, web, temporary)
            result['system_launcher_sidecar_startup'] = 'passed'
        else:
            result['system_launcher_sidecar_startup'] = 'skipped'
        command('sudo', '-n', 'dpkg', '--install', installer)
        verify_installed()
        result['same_version_reinstall'] = 'passed'
        save()
    except BaseException as error:
        main_error = error
        result['error'] = str(error)
        raise
    finally:
        if attempted:
            try:
                status = package_status()
                if status is not None and status['status'] != 'not-installed':
                    require_system_deb(status['version'] == expected_version and status['architecture'] == 'amd64',
                                       'Package identity changed; refusing cleanup of an unowned package')
                    command('sudo', '-n', 'dpkg', '--remove', 'universal-hmi')
                status = package_status()
                require_system_deb(status is None or status['status'] in ('not-installed', 'config-files'),
                                   'dpkg still reports the fixture package installed')
                for path in SYSTEM_DEB_PATHS:
                    require_system_deb(not os.path.lexists(path), f'Package removal left installed path: {path}')
                require_system_deb(sentinel.read_bytes() == before_data, 'Synthetic user data was removed or changed')
                result['remove'] = 'passed'
                result['synthetic_user_data_preserved'] = True
            except BaseException as cleanup_error:
                result['remove'] = 'failed'
                result['cleanup_error'] = str(cleanup_error)
                if main_error is None:
                    raise
            finally:
                save()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=('linux', 'windows', 'macos'))
    parser.add_argument('--system-deb', action='store_true', help='Also test privileged dpkg lifecycle; only explicit GitHub-hosted Linux CI is allowed')
    parser.add_argument('--skip-desktop', action='store_true', help='Headless install/backend checks only; no claim of GUI startup')
    args = parser.parse_args()
    if args.system_deb:
        check_system_deb_environment(args.target)
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
            run('lipo', binary, '-verify_arch', 'arm64', 'x86_64')
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
        if args.system_deb:
            result['system_deb'] = verify_system_deb(installers / 'universal-hmi-linux-x64.deb',
                                                    temp / 'system-deb', evidence, skip_desktop=args.skip_desktop)
        (evidence / f'{args.target}-installation.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()

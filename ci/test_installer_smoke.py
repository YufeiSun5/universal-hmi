"""CI-only Debian lifecycle contract, using mocked dpkg and private temp files.

These tests never run sudo, install a system package, or launch an application.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import installer_smoke as smoke
from build_release import sha256
from common import ROOT
from test_installers import fixture

CI_ENVIRONMENT = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'Linux'}


class SystemDebEnvironment(unittest.TestCase):
    def test_only_explicit_hosted_linux_allowed(self):
        with patch.object(smoke.sys, 'platform', 'linux'):
            smoke.check_system_deb_environment('linux', CI_ENVIRONMENT)
            for environment in ({}, {**CI_ENVIRONMENT, 'GITHUB_ACTIONS': 'false'},
                                {**CI_ENVIRONMENT, 'RUNNER_ENVIRONMENT': 'self-hosted'},
                                {**CI_ENVIRONMENT, 'RUNNER_OS': 'Windows'}):
                with self.subTest(environment=environment), self.assertRaises(ValueError):
                    smoke.check_system_deb_environment('linux', environment)
            with self.assertRaises(ValueError):
                smoke.check_system_deb_environment('macos', CI_ENVIRONMENT)
        with patch.object(smoke.sys, 'platform', 'darwin'), self.assertRaises(ValueError):
            smoke.check_system_deb_environment('linux', CI_ENVIRONMENT)

    def test_cli_flag_is_absent_by_default(self):
        source = (ROOT / 'ci/installer_smoke.py').read_text()
        self.assertIn("parser.add_argument('--system-deb', action='store_true'", source)
        self.assertIn('if args.system_deb:', source)
        self.assertIn("run('lipo', binary, '-verify_arch', 'arm64', 'x86_64')", source)


class SystemDebLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.bundle = self.repo / 'dist/linux'
        fixture(self.bundle)
        (self.repo / 'packaging').mkdir(parents=True)
        for name in ('README.txt', 'universal-hmi.desktop', 'universal-hmi.svg'):
            shutil.copy2(ROOT / 'packaging' / name, self.repo / 'packaging' / name)
        self.output = self.repo / 'dist/installers'
        self.output.mkdir()
        self.installer = self.output / 'universal-hmi-linux-x64.deb'
        self.installer.write_bytes(b'mocked deb; never passed to real dpkg')
        self.record = {'bundle_manifest_sha256': sha256(self.bundle / 'build-manifest.json'),
                       'version': '0.1.0+2', 'artifacts': {self.installer.name: sha256(self.installer)}}
        (self.output / 'installer-manifest-linux.json').write_text(json.dumps(self.record))
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir()
        self.workspace = self.root / 'work'
        self.system = self.root / 'mock-system'
        self.system.mkdir()
        self.paths = tuple(self.system / path.relative_to('/') for path in smoke.SYSTEM_DEB_PATHS)
        self.status = None
        self.commands = []
        self.install_count = 0
        self.fail_install = False
        self.fail_remove = False
        self.extra_control = False
        self.extra_payload = False
        self.tampered_readme = False
        self.wrong_package = False
        self.query_error = False
        self.patches = [patch.object(smoke, 'ROOT', self.repo), patch.object(smoke, 'SYSTEM_DEB_ROOT', self.system),
                        patch.object(smoke, 'SYSTEM_DEB_PATHS', self.paths),
                        patch.object(smoke.sys, 'platform', 'linux'),
                        patch.dict(os.environ, CI_ENVIRONMENT),
                        patch.object(smoke.subprocess, 'run', side_effect=self.fake_command),
                        patch.object(smoke, 'verify_web'), patch.object(smoke, 'verify_desktop_startup')]
        self.mocks = [item.start() for item in self.patches]
        for item in self.patches:
            self.addCleanup(item.stop)

    def package_tree(self, destination):
        shutil.copytree(self.bundle, destination / 'opt/universal-hmi')
        for relative, source in {
            'usr/share/doc/universal-hmi/README.txt': 'README.txt',
            'usr/share/applications/universal-hmi.desktop': 'universal-hmi.desktop',
            'usr/share/icons/hicolor/scalable/apps/universal-hmi.svg': 'universal-hmi.svg',
        }.items():
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.repo / 'packaging' / source, path)
        launcher = destination / 'usr/bin/universal-hmi'
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_bytes(b'#!/bin/sh\nexec /opt/universal-hmi/universal_hmi "$@"\n')
        launcher.chmod(0o755)
        if self.extra_payload:
            (destination / 'unexpected-file').write_text('refuse this path')
        if self.tampered_readme:
            (destination / 'usr/share/doc/universal-hmi/README.txt').write_text('modified README')

    def fake_command(self, arguments, **kwargs):
        self.commands.append(arguments)
        self.assertFalse(kwargs['check'])
        self.assertEqual(kwargs['env']['LC_ALL'], 'C')
        out, err, code = '', '', 0
        if arguments[0] == 'dpkg-query':
            if self.query_error:
                code, err = 2, 'dpkg database unavailable'
            elif self.status is None:
                code, err = 1, 'dpkg-query: no packages found matching universal-hmi\n'
            else:
                out = '\t'.join(self.status[key] for key in ('status', 'version', 'architecture')) + '\n'
        elif arguments[:2] == ['dpkg-deb', '--field']:
            out = 'Package: ' + ('other-package' if self.wrong_package else 'universal-hmi') + '\nVersion: 0.1.0+2\nArchitecture: amd64\n'
        elif arguments[:2] == ['dpkg-deb', '--extract']:
            self.package_tree(Path(arguments[-1]))
        elif arguments[:2] == ['dpkg-deb', '--control']:
            control = Path(arguments[-1])
            control.mkdir()
            (control / 'control').write_text('mock control')
            if self.extra_control:
                (control / 'postinst').write_text('not allowed')
        elif arguments[:4] == ['sudo', '-n', 'dpkg', '--install']:
            self.install_count += 1
            self.status = {'status': 'installed', 'version': '0.1.0+2', 'architecture': 'amd64'}
            shutil.copytree(self.workspace / 'extracted', self.system, dirs_exist_ok=True)
            if self.fail_install:
                self.status['status'] = 'unpacked'
                code, err = 1, 'injected configuration failure'
        elif arguments == ['sudo', '-n', 'dpkg', '--remove', 'universal-hmi']:
            if self.fail_remove:
                code, err = 1, 'injected removal failure'
            else:
                for path in self.paths:
                    if path.is_dir():
                        shutil.rmtree(path)
                    elif path.exists():
                        path.unlink()
                self.status = None
        else:
            self.fail(f'Unexpected command: {arguments}')
        return subprocess.CompletedProcess(arguments, code, out, err)

    def invoke(self, skip_desktop=False):
        return smoke.verify_system_deb(self.installer, self.workspace, self.evidence, skip_desktop=skip_desktop)

    def no_privileged_commands(self):
        self.assertFalse(any(command[0] == 'sudo' for command in self.commands), self.commands)

    def test_install_same_version_reinstall_launcher_and_remove(self):
        result = self.invoke()
        self.assertEqual(self.install_count, 2)
        self.assertEqual(result['first_install'], 'passed')
        self.assertEqual(result['same_version_reinstall'], 'passed')
        self.assertEqual(result['cross_version_migration'], 'not tested')
        self.assertEqual(result['remove'], 'passed')
        self.assertTrue(result['synthetic_user_data_preserved'])
        smoke.verify_web.assert_called()
        self.assertEqual(smoke.verify_web.call_count, 2)
        smoke.verify_desktop_startup.assert_called_once_with(self.system / 'usr/bin/universal-hmi',
                                                           self.system / 'opt/universal-hmi/web', self.workspace)
        self.assertIsNone(self.status)
        self.assertEqual(json.loads((self.evidence / 'linux-system-deb.json').read_text()), result)
        self.assertTrue((self.workspace / 'synthetic-data/universal-hmi/retained-user-file.txt').exists())

    def test_no_desktop_when_explicitly_skipped(self):
        result = self.invoke(skip_desktop=True)
        self.assertEqual(result['system_launcher_sidecar_startup'], 'skipped')
        smoke.verify_desktop_startup.assert_not_called()

    def test_environment_guard_prevents_all_commands(self):
        with patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'self-hosted'}), self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.commands, [])

    def test_existing_package_never_replaced_or_removed(self):
        self.status = {'status': 'config-files', 'version': 'old', 'architecture': 'amd64'}
        with self.assertRaisesRegex(ValueError, 'existing universal-hmi dpkg record'):
            self.invoke()
        self.no_privileged_commands()
        self.assertEqual(self.status['version'], 'old')

    def test_existing_unknown_system_path_never_touched(self):
        path = self.paths[0]
        path.mkdir(parents=True)
        (path / 'keep.txt').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'existing system path'):
            self.invoke()
        self.no_privileged_commands()
        self.assertEqual((path / 'keep.txt').read_text(), 'keep')

    def test_unknown_dpkg_database_state_refused(self):
        self.query_error = True
        with self.assertRaisesRegex(ValueError, 'Cannot establish'):
            self.invoke()
        self.no_privileged_commands()

    def test_bad_installer_checksum_refused_before_sudo(self):
        self.installer.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum differs'):
            self.invoke()
        self.no_privileged_commands()

    def test_unrelated_package_metadata_refused(self):
        self.wrong_package = True
        with self.assertRaisesRegex(ValueError, 'package identity'):
            self.invoke()
        self.no_privileged_commands()

    def test_maintainer_scripts_refused(self):
        self.extra_control = True
        with self.assertRaisesRegex(ValueError, 'maintainer scripts'):
            self.invoke()
        self.no_privileged_commands()

    def test_unexpected_package_path_refused(self):
        self.extra_payload = True
        with self.assertRaisesRegex(ValueError, 'installation paths'):
            self.invoke()
        self.no_privileged_commands()

    def test_tampered_readme_refused(self):
        self.tampered_readme = True
        with self.assertRaisesRegex(ValueError, 'integration file differs'):
            self.invoke()
        self.no_privileged_commands()

    def test_partial_failed_install_is_removed_only_after_identity_check(self):
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertIn(['sudo', '-n', 'dpkg', '--remove', 'universal-hmi'], self.commands)
        self.assertIsNone(self.status)
        result = json.loads((self.evidence / 'linux-system-deb.json').read_text())
        self.assertEqual(result['remove'], 'passed')
        self.assertEqual(result['first_install'], 'not run')

    def test_web_failure_cleans_owned_package_and_preserves_original_error(self):
        smoke.verify_web.side_effect = AssertionError('injected Web failure')
        with self.assertRaisesRegex(AssertionError, 'injected Web failure'):
            self.invoke()
        self.assertIsNone(self.status)
        self.assertEqual(self.install_count, 1)

    def test_cleanup_never_removes_package_that_changed_identity(self):
        def changed_owner(*args):
            self.status['version'] = 'different-owner-version'
            raise AssertionError('original failure')
        smoke.verify_web.side_effect = changed_owner
        with self.assertRaisesRegex(AssertionError, 'original failure'):
            self.invoke()
        self.assertFalse(any(command[:4] == ['sudo', '-n', 'dpkg', '--remove'] for command in self.commands))
        result = json.loads((self.evidence / 'linux-system-deb.json').read_text())
        self.assertIn('unowned package', result['cleanup_error'])
        self.assertEqual(result['remove'], 'failed')

    def test_cleanup_failure_records_both_errors_and_keeps_original_exception(self):
        smoke.verify_web.side_effect = AssertionError('original Web failure')
        self.fail_remove = True
        with self.assertRaisesRegex(AssertionError, 'original Web failure'):
            self.invoke()
        result = json.loads((self.evidence / 'linux-system-deb.json').read_text())
        self.assertEqual(result['error'], 'original Web failure')
        self.assertEqual(result['remove'], 'failed')
        self.assertIn('cleanup_error', result)

    def test_remove_failure_fails_an_otherwise_successful_test(self):
        self.fail_remove = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        result = json.loads((self.evidence / 'linux-system-deb.json').read_text())
        self.assertEqual(result['same_version_reinstall'], 'passed')
        self.assertEqual(result['remove'], 'failed')


if __name__ == '__main__':
    unittest.main(verbosity=2)

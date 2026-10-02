"""Platform-neutral faults for macOS packaging; fixtures are not real builds."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import build_release
import package_desktop
import package_final


def thin(cpu, extra=b'fixture'):
    return struct.pack('<IIIIIIII', 0xfeedfacf, cpu, 0, 6, 0, 0, 0, 0) + extra


def universal(order=(0x0100000c, 0x01000007), extra=b'fixture'):
    slices = [thin(cpu, extra) for cpu in order]
    offset = 8 + len(order) * 20
    result = struct.pack('>II', 0xcafebabe, len(order))
    for cpu, blob in zip(order, slices):
        result += struct.pack('>IIIII', cpu, 0, offset, len(blob), 0)
        offset += len(blob)
    return result + b''.join(slices)


class MacOSPackaging(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hmi-macos-packaging-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / build_release.BUILD_PATHS['macos']
        self.bundle.mkdir(parents=True)
        self.sdk = self.root / 'sdk'
        self.runner = self.put('Contents/MacOS/universal_hmi', universal())
        self.runner.chmod(0o755)
        self.engine = self.put('Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS', universal())
        self.aot = self.put('Contents/Frameworks/App.framework/Versions/A/App', universal(extra=b'AOT-fixture'))
        self.put('Contents/Info.plist', plistlib.dumps({'CFBundleExecutable': 'universal_hmi', 'CFBundlePackageType': 'APPL'}))
        framework = self.bundle / 'Contents/Frameworks/FlutterMacOS.framework'
        (framework / 'Versions/Current').symlink_to('A', target_is_directory=True)
        (framework / 'FlutterMacOS').symlink_to('Versions/Current/FlutterMacOS')
        self.official = self.sdk / 'bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/Versions/A/FlutterMacOS'
        self.official.parent.mkdir(parents=True)
        self.official.write_bytes(universal(order=(0x01000007, 0x0100000c)))

    def put(self, relative, content):
        path = self.bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def manifest(self, folder=None, target='macos', source='same-source'):
        folder = folder or self.bundle
        manifest = {'schema': 1, 'mode': 'release', 'target': target, 'git_revision': 'same-revision',
                    'source_sha256': source, 'source_files': {'app/lib/main.dart': source},
                    **build_release.artifact_inventory(folder, allow_symlinks=target == 'macos')}
        (folder / 'build-manifest.json').write_text(json.dumps(manifest))
        return manifest

    def web(self):
        web = self.root / build_release.BUILD_PATHS['web']
        web.mkdir(parents=True)
        (web / 'index.html').write_text('current Web fixture')
        self.manifest(web, target='web')
        return web

    def test_universal_engine_slice_identity_survives_fat_order(self):
        result = build_release.verify_macos(self.bundle, self.sdk)
        self.assertNotEqual(result['bundled_engine_sha256'], result['official_engine_sha256'])
        self.assertEqual(result['architectures'], ['arm64', 'x86_64'])
        self.assertEqual(result['engine_slice_sha256'], build_release.macho_slices(self.official))

    def test_missing_architecture_and_wrong_engine_fail(self):
        self.runner.write_bytes(thin(0x0100000c))
        with self.assertRaisesRegex(AssertionError, 'arm64 and x86_64'):
            build_release.verify_macos(self.bundle, self.sdk)
        self.runner.write_bytes(universal())
        self.engine.write_bytes(universal(extra=b'wrong-debug-engine'))
        with self.assertRaisesRegex(AssertionError, 'official darwin-x64-release'):
            build_release.verify_macos(self.bundle, self.sdk)

    def test_thin_plugin_and_debug_snapshot_fail(self):
        plugin = self.put('Contents/Frameworks/plugin.framework/Versions/A/plugin', thin(0x01000007))
        with self.assertRaisesRegex(AssertionError, 'arm64 and x86_64'):
            build_release.verify_macos(self.bundle, self.sdk)
        plugin.write_bytes(universal())
        self.put('Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin', b'debug')
        with self.assertRaisesRegex(AssertionError, 'debug snapshots'):
            build_release.verify_macos(self.bundle, self.sdk)

    def test_non_macho_and_corrupt_fat_bounds_fail(self):
        self.runner.write_bytes(b'not-a-Mach-O')
        with self.assertRaisesRegex(AssertionError, 'Not a Mach-O'):
            build_release.require_universal_macos(self.runner)
        broken = bytearray(universal())
        struct.pack_into('>I', broken, 16, 999999)
        self.runner.write_bytes(broken)
        with self.assertRaisesRegex(AssertionError, 'slice bounds'):
            build_release.require_universal_macos(self.runner)

    def test_safe_framework_links_are_explicit_and_aliases_not_hashed_twice(self):
        manifest = self.manifest()
        link = 'Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS'
        self.assertEqual(manifest['symlinks'][link], 'Versions/Current/FlutterMacOS')
        self.assertNotIn(link, manifest['artifacts'])
        self.assertNotIn('Contents/Frameworks/FlutterMacOS.framework/Versions/Current/FlutterMacOS', manifest['artifacts'])
        package_final.verify_artifacts(self.bundle, manifest, 'fixture')
        (self.bundle / link).unlink()
        (self.bundle / link).symlink_to('Versions/A/FlutterMacOS')
        with self.assertRaisesRegex(AssertionError, 'symlinks changed'):
            package_final.verify_artifacts(self.bundle, manifest, 'fixture')

    def test_outside_broken_cyclic_and_absolute_links_fail(self):
        outside = self.root / 'private'
        outside.write_bytes(b'must not be read')
        for target, pattern in [(str(outside), 'Invalid symlink target'), (os.path.relpath(outside, self.bundle), 'Symlink escapes'),
                                ('missing', 'Broken or cyclic'), ('.', 'Cyclic directory')]:
            with self.subTest(target=target):
                link = self.bundle / 'escape'
                link.symlink_to(target)
                try:
                    with self.assertRaisesRegex(AssertionError, pattern):
                        build_release.artifact_inventory(self.bundle, allow_symlinks=True)
                finally:
                    link.unlink()

    def test_new_links_regular_files_and_manifest_link_cannot_be_smuggled(self):
        manifest = self.manifest()
        link = self.bundle / 'extra-link'
        link.symlink_to('Contents/Info.plist')
        with self.assertRaisesRegex(AssertionError, 'symlinks changed'):
            package_final.verify_artifacts(self.bundle, manifest, 'fixture')
        link.unlink()
        self.put('unexpected-file', b'not verified')
        with self.assertRaisesRegex(AssertionError, 'unverified files'):
            package_final.verify_artifacts(self.bundle, manifest, 'fixture')
        (self.bundle / 'build-manifest.json').unlink()
        (self.bundle / 'build-manifest.json').symlink_to('Contents/Info.plist')
        with self.assertRaisesRegex(AssertionError, 'no verified release manifest'):
            package_final.load_manifest(self.bundle, 'macos', 'fixture')

    def test_backend_installed_next_to_launcher_with_universal_evidence(self):
        self.manifest()
        server = self.root / 'dist/universal-hmi-server'
        server.parent.mkdir()
        server.write_bytes(universal(extra=b'backend-fixture'))
        with patch.object(package_desktop, 'ROOT', self.root), patch.object(sys, 'argv', ['package_desktop.py', 'macos']):
            package_desktop.main()
        dest = self.bundle / 'Contents/MacOS/universal-hmi-server'
        self.assertEqual(dest.read_bytes(), server.read_bytes())
        self.assertTrue(dest.stat().st_mode & 0o111)
        manifest = json.loads((self.bundle / 'build-manifest.json').read_text())
        self.assertEqual(set(manifest['backend_slice_sha256']), {'arm64', 'x86_64'})
        package_final.verify_artifacts(self.bundle, manifest, 'packaged')

    def test_tampered_desktop_rejected_before_backend_copy(self):
        self.manifest()
        self.runner.write_bytes(universal(extra=b'tampered'))
        with patch.object(package_desktop, 'ROOT', self.root), patch.object(sys, 'argv', ['package_desktop.py', 'macos']):
            with self.assertRaisesRegex(AssertionError, 'artifact changed'):
                package_desktop.main()
        self.assertFalse((self.bundle / 'Contents/MacOS/universal-hmi-server').exists())

    def test_staging_preserves_links_and_injects_same_source_web_in_resources(self):
        self.manifest()
        self.web()
        with patch.object(package_final, 'ROOT', self.root):
            package_final.main(('macos',), stage=True)
            # Assembly is repeatable against the original native build reference.
            package_final.main(('macos',))
        staged = self.root / 'dist/macos'
        self.assertTrue((staged / 'Contents/Frameworks/FlutterMacOS.framework/Versions/Current').is_symlink())
        self.assertTrue((staged / 'Contents/Resources/web/index.html').is_file())
        self.assertFalse((staged / 'web').exists())
        manifest = json.loads((staged / 'build-manifest.json').read_text())
        self.assertIn('Contents/Resources/web/build-manifest.json', manifest['artifacts'])
        package_final.verify_artifacts(staged, manifest, 'final')

    def test_stale_source_rejected_before_staging(self):
        self.manifest(source='stale-source')
        self.web()
        with patch.object(package_final, 'ROOT', self.root):
            with self.assertRaisesRegex(AssertionError, 'source hashes differ'):
                package_final.main(('macos',), stage=True)
        self.assertFalse((self.root / 'dist/macos').exists())

    def test_traversal_manifest_and_symlink_root_are_rejected(self):
        manifest = self.manifest()
        manifest['artifacts']['../private'] = 'wrong'
        with self.assertRaisesRegex(AssertionError, 'Invalid artifact path'):
            package_final.verify_artifacts(self.bundle, manifest, 'fixture')
        alias = self.root / 'alias'
        alias.symlink_to(self.bundle, target_is_directory=True)
        with self.assertRaisesRegex(AssertionError, 'Invalid bundle directory'):
            build_release.artifact_inventory(alias, allow_symlinks=True)

    def test_runner_has_no_unrendered_templates_and_xml_is_valid(self):
        runner = Path(__file__).resolve().parents[1] / 'app/macos'
        self.assertFalse((runner / 'Podfile').exists())
        project = (runner / 'Runner.xcodeproj/project.pbxproj').read_text()
        self.assertIn('XCLocalSwiftPackageReference', project)
        self.assertIn('Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage', project)
        self.assertIn('FlutterGeneratedPluginSwiftPackage in Frameworks', project)
        scheme = (runner / 'Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme').read_text()
        self.assertIn('macos_assemble.sh prepare', scheme)
        for path in runner.rglob('*'):
            if not path.is_file() or path.suffix == '.png':
                continue
            self.assertNotIn('{{', path.read_text(), str(path))
            if path.suffix in ('.plist', '.entitlements', '.xib', '.xcworkspacedata', '.xcscheme'):
                ET.parse(path)
        info = (runner / 'Runner/Configs/AppInfo.xcconfig').read_text()
        self.assertIn('EXECUTABLE_NAME = universal_hmi', info)
        self.assertIn('ARCHS = arm64 x86_64', info)
        self.assertIn('CODE_SIGNING_REQUIRED = NO', info)


if __name__ == '__main__':
    unittest.main(verbosity=2)

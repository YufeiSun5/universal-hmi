"""Installer integrity/failure tests; native OS lifecycle is installer_smoke.py."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipapp
import zipfile

import build_installers as installers
from build_release import sha256

spec = importlib.util.spec_from_file_location("linux_installer", installers.PACKAGING / "linux_user_installer.py")
user_installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(user_installer)
REVISION = "a" * 40


def write_manifest(folder, data):
    (folder / "build-manifest.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def fixture(folder, target="linux", marker="one"):
    folder.mkdir(parents=True)
    web = folder / ("Contents/Resources/web" if target == "macos" else "web")
    web.mkdir(parents=True)
    (web / "index.html").write_text("<!doctype html><title>" + marker + "</title>")
    (web / "main.dart.js").write_text("var testRelease = " + repr(marker) + ";")
    source_files = {"app/main.dart": hashlib.sha256(marker.encode()).hexdigest()}
    identity = {"schema": 1, "mode": "release", "git_revision": REVISION, "source_files": source_files,
                "source_sha256": hashlib.sha256(json.dumps(source_files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}
    web_manifest = {**identity, "target": "web", "artifacts": {
        path.name: sha256(path) for path in web.iterdir()}}
    write_manifest(web, web_manifest)
    for name in ({"linux": ("universal_hmi", "universal-hmi-server"),
                  "windows": ("universal_hmi.exe", "universal-hmi-server.exe"),
                  "macos": ("Contents/MacOS/universal_hmi", "Contents/MacOS/universal-hmi-server")}[target]):
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    manifest = {**identity, "target": target, "package_contains_web": True,
                "artifacts": {path.relative_to(folder).as_posix(): sha256(path)
                              for path in folder.rglob("*") if path.is_file()}}
    write_manifest(folder, manifest)
    return manifest


def pyz_fixture(bundle, path):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        shutil.copytree(bundle, root / "payload")
        shutil.copy2(installers.PACKAGING / "linux_user_installer.py", root / "__main__.py")
        hashes = {p.relative_to(bundle).as_posix(): sha256(p) for p in bundle.rglob("*") if p.is_file()}
        (root / "payload-hashes.json").write_text(json.dumps(hashes))
        zipapp.create_archive(root, path, interpreter="/usr/bin/env python3", compressed=True)


class BundleVerification(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.manifest = fixture(self.bundle)

    def test_accepts_only_complete_matching_release(self):
        actual = installers.verify_bundle(self.bundle, "linux", REVISION)
        self.assertEqual(actual, self.manifest)

    def test_tampered_artifact_rejected(self):
        (self.bundle / "web/index.html").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            installers.verify_bundle(self.bundle, "linux")

    def test_missing_file_rejected(self):
        (self.bundle / "universal-hmi-server").unlink()
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            installers.verify_bundle(self.bundle, "linux")

    def test_extra_file_rejected(self):
        (self.bundle / "secret.txt").write_text("not shipped")
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            installers.verify_bundle(self.bundle, "linux")

    def test_web_marker_required(self):
        self.manifest["package_contains_web"] = False
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "no assembled Web"):
            installers.verify_bundle(self.bundle, "linux")

    def test_wrong_revision_rejected(self):
        with self.assertRaisesRegex(ValueError, "expected revision"):
            installers.verify_bundle(self.bundle, "linux", "b" * 40)

    def test_unverified_web_js_rejected_even_with_updated_outer_hash(self):
        target = self.bundle / "web/main.dart.js"
        target.write_text("different release")
        self.manifest["artifacts"]["web/main.dart.js"] = sha256(target)
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "Nested Web artifact inventory differs"):
            installers.verify_bundle(self.bundle, "linux")

    def test_web_revision_mismatch_rejected(self):
        target = self.bundle / "web/build-manifest.json"
        web = json.loads(target.read_text())
        web["git_revision"] = "b" * 40
        write_manifest(target.parent, web)
        self.manifest["artifacts"]["web/build-manifest.json"] = sha256(target)
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "Web git_revision differ"):
            installers.verify_bundle(self.bundle, "linux")

    def test_source_hash_cannot_be_changed_independently(self):
        self.manifest["source_sha256"] = "b" * 64
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "Source inventory hash differs"):
            installers.verify_bundle(self.bundle, "linux")

    def test_duplicate_json_keys_rejected(self):
        path = self.bundle / "build-manifest.json"
        path.write_text(path.read_text().replace('"target": "linux"', '"target": "linux", "target": "linux"'))
        with self.assertRaisesRegex(ValueError, "Duplicate JSON key"):
            installers.verify_bundle(self.bundle, "linux")

    def test_paths_reject_traversal_drive_aliases_and_normalization(self):
        for name in ("../outside", "/outside", "C:/outside", "a\\b", "a/../b", "a//b", "./file"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                installers.safe_name(name)

    @unittest.skipIf(platform.system() == "Windows", "Symlink creation needs separate Windows privilege")
    def test_linux_symlinks_rejected(self):
        (self.bundle / "link").symlink_to("web")
        with self.assertRaisesRegex(ValueError, "Symlink not allowed"):
            installers.verify_bundle(self.bundle, "linux")

    @unittest.skipIf(platform.system() == "Windows", "Symlink creation needs separate Windows privilege")
    def test_macos_preserves_only_verified_internal_framework_links(self):
        app = self.root / "macos"
        manifest = fixture(app, "macos")
        framework = app / "Contents/Frameworks/FlutterMacOS.framework"
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        (version / "FlutterMacOS").write_bytes(b"macho")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "FlutterMacOS").symlink_to("Versions/Current/FlutterMacOS")
        manifest["symlinks"] = {
            "Contents/Frameworks/FlutterMacOS.framework/Versions/Current": "A",
            "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS": "Versions/Current/FlutterMacOS"}
        manifest["artifacts"]["Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"] = sha256(version / "FlutterMacOS")
        write_manifest(app, manifest)
        installers.verify_bundle(app, "macos")
        (framework / "Versions/Current").unlink()
        (framework / "Versions/Current").symlink_to(self.root)
        manifest["symlinks"]["Contents/Frameworks/FlutterMacOS.framework/Versions/Current"] = str(self.root)
        write_manifest(app, manifest)
        with self.assertRaisesRegex(ValueError, "Invalid symlink destination"):
            installers.verify_bundle(app, "macos")

    def test_bad_bundle_never_calls_native_tool_or_creates_output(self):
        (self.bundle / "web/index.html").write_text("tampered")
        with patch.object(installers.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                installers.build("linux", self.bundle, self.root / "output")
            run.assert_not_called()
        self.assertFalse((self.root / "output").exists())

    def test_output_cannot_be_inside_bundle(self):
        with self.assertRaisesRegex(ValueError, "inside the bundle"):
            installers.build("linux", self.bundle, self.bundle / "output")

    def test_missing_native_tool_never_replaces_existing_installer(self):
        output = self.root / "output"
        output.mkdir()
        old = output / "universal-hmi-linux-x64.deb"
        old.write_bytes(b"previous good installer")
        with patch.object(installers.platform, "system", return_value="Linux"), patch.object(installers.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "dpkg-deb"):
                installers.build("linux", self.bundle, output)
        self.assertEqual(old.read_bytes(), b"previous good installer")


@unittest.skipUnless(platform.system() == "Linux", "Rootless installer is Linux-specific")
class RootlessLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        fixture(self.bundle)
        self.pyz = self.root / "installer.pyz"
        pyz_fixture(self.bundle, self.pyz)
        self.prefix = self.root / "install with spaces 'and quote'"
        self.data = self.root / "user-data/universal-hmi"
        self.data.mkdir(parents=True)
        (self.data / "points.json").write_text("personal data")

    def invoke(self, *args, success=True):
        result = subprocess.run([sys.executable, str(self.pyz), "--prefix", str(self.prefix), *args],
                                text=True, capture_output=True, env={**os.environ, "XDG_DATA_HOME": str(self.data.parent)})
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_install_update_uninstall_preserves_data_and_executable_modes(self):
        self.invoke()
        self.assertTrue(os.access(self.prefix / "app/universal_hmi", os.X_OK))
        subprocess.run([str(self.prefix / "launch-universal-hmi")], check=True)
        self.assertEqual((self.prefix / "app/web/index.html").read_text(), "<!doctype html><title>one</title>")
        shutil.rmtree(self.bundle)
        fixture(self.bundle, marker="two")
        pyz_fixture(self.bundle, self.pyz)
        self.invoke()
        self.assertEqual((self.prefix / "app/web/index.html").read_text(), "<!doctype html><title>two</title>")
        subprocess.run([str(self.prefix / "uninstall-universal-hmi")], check=True)
        self.assertFalse(self.prefix.exists())
        self.assertEqual((self.data / "points.json").read_text(), "personal data")

    def test_refuses_arbitrary_existing_directory(self):
        self.prefix.mkdir()
        (self.prefix / "personal.txt").write_text("keep")
        result = self.invoke(success=False)
        self.assertIn("not a managed", result.stderr)
        self.assertEqual((self.prefix / "personal.txt").read_text(), "keep")

    def test_refuses_modified_or_unknown_files_on_update_and_uninstall(self):
        self.invoke()
        path = self.prefix / "personal.txt"
        path.write_text("keep")
        for args in ((), ("--uninstall",)):
            result = self.invoke(*args, success=False)
            self.assertIn("changed or added", result.stderr)
            self.assertEqual(path.read_text(), "keep")
        path.unlink()
        (self.prefix / "app/web/index.html").write_text("changed")
        self.invoke("--uninstall", success=False)
        self.assertTrue(self.prefix.exists())

    def test_refuses_symlink_prefix_and_payload(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.prefix.symlink_to(elsewhere)
        self.assertIn("cannot be a symlink", self.invoke(success=False).stderr)
        self.prefix.unlink()
        self.invoke()
        (self.prefix / "extra").symlink_to(elsewhere)
        self.assertIn("symlink", self.invoke("--uninstall", success=False).stderr)
        self.assertTrue(elsewhere.exists())

    def test_tampered_zip_does_not_replace_existing_install(self):
        self.invoke()
        before = user_installer.inventory(self.prefix)
        with zipfile.ZipFile(self.pyz, "a") as archive:
            archive.writestr("unexpected.txt", "untrusted")
        self.assertIn("Unexpected or missing", self.invoke(success=False).stderr)
        self.assertEqual(before, user_installer.inventory(self.prefix))

    def test_failed_atomic_swap_restores_previous_install(self):
        self.invoke()
        before = user_installer.inventory(self.prefix)
        replace = os.replace
        def fail_once(source, target):
            if Path(source).name == "new":
                raise OSError("injected final rename failure")
            return replace(source, target)
        with patch.object(user_installer.os, "replace", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "injected"):
                user_installer.install(self.pyz, self.prefix)
        self.assertEqual(before, user_installer.inventory(self.prefix))

    def test_concurrent_lock_refuses_without_touching_existing_files(self):
        self.invoke()
        lock = self.prefix.parent / ("." + self.prefix.name + ".install-lock")
        lock.mkdir()
        self.assertIn("Another install", self.invoke("--uninstall", success=False).stderr)
        self.assertTrue(self.prefix.exists())

    def test_running_installed_process_blocks_update_without_killing(self):
        self.invoke()
        # A real executable under the install root is used, rather than a script
        # whose /proc/exe would identify /bin/sh outside the installation.
        binary = self.prefix / "app/sleep-fixture"
        shutil.copy2(shutil.which("sleep"), binary)
        state_path = self.prefix / user_installer.STATE
        state = json.loads(state_path.read_text())
        state["files"] = user_installer.inventory(self.prefix)
        state_path.write_text(json.dumps(state))
        process = subprocess.Popen([str(binary), "20"])
        try:
            result = self.invoke(success=False)
            self.assertIn("Close Universal HMI", result.stderr)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(timeout=3)


class NativeDefinitions(unittest.TestCase):
    def test_windows_wmi_path_is_converted_before_string_functions(self):
        text = (installers.PACKAGING / "windows.iss").read_text()
        self.assertIn("if not VarIsNull(Process.ExecutablePath) then begin", text)
        self.assertIn("ExecutablePath := Process.ExecutablePath;\n"
                      "      ExecutablePath := Lowercase(ExecutablePath);", text)
        self.assertNotIn("Lowercase(Process.ExecutablePath)", text)

    def test_windows_is_per_user_and_does_not_autorun_or_delete_data(self):
        text = (installers.PACKAGING / "windows.iss").read_text()
        self.assertIn("PrivilegesRequired=lowest", text)
        self.assertIn("CloseApplications=no", text)
        self.assertIn("RestartApplications=no", text)
        self.assertNotIn("\n[Run]", text)
        self.assertNotIn("\n[InstallDelete]", text)
        self.assertNotIn("\n[UninstallDelete]", text)
        self.assertNotIn("\n[Registry]", text)
        self.assertIn("PrepareToInstall", text)
        self.assertIn("InitializeUninstall", text)

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("dpkg-deb"), "Requires Linux dpkg-deb")
    def test_builds_real_deb_and_rootless_archive_with_exact_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            manifest = fixture(bundle)
            output = root / "output"
            evidence = installers.build("linux", bundle, output, REVISION)
            self.assertEqual(evidence["git_revision"], REVISION)
            self.assertTrue(evidence["package_contains_web"])
            self.assertFalse(evidence["signed"])
            for name, value in evidence["artifacts"].items():
                self.assertEqual(sha256(output / name), value)
            extracted = root / "extracted"
            subprocess.run(["dpkg-deb", "--extract", str(output / "universal-hmi-linux-x64.deb"), str(extracted)], check=True)
            self.assertEqual(installers.verify_bundle(extracted / "opt/universal-hmi", "linux"), manifest)
            control = root / "control"
            subprocess.run(["dpkg-deb", "--control", str(output / "universal-hmi-linux-x64.deb"), str(control)], check=True)
            self.assertEqual({p.name for p in control.iterdir()}, {"control"})
            self.assertIn("Architecture: amd64", (control / "control").read_text())
            with zipfile.ZipFile(output / "universal-hmi-linux-x64.install.pyz") as archive:
                self.assertIn("payload/web/main.dart.js", archive.namelist())


if __name__ == "__main__":
    unittest.main(verbosity=2)

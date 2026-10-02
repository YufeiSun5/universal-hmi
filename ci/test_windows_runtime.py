"""App-local Visual C++ runtime tests; no runtime is downloaded or executed."""
import copy
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest.mock import patch

from build_installers import verify_bundle
from build_release import sha256
from package_desktop import (WINDOWS_CRT_REQUIRED, locate_windows_crt,
                             prepare_windows_runtime, require_amd64_pe,
                             verify_windows_runtime)
from test_installers import fixture, write_manifest


def pe(path, machine=0x8664, payload=b"release-runtime"):
    path.parent.mkdir(parents=True, exist_ok=True)
    content = bytearray(512)
    content[:2] = b"MZ"
    struct.pack_into("<I", content, 60, 128)
    content[128:132] = b"PE\0\0"
    struct.pack_into("<H", content, 132, machine)
    struct.pack_into("<H", content, 152, 0x20B)
    path.write_bytes(content + payload)


class WindowsRuntime(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.vc = self.root / "Visual Studio/VC"
        self.redist = self.vc / "Redist/MSVC/14.44.35211"
        self.crt = self.redist / "x64/Microsoft.VC143.CRT"
        self.names = WINDOWS_CRT_REQUIRED | {"msvcp140_1.dll", "msvcp140_2.dll", "concrt140.dll"}
        for name in self.names:
            pe(self.crt / name)
        self.bundle = self.root / "bundle"
        self.manifest = fixture(self.bundle, "windows")
        self.environment = {"VCINSTALLDIR": str(self.vc)}

    def add_runtime(self):
        files, runtime = prepare_windows_runtime(self.bundle, self.environment)
        for name, (source, digest) in files.items():
            shutil.copy2(source, self.bundle / name)
            self.manifest["artifacts"][name] = digest
        self.manifest["windows_vc_runtime"] = runtime
        write_manifest(self.bundle, self.manifest)
        return runtime

    def test_complete_release_dll_set_bundled_and_hashed(self):
        runtime = self.add_runtime()
        self.assertEqual(set(runtime["files"]), self.names)
        self.assertEqual(runtime["version"], "14.44.35211")
        self.assertNotIn(str(self.root), runtime["source"])
        verify_windows_runtime(self.bundle, self.manifest)
        verify_bundle(self.bundle, "windows")

    def test_latest_installed_version_chosen_numerically(self):
        other = self.vc / "Redist/MSVC/14.9.90000/x64/Microsoft.VC143.CRT"
        other.mkdir(parents=True)
        actual, version = locate_windows_crt(self.environment)
        self.assertEqual(actual, self.crt)
        self.assertEqual(version, "14.44.35211")

    def test_active_toolset_redist_takes_precedence(self):
        active = self.vc / "Redist/MSVC/14.42.34433"
        (active / "x64/Microsoft.VC143.CRT").mkdir(parents=True)
        actual, version = locate_windows_crt({**self.environment, "VCToolsRedistDir": str(active)})
        self.assertEqual(version, "14.42.34433")
        self.assertEqual(actual, active / "x64/Microsoft.VC143.CRT")

    def test_official_installed_vswhere_fallback(self):
        program_files = self.root / "Program Files (x86)"
        vswhere = program_files / "Microsoft Visual Studio/Installer/vswhere.exe"
        vswhere.parent.mkdir(parents=True)
        vswhere.write_bytes(b"fixture not executed")
        with patch("package_desktop.subprocess.check_output", return_value=str(self.vc.parent) + "\n") as command:
            actual, _ = locate_windows_crt({"ProgramFiles(x86)": str(program_files)})
        self.assertEqual(actual, self.crt)
        invocation = command.call_args.args[0]
        self.assertEqual(invocation[0], str(vswhere))
        self.assertIn("Microsoft.VisualStudio.Component.VC.Tools.x86.x64", invocation)

    def test_missing_vswhere_fails_without_download(self):
        with patch("package_desktop.subprocess.check_output") as command:
            with self.assertRaisesRegex(ValueError, "vswhere"):
                locate_windows_crt({"ProgramFiles(x86)": str(self.root / "missing")})
            command.assert_not_called()

    def test_system32_or_debug_runtime_not_accepted_as_active_redist(self):
        for path in (self.root / "Windows/System32", self.redist / "debug_nonredist"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "VCToolsRedistDir"):
                locate_windows_crt({"VCToolsRedistDir": str(path)})

    def test_missing_required_dll_fails_before_bundle_mutation(self):
        (self.crt / "vcruntime140_1.dll").unlink()
        before = set(self.bundle.iterdir())
        with self.assertRaisesRegex(ValueError, "Required release"):
            prepare_windows_runtime(self.bundle, self.environment)
        self.assertEqual(set(self.bundle.iterdir()), before)

    def test_x86_runtime_rejected(self):
        pe(self.crt / "msvcp140.dll", machine=0x14C)
        with self.assertRaisesRegex(ValueError, "AMD64"):
            prepare_windows_runtime(self.bundle, self.environment)

    def test_debug_dll_rejected(self):
        pe(self.crt / "vcruntime140d.dll")
        with self.assertRaisesRegex(ValueError, "debug"):
            prepare_windows_runtime(self.bundle, self.environment)

    def test_existing_conflicting_dll_not_overwritten(self):
        existing = self.bundle / "msvcp140.dll"
        pe(existing, payload=b"user file keep")
        before = existing.read_bytes()
        with self.assertRaisesRegex(ValueError, "Conflicting existing"):
            prepare_windows_runtime(self.bundle, self.environment)
        self.assertEqual(existing.read_bytes(), before)

    def test_same_existing_runtime_can_be_repackaged(self):
        self.add_runtime()
        files, _ = prepare_windows_runtime(self.bundle, self.environment)
        self.assertEqual(set(files), self.names)

    def test_installer_rejects_missing_runtime_even_on_rich_build_host(self):
        with self.assertRaisesRegex(ValueError, "app-local VC"):
            verify_bundle(self.bundle, "windows")

    def test_installer_rejects_tampered_runtime_with_rehashed_outer_artifact(self):
        self.add_runtime()
        path = self.bundle / "msvcp140.dll"
        pe(path, payload=b"changed")
        self.manifest["artifacts"][path.name] = sha256(path)
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "runtime hash differs"):
            verify_bundle(self.bundle, "windows")

    def test_installer_rejects_wrong_arch_even_with_consistent_hashes(self):
        self.add_runtime()
        path = self.bundle / "vcruntime140.dll"
        pe(path, machine=0xAA64)
        self.manifest["artifacts"][path.name] = sha256(path)
        self.manifest["windows_vc_runtime"]["files"][path.name] = sha256(path)
        write_manifest(self.bundle, self.manifest)
        with self.assertRaisesRegex(ValueError, "AMD64"):
            verify_bundle(self.bundle, "windows")

    def test_truncated_or_non_pe_dlls_rejected(self):
        path = self.root / "invalid.dll"
        for data in (b"", b"MZ", b"MZ" + bytes(80), b"this is not a DLL" * 30):
            path.write_bytes(data)
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                require_amd64_pe(path)

    def test_manifest_cannot_point_runtime_hash_outside_bundle(self):
        self.add_runtime()
        self.manifest["windows_vc_runtime"]["files"]["../outside.dll"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Invalid or debug"):
            verify_windows_runtime(self.bundle, self.manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)

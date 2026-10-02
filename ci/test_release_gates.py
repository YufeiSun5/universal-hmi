"""Fault-injection tests for release provenance and failure evidence.

Temporary stand-in artifacts are deliberate negative-test inputs; they are never
packaged or used as evidence that a real Flutter release was built.
"""
from contextlib import nullcontext
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

import build_release
import package_final
import run_linux_ui


class ReleaseGates(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hmi-release-gate-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.bundle = self.root / "bundle"
        self.sdk = self.root / "sdk"
        self.engine = self.bundle / "lib/libflutter_linux_gtk.so"
        self.official = self.sdk / "bin/cache/artifacts/engine/linux-x64-release/libflutter_linux_gtk.so"
        self.aot = self.bundle / "lib/libapp.so"
        self.engine.parent.mkdir(parents=True)
        self.official.parent.mkdir(parents=True)
        self.engine.write_bytes(b"official-release-engine-fixture")
        self.official.write_bytes(self.engine.read_bytes())
        self.aot.write_bytes(b"\x7fELF-test-AOT-fixture")
        (self.bundle / "universal_hmi").write_bytes(b"runner-fixture")

    def test_release_engine_matches_official_and_wrong_debug_engine_is_rejected(self):
        result = build_release.verify_linux(self.bundle, self.sdk)
        self.assertEqual(result["bundled_engine_sha256"], result["official_engine_sha256"])
        self.engine.write_bytes(b"wrong-debug-engine-fixture")
        with self.assertRaisesRegex(AssertionError, "official linux-x64-release"):
            build_release.verify_linux(self.bundle, self.sdk)

    def test_missing_or_non_elf_aot_cannot_pass_release_gate(self):
        self.aot.unlink()
        with self.assertRaisesRegex(AssertionError, "Required release artifact missing"):
            build_release.verify_linux(self.bundle, self.sdk)
        self.aot.write_bytes(b"debug-kernel-snapshot-is-not-AOT")
        with self.assertRaisesRegex(AssertionError, "not ELF"):
            build_release.verify_linux(self.bundle, self.sdk)

    def test_source_mutation_during_build_prevents_manifest(self):
        (self.root / "app/lib").mkdir(parents=True)
        source = self.root / "app/lib/main.dart"
        source.write_text("original source\n")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "add", "app/lib/main.dart"], cwd=self.root, check=True)
        binary = self.root / "bin/flutter"
        binary.parent.mkdir()
        binary.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath('lib/main.dart').write_text('mutated during build\\n')\n")
        binary.chmod(0o755)
        with patch.object(build_release, "ROOT", self.root), patch.dict(os.environ, {"PATH": str(binary.parent) + os.pathsep + os.environ["PATH"], "FLUTTER_ROOT": str(self.sdk)}), patch.object(sys, "argv", ["build_release.py", "linux"]):
            with self.assertRaisesRegex(AssertionError, "Source or lock file changed"):
                build_release.main()
        self.assertFalse((self.root / "dist/provenance/linux-release.json").exists())

    def write_release(self, folder, target, source="old-source", artifact_suffix="old"):
        folder.mkdir(parents=True, exist_ok=True)
        contents = {"index.html": f"web-{artifact_suffix}".encode()} if target == "web" else {
            "universal_hmi": f"runner-{artifact_suffix}".encode(),
            "universal-hmi-server": f"backend-{artifact_suffix}".encode(),
            "lib/libapp.so": f"AOT-{artifact_suffix}".encode(),
        }
        for name, content in contents.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        manifest = {"mode": "release", "target": target, "git_revision": "same-revision",
            "source_sha256": source, "source_files": {"app/lib/main.dart": source},
            "artifacts": {name: build_release.sha256(folder / name) for name in contents}}
        (folder / "build-manifest.json").write_text(json.dumps(manifest))
        return manifest

    def manifests(self):
        web = self.root / "dist/web"
        linux = self.root / "dist/linux"
        manifest = self.write_release(linux, "linux")
        self.write_release(web, "web")
        return web, linux, manifest

    def local_builds(self, source="new-source", artifact_suffix="new"):
        manifests = {}
        for target in ("linux", "web"):
            manifests[target] = self.write_release(self.root / package_final.BUILD_PATHS[target], target, source, artifact_suffix)
            provenance = self.root / "dist/provenance" / f"{target}-release.json"
            provenance.parent.mkdir(parents=True, exist_ok=True)
            provenance.write_text(json.dumps(manifests[target]))
        return manifests

    def test_windows_manifest_names_can_be_read_by_linux_assembler(self):
        bundle = PureWindowsPath("C:/build/Release")
        name = build_release.artifact_name(bundle / "data/flutter_assets/AssetManifest.bin", bundle)
        self.assertEqual(name, "data/flutter_assets/AssetManifest.bin")
        linux_copy = self.root / name
        linux_copy.parent.mkdir(parents=True)
        linux_copy.write_bytes(b"copied Windows artifact")
        self.assertTrue((self.root / name).is_file())

    def test_changed_binary_is_not_assembled(self):
        _, linux, _ = self.manifests()
        (linux / "universal_hmi").write_bytes(b"binary substituted after verification")
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "Desktop artifact changed"):
                package_final.main()
        self.assertFalse((self.root / "dist/final").exists())

    def test_web_and_desktop_source_mismatch_is_not_assembled(self):
        web, _, _ = self.manifests()
        manifest = json.loads((web / "build-manifest.json").read_text())
        manifest["source_sha256"] = "different-source"
        (web / "build-manifest.json").write_text(json.dumps(manifest))
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "source hashes differ"):
                package_final.main()
        self.assertFalse((self.root / "dist/final").exists())

    def test_mutually_consistent_old_dist_is_rejected_against_new_local_build(self):
        self.manifests()
        self.local_builds()
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "Staged web is stale.*source_sha256 differs"):
                package_final.main(("linux",))
        self.assertFalse((self.root / "dist/final").exists())
        self.assertEqual((self.root / "dist/linux/universal_hmi").read_bytes(), b"runner-old")

    def test_same_source_but_old_aot_is_rejected_against_current_build(self):
        self.manifests()
        manifests = self.local_builds(source="old-source", artifact_suffix="old")
        local = self.root / package_final.BUILD_PATHS["linux"]
        (local / "lib/libapp.so").write_bytes(b"AOT-new")
        manifests["linux"]["artifacts"]["lib/libapp.so"] = build_release.sha256(local / "lib/libapp.so")
        (local / "build-manifest.json").write_text(json.dumps(manifests["linux"]))
        (self.root / "dist/provenance/linux-release.json").write_text(json.dumps(manifests["linux"]))
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "Staged linux is stale.*artifact lib/libapp.so differs"):
                package_final.main(("linux",))
        self.assertFalse((self.root / "dist/final").exists())

    def test_explicit_staging_removes_old_files_and_tar_contains_current_bytes(self):
        self.manifests()
        self.local_builds()
        (self.root / "dist/linux/obsolete-ui-file").write_bytes(b"must not survive clean staging")
        with patch.object(package_final, "ROOT", self.root):
            package_final.main(("linux",), stage=True)
        self.assertFalse((self.root / "dist/linux/obsolete-ui-file").exists())
        manifest = json.loads((self.root / "dist/linux/build-manifest.json").read_text())
        self.assertEqual(manifest["source_sha256"], "new-source")
        with tarfile.open(self.root / "dist/final/universal-hmi-linux-x64.tar.gz") as archive:
            self.assertEqual(archive.extractfile("universal-hmi/universal_hmi").read(), b"runner-new")
            self.assertEqual(archive.extractfile("universal-hmi/lib/libapp.so").read(), b"AOT-new")
            self.assertEqual(archive.extractfile("universal-hmi/web/index.html").read(), b"web-new")
            archived = json.load(archive.extractfile("universal-hmi/build-manifest.json"))
            self.assertEqual(archived, manifest)

    def test_downloaded_ci_artifacts_work_without_local_builds_or_provenance(self):
        self.manifests()
        with patch.object(package_final, "ROOT", self.root):
            package_final.main(("linux",))
        self.assertTrue((self.root / "dist/final/universal-hmi-linux-x64.tar.gz").is_file())

    def test_provenance_alone_rejects_old_downloaded_artifacts(self):
        self.manifests()
        provenance = self.root / "dist/provenance/web-release.json"
        provenance.parent.mkdir(parents=True)
        current = json.loads((self.root / "dist/web/build-manifest.json").read_text())
        current["source_sha256"] = "new-source"
        provenance.write_text(json.dumps(current))
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "Staged web is stale.*source_sha256 differs"):
                package_final.main(("linux",))

    def test_corrupt_local_build_does_not_replace_existing_dist(self):
        self.manifests()
        self.local_builds()
        (self.root / package_final.BUILD_PATHS["linux"] / "lib/libapp.so").write_bytes(b"corrupted after verification")
        with patch.object(package_final, "ROOT", self.root):
            with self.assertRaisesRegex(AssertionError, "Current local linux build artifact changed"):
                package_final.main(("linux",), stage=True)
        self.assertEqual((self.root / "dist/linux/universal_hmi").read_bytes(), b"runner-old")
        self.assertEqual((self.root / "dist/web/index.html").read_bytes(), b"web-old")

    def test_failed_native_command_preserves_error_log_and_closes_fixture(self):
        binary = self.root / "bin/flutter"
        binary.parent.mkdir()
        binary.write_text("#!/usr/bin/env python3\nimport sys\nprint('intentional native driver failure', file=sys.stderr)\nsys.exit(7)\n")
        binary.chmod(0o755)
        (self.root / "app").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "temporary test fixture"], cwd=self.root, check=True)
        server = self.root / "server-placeholder"
        server.write_text("unused; backend start is replaced by a temporary sleeping process")
        output = self.root / "evidence"
        backend = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(lambda: backend.poll() is None and backend.kill())
        fixture = Mock()
        fixture.prepare.return_value = fixture
        fixture.start.return_value = fixture
        with patch.object(run_linux_ui, "ROOT", self.root), patch.object(run_linux_ui, "start_backend", return_value=backend), patch.object(run_linux_ui, "CapacityFixture", return_value=fixture), patch.object(run_linux_ui, "display_environment", return_value=nullcontext(dict(os.environ, PATH=str(binary.parent) + os.pathsep + os.environ["PATH"]))), patch.dict(os.environ, {"PATH": str(binary.parent) + os.pathsep + os.environ["PATH"]}), patch.object(sys, "argv", ["run_linux_ui.py", "--server", str(server), "--output", str(output), "--display", ":fixture"]):
            with self.assertRaises(subprocess.CalledProcessError):
                run_linux_ui.main()
        self.assertIn("intentional native driver failure", (output / "flutter-drive.log").read_text())
        self.assertTrue((output / "cpu-rss.json").exists())
        fixture.close.assert_called_once()
        self.assertIsNotNone(backend.poll())


if __name__ == "__main__":
    unittest.main(verbosity=2)

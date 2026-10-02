"""Verify and assemble release packages; explicitly stage current local builds.

CI may download verified inputs directly into dist. On a build machine, existing
app/build manifests and dist/provenance are authoritative and stale dist inputs
are rejected. Use --stage-local to replace dist inputs from verified local builds
before assembly. Close any running packaged app before staging.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile

from build_release import sha256
from common import ROOT

BUILD_PATHS = {
    "linux": "app/build/linux/x64/release/bundle",
    "windows": "app/build/windows/x64/runner/Release",
    "web": "app/build/web",
}


def load_manifest(folder, target, label):
    path = folder / "build-manifest.json"
    assert path.is_file(), f"{label} has no verified release manifest: {path}"
    manifest = json.loads(path.read_text())
    assert manifest.get("mode") == "release", f"{label} is not a release"
    assert manifest.get("target") == target, f"{label} target is not {target}"
    assert manifest.get("artifacts"), f"{label} has no artifact hashes"
    return manifest


def verify_artifacts(folder, manifest, label):
    for name, expected in manifest["artifacts"].items():
        relative = PurePosixPath(name)
        assert not relative.is_absolute() and ".." not in relative.parts and "\\" not in name, f"Invalid artifact path: {name}"
        path = folder / name
        assert path.is_file(), f"{label} artifact missing: {name}"
        assert sha256(path) == expected, f"{label} artifact changed: {name}"
    actual = {path.relative_to(folder).as_posix() for path in folder.rglob("*") if path.is_file()}
    expected_names = set(manifest["artifacts"]) | {"build-manifest.json"}
    assert actual == expected_names, f"{label} contains unverified files: {sorted(actual - expected_names)}"


def compare_reference(staged, reference, target, origin):
    prefix = f"Staged {target} is stale or inconsistent with {origin}"
    for field in ("mode", "target", "git_revision", "source_sha256"):
        assert staged.get(field) == reference.get(field), f"{prefix}: {field} differs. Run package_final.py --stage-local for current local builds."
    if "source_files" in reference:
        assert staged.get("source_files") == reference["source_files"], f"{prefix}: source file hashes differ"
    for name, expected in reference["artifacts"].items():
        assert staged["artifacts"].get(name) == expected, f"{prefix}: artifact {name} differs. Run package_final.py --stage-local."


def current_references(target):
    """Absent local outputs are normal in the CI artifact-assembly job."""
    references = []
    local = ROOT / BUILD_PATHS[target]
    if local.exists():
        manifest = load_manifest(local, target, f"Current local {target} build")
        verify_artifacts(local, manifest, f"Current local {target} build")
        references.append((str(local), manifest))
    provenance = ROOT / "dist/provenance" / f"{target}-release.json"
    if provenance.exists():
        manifest = json.loads(provenance.read_text())
        assert manifest.get("mode") == "release" and manifest.get("target") == target, f"Invalid current provenance: {provenance}"
        if references:
            compare_reference(references[0][1], manifest, target, str(provenance))
        references.append((str(provenance), manifest))
    return references


def verify_pair(desktop, web):
    assert desktop["git_revision"] == web["git_revision"], "Desktop and Web revisions differ"
    assert desktop["source_sha256"] == web["source_sha256"], "Desktop and Web source hashes differ"
    if "source_files" in desktop or "source_files" in web:
        assert desktop.get("source_files") == web.get("source_files"), "Desktop and Web source file hashes differ"


def stage_local(targets):
    """Validate everything, copy to temporary siblings, then replace cleanly."""
    names = ("web", *targets)
    inputs = {}
    for target in names:
        folder = ROOT / BUILD_PATHS[target]
        manifest = load_manifest(folder, target, f"Current local {target} build")
        verify_artifacts(folder, manifest, f"Current local {target} build")
        for origin, reference in current_references(target):
            compare_reference(manifest, reference, target, origin)
        inputs[target] = (folder, manifest)
    for target in targets:
        verify_pair(inputs[target][1], inputs["web"][1])
    dist = ROOT / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".stage-release-", dir=dist) as temporary:
        temporary = Path(temporary)
        for target, (folder, manifest) in inputs.items():
            copied = temporary / f"new-{target}"
            shutil.copytree(folder, copied)
            verify_artifacts(copied, manifest, f"Copied local {target} build")
        moved = []
        try:
            for target in names:
                destination = dist / target
                backup = temporary / f"old-{target}"
                if destination.exists():
                    os.replace(destination, backup)
                moved.append(target)
                os.replace(temporary / f"new-{target}", destination)
        except BaseException:
            for target in reversed(moved):
                destination = dist / target
                if destination.exists():
                    shutil.rmtree(destination)
                backup = temporary / f"old-{target}"
                if backup.exists():
                    os.replace(backup, destination)
            raise
    print("PASS: current verified local builds staged cleanly: " + ", ".join(names))


def main(targets=("linux", "windows"), *, stage=False):
    targets = tuple(dict.fromkeys(targets))
    assert targets and all(target in ("linux", "windows") for target in targets)
    if stage:
        stage_local(targets)
    web = ROOT / "dist/web"
    web_manifest = load_manifest(web, "web", "Staged Web")
    verify_artifacts(web, web_manifest, "Web")
    for origin, reference in current_references("web"):
        compare_reference(web_manifest, reference, "web", origin)
    # Validate every target before changing any staged bundle or final archive.
    manifests = {}
    for target in targets:
        folder = ROOT / "dist" / target
        manifest = load_manifest(folder, target, f"Staged {target}")
        verify_pair(manifest, web_manifest)
        verify_artifacts(folder, manifest, "Desktop")
        for origin, reference in current_references(target):
            compare_reference(manifest, reference, target, origin)
        manifests[target] = manifest
    for target, manifest in manifests.items():
        folder = ROOT / "dist" / target
        if (folder / "web").exists():
            shutil.rmtree(folder / "web")
        shutil.copytree(web, folder / "web")
        manifest["artifacts"] = {name: digest for name, digest in manifest["artifacts"].items() if not name.startswith("web/")}
        manifest["artifacts"].update({path.relative_to(folder).as_posix(): sha256(path) for path in (folder / "web").rglob("*") if path.is_file()})
        manifest["package_contains_web"] = True
        (folder / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        verify_artifacts(folder, manifest, f"Assembled {target}")
    if "linux" in targets:
        linux = ROOT / "dist/linux"
        for name in ("universal_hmi", "universal-hmi-server"):
            (linux / name).chmod(0o755)
        output = ROOT / "dist/final"
        output.mkdir(parents=True, exist_ok=True)
        archive_path = output / "universal-hmi-linux-x64.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            archive.add(linux, arcname="universal-hmi")
        (output / "SHA256SUMS").write_text(f"{sha256(archive_path)}  {archive_path.name}\n")
    print("PASS: staged inputs match current build/provenance; desktop/Web identities and artifact hashes verified; final packages assembled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", nargs="+", choices=("linux", "windows"), default=["linux", "windows"])
    parser.add_argument("--stage-local", action="store_true", help="Cleanly replace dist inputs from verified current app/build outputs before assembly")
    args = parser.parse_args()
    main(tuple(args.targets), stage=args.stage_local)

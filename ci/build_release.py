"""Serial release build with source, engine and AOT provenance.

Run after profile/debug testing. Linux generated build files are discarded before
building so cached non-release engines cannot enter a shipping bundle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from common import ROOT


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sources():
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
    # Generated dependency bytes remain part of build provenance even though
    # the VCS contains their pinned recipe rather than a large binary blob.
    font_lock = ROOT / 'ci/fonts.lock.json'
    if font_lock.is_file():
        tracked.extend('app/assets/fonts/' + name for name in json.loads(font_lock.read_text())['fonts'])
    result = {}
    for name in sorted(set(tracked)):
        if not name or not (name.startswith(("app/", "backend/", "ci/", ".github/"))):
            continue
        if "/build/" in name or "/.dart_tool/" in name or "/__pycache__/" in name:
            continue
        path = ROOT / name
        if path.is_file():
            result[name] = sha256(path)
    return result


def artifact_name(path, bundle):
    """Portable archive names, including when the producer runs on Windows."""
    return path.relative_to(bundle).as_posix()


def verify_linux(bundle, flutter_root):
    engine = bundle / "lib/libflutter_linux_gtk.so"
    official = flutter_root / "bin/cache/artifacts/engine/linux-x64-release/libflutter_linux_gtk.so"
    aot = bundle / "lib/libapp.so"
    for path in (engine, official, aot, bundle / "universal_hmi"):
        if not path.is_file() or path.stat().st_size == 0:
            raise AssertionError(f"Required release artifact missing: {path}")
    assert sha256(engine) == sha256(official), "Bundle engine differs from official linux-x64-release engine"
    assert aot.read_bytes()[:4] == b"\x7fELF", "Linux AOT artifact is not ELF"
    return {"bundled_engine_sha256": sha256(engine), "official_engine_sha256": sha256(official), "aot_sha256": sha256(aot), "official_engine_path": str(official)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("linux", "windows", "web"))
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--flutter-root", type=Path)
    args = parser.parse_args()
    flutter = shutil.which("flutter")
    assert flutter, "flutter not available"
    flutter_root = args.flutter_root or Path(os.environ.get("FLUTTER_ROOT", str(Path(flutter).resolve().parents[1])))
    before = sources()
    if not args.verify_only:
        if args.target == "linux":
            shutil.rmtree(ROOT / "app/build/linux", ignore_errors=True)
        command = [flutter, "build", args.target, "--release", "--no-pub"]
        if args.target == "web":
            command.append("--no-web-resources-cdn")
        subprocess.run(command, cwd=ROOT / "app", check=True)
    after = sources()
    assert before == after, "Source or lock file changed during release build"
    bundles = {"linux": ROOT / "app/build/linux/x64/release/bundle", "windows": ROOT / "app/build/windows/x64/runner/Release", "web": ROOT / "app/build/web"}
    bundle = bundles[args.target]
    evidence = verify_linux(bundle, flutter_root) if args.target == "linux" else {}
    manifest = {
        "schema": 1, "target": args.target, "mode": "release", "verified_unix": time.time(),
        "git_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": hashlib.sha256(json.dumps(after, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "source_files": after, "flutter_version": subprocess.check_output([flutter, "--version", "--machine"], text=True),
        "built_in_this_invocation": not args.verify_only, **evidence,
        "artifacts": {artifact_name(p, bundle): sha256(p) for p in sorted(bundle.rglob("*")) if p.is_file() and p.name != "build-manifest.json"},
    }
    (bundle / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    output = ROOT / "dist/provenance"
    output.mkdir(parents=True, exist_ok=True)
    (output / f"{args.target}-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {args.target} release artifacts; source SHA256 {manifest['source_sha256']}")


if __name__ == "__main__":
    main()

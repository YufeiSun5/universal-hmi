"""Serial release build with source, engine and AOT provenance.

Run after profile/debug testing. Linux generated build files are discarded before
building so cached non-release engines cannot enter a shipping bundle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import subprocess
import time

from common import ROOT

BUILD_PATHS = {
    "linux": "app/build/linux/x64/release/bundle",
    "windows": "app/build/windows/x64/runner/Release",
    "macos": "app/build/macos/Build/Products/Release/Universal HMI.app",
    "web": "app/build/web",
}
MACOS_ARCHITECTURES = {"arm64", "x86_64"}


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
        if not name or not (name.startswith(("app/", "backend/", "ci/", "packaging/", ".github/"))):
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


def valid_artifact_name(name):
    if not isinstance(name, str):
        return False
    relative = PurePosixPath(name)
    return (bool(name) and not relative.is_absolute()
            and ".." not in relative.parts and "\\" not in name
            and relative.as_posix() == name and ":" not in name)


def artifact_inventory(bundle, *, allow_symlinks=False):
    """Hash real files once, recording framework links without traversing them."""
    bundle = Path(bundle)
    assert bundle.is_dir() and not bundle.is_symlink(), f"Invalid bundle directory: {bundle}"
    root = bundle.resolve()
    artifacts, symlinks = {}, {}
    for directory, dirs, files in os.walk(bundle, followlinks=False):
        for entry in sorted(dirs + files):
            path = Path(directory) / entry
            name = artifact_name(path, bundle)
            assert valid_artifact_name(name), f"Invalid artifact path: {name}"
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                assert name != "build-manifest.json", "Release manifest cannot be a symlink"
                assert allow_symlinks, f"Unexpected symlink: {name}"
                target = os.readlink(path)
                assert target and not PurePosixPath(target).is_absolute() and "\\" not in target, f"Invalid symlink target: {name}"
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise AssertionError(f"Broken or cyclic symlink: {name}") from error
                assert resolved.is_relative_to(root), f"Symlink escapes bundle: {name}"
                assert resolved.is_file() or resolved.is_dir(), f"Symlink target is not a file or directory: {name}"
                assert not (resolved.is_dir() and (resolved == root or resolved in path.parents)), f"Cyclic directory symlink: {name}"
                symlinks[name] = target
            elif stat.S_ISREG(mode):
                if name != "build-manifest.json":
                    artifacts[name] = sha256(path)
            else:
                assert stat.S_ISDIR(mode), f"Unsupported special artifact: {name}"
    return {"artifacts": artifacts, "symlinks": symlinks}


def macho_slices(path):
    """Read CPU types and hash whole Mach-O slices, independent of fat ordering."""
    data = Path(path).read_bytes()
    cpu_names = {0x01000007: "x86_64", 0x0100000c: "arm64"}

    def thin(blob):
        assert len(blob) >= 32 and blob[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"), f"Not a 64-bit Mach-O artifact: {path}"
        endian = "<" if blob[:4] == b"\xcf\xfa\xed\xfe" else ">"
        cpu = struct.unpack_from(endian + "I", blob, 4)[0]
        assert cpu in cpu_names, f"Unsupported Mach-O architecture in {path}"
        return cpu, hashlib.sha256(blob).hexdigest()

    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        cpu, digest = thin(data)
        return {cpu_names[cpu]: digest}
    formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
               b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    assert len(data) >= 8 and data[:4] in formats, f"Not a Mach-O artifact: {path}"
    endian, wide = formats[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    size = 32 if wide else 20
    assert 0 < count <= 8 and len(data) >= 8 + count * size, f"Invalid universal Mach-O header: {path}"
    result, ranges = {}, []
    for index in range(count):
        cpu, _, offset, length, *_ = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * size)
        assert offset >= 8 + count * size and length >= 32 and offset + length <= len(data), f"Invalid Mach-O slice bounds: {path}"
        assert not any(offset < end and offset + length > start for start, end in ranges), f"Overlapping Mach-O slices: {path}"
        ranges.append((offset, offset + length))
        actual_cpu, digest = thin(data[offset:offset + length])
        assert cpu == actual_cpu and cpu_names[cpu] not in result, f"Invalid or duplicate Mach-O slice: {path}"
        result[cpu_names[cpu]] = digest
    return result


def require_universal_macos(path):
    slices = macho_slices(path)
    assert set(slices) == MACOS_ARCHITECTURES, f"macOS artifact must contain arm64 and x86_64: {path}"
    return slices


def verify_macos(bundle, flutter_root):
    runner = bundle / "Contents/MacOS/universal_hmi"
    engine = bundle / "Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
    aot = bundle / "Contents/Frameworks/App.framework/Versions/A/App"
    official = flutter_root / "bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/Versions/A/FlutterMacOS"
    inventory = artifact_inventory(bundle, allow_symlinks=True)
    assert not any(name.endswith(("/kernel_blob.bin", "/vm_snapshot_data", "/isolate_snapshot_data")) for name in inventory["artifacts"]), "macOS release contains debug snapshots"
    for path in (runner, engine, aot, official):
        assert path.is_file() and path.stat().st_size, f"Required release artifact missing: {path}"
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    assert info.get("CFBundleExecutable") == runner.name and info.get("CFBundlePackageType") == "APPL", "Invalid macOS app bundle metadata"
    engine_slices = require_universal_macos(engine)
    assert engine_slices == require_universal_macos(official), "Bundle engine differs from official darwin-x64-release engine slices"
    # Include plugins too: a universal runner with a host-only plugin cannot run on both Macs.
    binaries = {}
    for name in inventory["artifacts"]:
        path = bundle / name
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
            binaries[name] = require_universal_macos(path)
    require_universal_macos(runner)
    require_universal_macos(aot)
    return {"architectures": sorted(MACOS_ARCHITECTURES), "official_engine_path": str(official),
            "bundled_engine_sha256": sha256(engine), "official_engine_sha256": sha256(official),
            "engine_slice_sha256": engine_slices, "aot_sha256": sha256(aot),
            "macho_slice_sha256": binaries, "distribution_signing": "unsigned-development"}


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
    parser.add_argument("target", choices=tuple(BUILD_PATHS))
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--flutter-root", type=Path)
    args = parser.parse_args()
    flutter = shutil.which("flutter")
    assert flutter, "flutter not available"
    flutter_root = args.flutter_root or Path(os.environ.get("FLUTTER_ROOT", str(Path(flutter).resolve().parents[1])))
    before = sources()
    if not args.verify_only:
        if args.target in ("linux", "macos"):
            shutil.rmtree(ROOT / "app/build" / args.target, ignore_errors=True)
        command = [flutter, "build", args.target, "--release", "--no-pub"]
        if args.target == "web":
            command.append("--no-web-resources-cdn")
        subprocess.run(command, cwd=ROOT / "app", check=True)
    after = sources()
    assert before == after, "Source or lock file changed during release build"
    bundle = ROOT / BUILD_PATHS[args.target]
    evidence = verify_linux(bundle, flutter_root) if args.target == "linux" else verify_macos(bundle, flutter_root) if args.target == "macos" else {}
    manifest = {
        "schema": 1, "target": args.target, "mode": "release", "verified_unix": time.time(),
        "git_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": hashlib.sha256(json.dumps(after, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "source_files": after, "flutter_version": subprocess.check_output([flutter, "--version", "--machine"], text=True),
        "built_in_this_invocation": not args.verify_only, **evidence,
        **artifact_inventory(bundle, allow_symlinks=args.target == "macos"),
    }
    (bundle / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    output = ROOT / "dist/provenance"
    output.mkdir(parents=True, exist_ok=True)
    (output / f"{args.target}-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {args.target} release artifacts; source SHA256 {manifest['source_sha256']}")


if __name__ == "__main__":
    main()

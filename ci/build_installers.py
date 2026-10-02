"""Build native installers from exact, already-assembled release bundles.

No package manager, network, signing credential, service or firewall is touched.
Linux: dpkg-deb plus a Python 3 rootless installer; Windows: installed Inno Setup;
macOS: Apple's hdiutil. Each host builds its own platform's installer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tempfile
import zipfile
import zipapp

from build_release import sha256
from common import ROOT

PACKAGING = ROOT / "packaging"
TARGETS = ("linux", "windows", "macos")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_name(name):
    require(isinstance(name, str) and name and "\\" not in name and ":" not in name and "\x00" not in name,
            f"Invalid artifact path: {name!r}")
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts and str(path) == name,
            f"Invalid artifact path: {name!r}")
    return path


def read_json(path):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)


def verify_bundle(folder, target, expected_revision=None):
    """Reject extra/missing/changed files, unsafe links and mismatched Web."""
    folder = Path(folder).resolve(strict=True)
    manifest = read_json(folder / "build-manifest.json")
    require(manifest.get("schema") == 1, "Unsupported build manifest schema")
    require(manifest.get("mode") == "release" and manifest.get("target") == target,
            f"Expected a verified {target} release bundle")
    require(manifest.get("package_contains_web") is True, "Bundle has no assembled Web release")
    revision = manifest.get("git_revision", "")
    require(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision), "Invalid source revision")
    if expected_revision:
        require(revision == expected_revision, "Bundle revision differs from expected revision")
    source_hash = manifest.get("source_sha256", "")
    require(isinstance(source_hash, str) and re.fullmatch(r"[0-9a-f]{64}", source_hash), "Invalid source hash")
    source_files = manifest.get("source_files")
    require(isinstance(source_files, dict) and source_files, "Missing source inventory")
    require(hashlib.sha256(json.dumps(source_files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            == source_hash, "Source inventory hash differs")
    artifacts = manifest.get("artifacts")
    require(isinstance(artifacts, dict) and artifacts, "Missing artifact hashes")
    links = manifest.get("symlinks", {})
    require(isinstance(links, dict), "Invalid symlink manifest")
    require(not set(links) & set(artifacts), "Artifact and symlink inventories overlap")
    for name, destination in links.items():
        safe_name(name)
        require(isinstance(destination, str) and destination and not os.path.isabs(destination),
                f"Invalid symlink destination: {name}")
        link = folder / name
        require(link.is_symlink() and os.readlink(link) == destination, f"Changed symlink: {name}")
    actual = set()
    actual_links = set()
    for path in folder.rglob("*"):
        name = path.relative_to(folder).as_posix()
        if path.is_symlink():
            require(target == "macos", f"Symlink not allowed in {target} bundle: {name}")
            require(path.resolve(strict=True).is_relative_to(folder), f"Symlink escapes bundle: {name}")
            actual_links.add(name)
        elif not path.is_dir():
            require(path.is_file(), f"Special file not allowed: {name}")
        if path.is_file() and not path.is_symlink():
            actual.add(name)
    require(actual_links == set(links), "Unverified or missing bundle symlinks")
    require(actual == set(artifacts) | {"build-manifest.json"},
            f"Artifact inventory differs: {sorted(actual ^ (set(artifacts) | {'build-manifest.json'}))}")
    for name, digest in artifacts.items():
        safe_name(name)
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), f"Invalid hash: {name}")
        path = folder / name
        require(path.is_file() and sha256(path) == digest, f"Artifact missing or changed: {name}")
    web_path = "Contents/Resources/web" if target == "macos" else "web"
    app_path = {"linux": "universal_hmi", "windows": "universal_hmi.exe",
                "macos": "Contents/MacOS/universal_hmi"}[target]
    server_path = {"linux": "universal-hmi-server", "windows": "universal-hmi-server.exe",
                   "macos": "Contents/MacOS/universal-hmi-server"}[target]
    for required in (app_path, server_path, f"{web_path}/index.html", f"{web_path}/main.dart.js",
                     f"{web_path}/build-manifest.json"):
        require(required in artifacts, f"Required payload missing: {required}")
        require((folder / required).stat().st_size > 0, f"Empty payload: {required}")
    web = read_json(folder / web_path / "build-manifest.json")
    require(web.get("mode") == "release" and web.get("target") == "web", "Invalid nested Web manifest")
    for key in ("git_revision", "source_sha256", "source_files"):
        require(web.get(key) == manifest.get(key), f"Desktop and Web {key} differ")
    web_artifacts = web.get("artifacts")
    require(isinstance(web_artifacts, dict) and web_artifacts, "Missing Web artifact hashes")
    expected_web = {f"{web_path}/{name}": digest for name, digest in web_artifacts.items()}
    for name in web_artifacts:
        safe_name(name)
    actual_web = {name: digest for name, digest in artifacts.items()
                  if name.startswith(web_path + "/") and name != f"{web_path}/build-manifest.json"}
    require(actual_web == expected_web, "Nested Web artifact inventory differs")
    return manifest


def product_version():
    text = (ROOT / "app/pubspec.yaml").read_text(encoding="utf-8")
    found = re.search(r"^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$", text, re.M)
    require(found is not None, "Unsupported pubspec version")
    return found.group(1) + ("+" + found.group(2) if found.group(2) else "")


def copy_payload(bundle, destination, target):
    shutil.copytree(bundle, destination, symlinks=True)
    if target == "linux":
        for path in destination.rglob("*"):
            path.chmod(0o755 if path.is_dir() else 0o644)
        for name in ("universal_hmi", "universal-hmi-server"):
            (destination / name).chmod(0o755)
    elif target == "macos":
        for name in ("universal_hmi", "universal-hmi-server"):
            (destination / "Contents/MacOS" / name).chmod(0o755)


def write_executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    path.chmod(0o755)


def build_linux(bundle, output, manifest, version):
    require(platform.system() == "Linux", "Linux installers require a Linux build host")
    tool = shutil.which("dpkg-deb")
    require(tool is not None, "dpkg-deb is required")
    deb = output / "universal-hmi-linux-x64.deb"
    pyz = output / "universal-hmi-linux-x64.install.pyz"
    with tempfile.TemporaryDirectory(prefix="hmi-linux-", dir=output) as temporary:
        root = Path(temporary)
        package = root / "deb"
        copy_payload(bundle, package / "opt/universal-hmi", "linux")
        control = package / "DEBIAN"
        control.mkdir()
        installed_kib = (sum(p.stat().st_size for p in package.rglob("*") if p.is_file()) + 1023) // 1024
        (control / "control").write_text(
            f"Package: universal-hmi\nVersion: {version}\nArchitecture: amd64\n"
            "Maintainer: Universal HMI maintainers\nSection: science\nPriority: optional\n"
            f"Installed-Size: {installed_kib}\n"
            "Depends: libc6 (>= 2.39), libgtk-3-0, libglib2.0-0, libstdc++6, libgcc-s1, liblzma5, libegl1\n"
            "Homepage: https://github.com/YufeiSun5/universal-hmi\n"
            "Description: Universal HMI desktop and local Web workspace\n"
            " Includes the Go backend and offline Flutter Web assets. No service is enabled.\n",
            encoding="utf-8")
        write_executable(package / "usr/bin/universal-hmi",
                         '#!/bin/sh\nexec /opt/universal-hmi/universal_hmi "$@"\n')
        applications = package / "usr/share/applications"
        applications.mkdir(parents=True)
        shutil.copy2(PACKAGING / "universal-hmi.desktop", applications)
        icons = package / "usr/share/icons/hicolor/scalable/apps"
        icons.mkdir(parents=True)
        shutil.copy2(PACKAGING / "universal-hmi.svg", icons)
        docs = package / "usr/share/doc/universal-hmi"
        docs.mkdir(parents=True)
        shutil.copy2(PACKAGING / "README.txt", docs)
        subprocess.run([tool, "--root-owner-group", "--build", str(package), str(deb)], check=True)
        subprocess.run([tool, "--info", str(deb)], check=True)
        ziproot = root / "rootless"
        copy_payload(bundle, ziproot / "payload", "linux")
        shutil.copy2(PACKAGING / "linux_user_installer.py", ziproot / "__main__.py")
        payload_hashes = {path.relative_to(ziproot / "payload").as_posix(): sha256(path)
                          for path in (ziproot / "payload").rglob("*") if path.is_file()}
        (ziproot / "payload-hashes.json").write_text(json.dumps(payload_hashes, sort_keys=True) + "\n", encoding="utf-8")
        zipapp.create_archive(ziproot, pyz, interpreter="/usr/bin/env python3", compressed=True)
        pyz.chmod(0o755)
    return [deb, pyz]


def find_iscc(explicit=None):
    candidates = [explicit, shutil.which("ISCC.exe"), shutil.which("iscc")]
    for variable in ("ProgramFiles(x86)", "ProgramFiles"):
        if os.environ.get(variable):
            candidates.append(str(Path(os.environ[variable]) / "Inno Setup 6/ISCC.exe"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise ValueError("Installed Inno Setup 6 ISCC.exe is required; pass --iscc if not on PATH")


def build_windows(bundle, output, manifest, version, iscc=None):
    require(platform.system() == "Windows", "Windows installer requires a Windows build host")
    compiler = find_iscc(iscc)
    # The source identity gives upgrades a separate immutable application payload.
    # Inno's own uninstall log only removes installer-owned files, never app data.
    identifier = manifest["source_sha256"][:24]
    subprocess.run([str(compiler), "/Qp", f"/DBundleDir={bundle}", f"/DOutputDir={output}",
                    f"/DProductVersion={version.split('+')[0]}",
                    f"/DProductFileVersion={version.replace('+', '.')}",
                    f"/DPayloadId={identifier}", str(PACKAGING / "windows.iss")], check=True)
    return [output / "universal-hmi-windows-x64-setup.exe"]


def build_macos(bundle, output, manifest, version):
    require(platform.system() == "Darwin", "macOS installer requires a macOS build host")
    tool = shutil.which("hdiutil")
    require(tool is not None, "Apple hdiutil is required")
    dmg = output / "universal-hmi-macos-universal.dmg"
    with tempfile.TemporaryDirectory(prefix="hmi-macos-", dir=output) as temporary:
        volume = Path(temporary) / "volume"
        volume.mkdir()
        app = volume / "Universal HMI.app"
        copy_payload(bundle, app, "macos")
        verify_bundle(app, "macos", manifest["git_revision"])
        (volume / "Applications").symlink_to("/Applications", target_is_directory=True)
        shutil.copy2(PACKAGING / "README.txt", volume / "READ ME FIRST.txt")
        subprocess.run([tool, "create", "-volname", "Universal HMI", "-srcfolder", str(volume),
                        "-format", "UDZO", "-ov", str(dmg)], check=True)
        subprocess.run([tool, "verify", str(dmg)], check=True)
    return [dmg]


def build(target, bundle, output, expected_revision=None, iscc=None):
    require(target in TARGETS, "Unsupported installer target")
    bundle, output = Path(bundle).resolve(), Path(output).resolve()
    require(not output.is_relative_to(bundle), "Installer output cannot be inside the bundle")
    manifest = verify_bundle(bundle, target, expected_revision)
    output.mkdir(parents=True, exist_ok=True)
    version = product_version()
    # Native tools write only temporary outputs; failed builds cannot replace a
    # previously good installer or its integrity record.
    with tempfile.TemporaryDirectory(prefix=".installers-", dir=output) as temporary:
        staging = Path(temporary)
        if target == "linux":
            files = build_linux(bundle, staging, manifest, version)
        elif target == "windows":
            files = build_windows(bundle, staging, manifest, version, iscc)
        else:
            files = build_macos(bundle, staging, manifest, version)
        hashes = {}
        for path in files:
            require(path.is_file() and path.stat().st_size > 0, f"Installer not produced: {path.name}")
            hashes[path.name] = sha256(path)
        evidence = {
            "schema": 1, "target": target, "version": version,
            "git_revision": manifest["git_revision"], "source_sha256": manifest["source_sha256"],
            "bundle_manifest_sha256": sha256(bundle / "build-manifest.json"),
            "package_contains_web": True, "signed": False, "artifacts": hashes,
        }
        record = staging / f"installer-manifest-{target}.json"
        record.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        checksums = staging / f"SHA256SUMS-{target}"
        checksums.write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(hashes.items())), encoding="utf-8")
        # Recheck after packaging so concurrent input changes never get certified.
        verify_bundle(bundle, target, expected_revision)
        for path in [*files, record, checksums]:
            os.replace(path, output / path.name)
    print(f"PASS: {target} installers verified and written to {output}")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/installers")
    parser.add_argument("--expected-revision")
    parser.add_argument("--iscc", type=Path, help="Existing official Inno Setup compiler")
    args = parser.parse_args()
    expected = args.expected_revision or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    build(args.target, args.bundle or ROOT / "dist" / args.target, args.output, expected, args.iscc)


if __name__ == "__main__":
    main()

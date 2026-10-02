"""Self-contained, offline user-directory installer. Requires Python 3.9+."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile

STATE = ".universal-hmi-install.json"
PRODUCT = "universal-hmi"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_relative(name):
    require(isinstance(name, str) and name and "\\" not in name and ":" not in name and "\x00" not in name,
            "Invalid inventory path")
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts and str(path) == name,
            "Invalid inventory path")
    return path


def inventory(root):
    result = {}
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"Refusing symlink: {path}")
        if path.is_dir():
            continue
        require(path.is_file(), f"Refusing special file: {path}")
        if path.relative_to(root).as_posix() != STATE:
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def check_installed(prefix):
    require(prefix.is_dir() and not prefix.is_symlink(), "Install directory is not a regular directory")
    state = prefix / STATE
    require(state.is_file() and not state.is_symlink(), "Directory is not a managed Universal HMI install")
    manifest = json.loads(state.read_text(encoding="utf-8"))
    require(manifest.get("schema") == 1 and manifest.get("product") == PRODUCT,
            "Invalid install ownership record")
    files = manifest.get("files")
    require(isinstance(files, dict) and files, "Invalid install file inventory")
    for name in files:
        safe_relative(name)
    require(inventory(prefix) == files,
            "Installed files were changed or added; back them up before update/uninstall. Nothing was removed")
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            try:
                executable = (entry / "exe").resolve(strict=True)
            except (OSError, RuntimeError):
                continue
            require(prefix not in executable.parents,
                    "Close Universal HMI and its backend before update/uninstall. No process was stopped")
    return manifest


def prepare_payload(archive_path, stage):
    """Extract only expected files, never links, devices, or arbitrary ZIP paths."""
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos if not info.is_dir()]
        require(len(names) == len(set(names)), "Duplicate archive entry")
        require("payload-hashes.json" in names and "__main__.py" in names, "Invalid installer archive")
        hashes = json.loads(archive.read("payload-hashes.json"))
        require(isinstance(hashes, dict) and hashes, "Invalid payload hash inventory")
        expected = {"payload/" + name for name in hashes} | {"__main__.py", "payload-hashes.json"}
        require(set(names) == expected, "Unexpected or missing installer entry")
        for name in hashes:
            safe_relative(name)
        for info in infos:
            relative = info.filename.rstrip("/")
            safe_relative(relative)
            mode_type = (info.external_attr >> 16) & 0o170000
            require(mode_type in (0, 0o040000, 0o100000), "Archive contains symlink or special file")
            if info.is_dir():
                continue
            if info.filename.startswith("payload/"):
                name = info.filename[len("payload/"):]
                target = stage / "app" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                require(digest(target) == hashes[name], f"Payload hash mismatch: {name}")
                target.chmod(0o755 if name in ("universal_hmi", "universal-hmi-server") else 0o644)
        manifest = json.loads((stage / "app/build-manifest.json").read_text(encoding="utf-8"))
        require(manifest.get("mode") == "release" and manifest.get("target") == "linux"
                and manifest.get("package_contains_web") is True, "Payload is not a Linux+Web release")
        require(manifest.get("artifacts") == {name: value for name, value in hashes.items()
                                             if name != "build-manifest.json"}, "Payload manifest inventory differs")
        for name in ("universal_hmi", "universal-hmi-server", "web/index.html", "web/main.dart.js",
                     "web/build-manifest.json"):
            require(name in hashes, f"Required payload missing: {name}")
        (stage / "manage-install.py").write_bytes(archive.read("__main__.py"))
    return manifest


def write_launcher(path, body):
    path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
    path.chmod(0o755)


def install(archive_path, prefix):
    if prefix.exists():
        check_installed(prefix)
    with tempfile.TemporaryDirectory(prefix=".hmi-install-", dir=prefix.parent) as temporary:
        workspace = Path(temporary)
        stage = workspace / "new"
        stage.mkdir(mode=0o755)
        manifest = prepare_payload(archive_path, stage)
        # Resolve at launch rather than baking a path into a shell command. A
        # moved installation still works; no PATH, login file or menu is changed.
        write_launcher(stage / "launch-universal-hmi",
                       'HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                       'exec "$HERE/app/universal_hmi" "$@"\n')
        write_launcher(stage / "uninstall-universal-hmi",
                       'HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                       'exec python3 "$HERE/manage-install.py" --uninstall --prefix "$HERE" "$@"\n')
        state = {"schema": 1, "product": PRODUCT, "git_revision": manifest["git_revision"],
                 "source_sha256": manifest["source_sha256"], "files": inventory(stage)}
        (stage / STATE).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        backup = workspace / "previous"
        moved = False
        try:
            if prefix.exists():
                # Verify again immediately before moving the previous install.
                check_installed(prefix)
                os.replace(prefix, backup)
                moved = True
            os.replace(stage, prefix)
        except BaseException:
            if moved and not prefix.exists():
                os.replace(backup, prefix)
            raise
    print(f"Installed Universal HMI in {prefix}")
    print(f"Launch: {prefix / 'launch-universal-hmi'}")
    print("Web while running: http://127.0.0.1:18080; personal data was not changed")


def uninstall(prefix):
    check_installed(prefix)
    # Only the verified install-owned tree is removed. Runtime data lives outside
    # this tree; unknown files above made check_installed fail without deletion.
    shutil.rmtree(prefix)
    print(f"Uninstalled Universal HMI from {prefix}; personal data was kept")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local/opt/universal-hmi")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    require(args.prefix.is_absolute(), "--prefix must be an absolute path")
    require(not args.prefix.is_symlink(), "Install directory cannot be a symlink")
    prefix = args.prefix.resolve()
    require(prefix != Path(prefix.anchor) and prefix != Path.home().resolve(), "Unsafe install directory")
    require(not any(character in str(prefix) for character in ("\n", "\r", "\x00")), "Invalid install directory")
    prefix.parent.mkdir(parents=True, exist_ok=True)
    lock = prefix.parent / ("." + prefix.name + ".install-lock")
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError(f"Another install may be active; lock exists: {lock}") from error
    try:
        if args.uninstall:
            uninstall(prefix)
        else:
            archive = Path(sys.argv[0]).resolve()
            require(zipfile.is_zipfile(archive), "Use the downloaded .install.pyz to install or update")
            require(prefix not in archive.parents, "Run the installer from outside the install directory")
            install(archive, prefix)
    finally:
        lock.rmdir()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        print(f"Installation stopped: {error}", file=sys.stderr)
        sys.exit(1)

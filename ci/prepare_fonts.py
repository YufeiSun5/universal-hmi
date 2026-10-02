"""Prepare byte-identical offline fonts before Flutter dependency resolution/builds.

Requires Python 3.10+. Existing files are verified and never silently replaced.
For a fresh checkout: python -m pip install -r ci/requirements-fonts.txt
Then: python ci/prepare_fonts.py
"""
from __future__ import annotations

import argparse
import hashlib
from importlib import metadata
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = Path(__file__).with_name("fonts.lock.json")
CHUNK_SIZE = 64 * 1024
SOCKET_TIMEOUT = 30
DOWNLOAD_TIMEOUT = 120


class FontPreparationError(RuntimeError):
    """A pinned input or output could not be verified."""


def verify_file(path, expected):
    """Reject unexpected content rather than repairing an existing asset silently."""
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise FontPreparationError(f"Expected a regular file: {path}")
    if path.stat().st_size != expected["bytes"]:
        raise FontPreparationError(f"Size mismatch for {path}; expected {expected['bytes']} bytes")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK_SIZE), b""):
            digest.update(block)
    if digest.hexdigest() != expected["sha256"]:
        raise FontPreparationError(f"SHA256 mismatch for {path}; existing assets are not replaced")


def download(source, destination):
    """Fetch a fixed HTTPS input with bounded time/size and mandatory SHA256."""
    url = source["url"]
    if urllib.parse.urlparse(url).scheme != "https":
        raise FontPreparationError("Font input URLs must use HTTPS")
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    request = urllib.request.Request(url, headers={"User-Agent": "UniversalHMI-font-preparation/1"})
    with urllib.request.urlopen(request, timeout=SOCKET_TIMEOUT) as response:
        if urllib.parse.urlparse(response.geturl()).scheme != "https":
            raise FontPreparationError("Font download redirected away from HTTPS")
        length = response.headers.get("Content-Length")
        if length is not None and int(length) != source["bytes"]:
            raise FontPreparationError(f"Unexpected Content-Length for {url}")
        size = 0
        with Path(destination).open("wb") as stream:
            while True:
                if time.monotonic() >= deadline:
                    raise FontPreparationError(f"Font download exceeded {DOWNLOAD_TIMEOUT} seconds: {url}")
                block = response.read(CHUNK_SIZE)
                if not block:
                    break
                size += len(block)
                if size > source["bytes"]:
                    raise FontPreparationError(f"Font download exceeds pinned size: {url}")
                stream.write(block)
    verify_file(destination, source)


def require_fonttools(version):
    try:
        installed = metadata.version("fonttools")
    except metadata.PackageNotFoundError:
        installed = "not installed"
    if installed != version:
        raise FontPreparationError(
            f"fonttools {version} is required (found {installed}); "
            "run: python -m pip install -r ci/requirements-fonts.txt"
        )


def materialize(source_path, destination, spec):
    if spec["format"] == "ttc-face":
        from fontTools.ttLib import TTFont

        with TTFont(source_path, fontNumber=spec["face_index"], recalcTimestamp=False) as font:
            # Preserve the timestamp of the already-tested release asset exactly.
            font["head"].modified = spec["head_modified"]
            font.save(destination)
    elif spec["format"] == "zip-member":
        with zipfile.ZipFile(source_path) as archive:
            member = archive.getinfo(spec["member"])
            if member.file_size != spec["bytes"]:
                raise FontPreparationError(f"Unexpected uncompressed size for {spec['member']}")
            # Read only the named font; never extract arbitrary archive paths.
            with archive.open(member) as stream:
                content = stream.read(spec["bytes"] + 1)
            Path(destination).write_bytes(content)
    else:
        raise FontPreparationError(f"Unknown font recipe: {spec['format']}")
    verify_file(destination, spec)


def prepare_fonts(assets_dir, lock, *, check_only=False):
    assets_dir = Path(assets_dir)
    # Licenses are small, checked-in source files and must retain their exact bytes.
    for name, spec in lock["licenses"].items():
        verify_file(assets_dir / name, spec)
    missing = []
    for name, spec in lock["fonts"].items():
        path = assets_dir / name
        if path.exists() or path.is_symlink():
            verify_file(path, spec)
        else:
            missing.append((name, spec))
    if not missing:
        return []
    if check_only:
        raise FontPreparationError("Missing font assets: " + ", ".join(name for name, _ in missing))
    if any(spec["format"] == "ttc-face" for _, spec in missing):
        require_fonttools(lock["fonttools_version"])
    # Stage in the output filesystem for atomic replace on Linux and Windows.
    with tempfile.TemporaryDirectory(prefix=".prepare-fonts-", dir=assets_dir) as temporary:
        stage = Path(temporary)
        for name, spec in missing:
            source = stage / (name + ".source")
            download(spec["source"], source)
            materialize(source, stage / name, spec)
        # Validate all outputs before publishing any new font asset.
        for name, spec in missing:
            target = assets_dir / name
            if target.exists() or target.is_symlink():
                verify_file(target, spec)
            else:
                os.replace(stage / name, target)
    return [name for name, _ in missing]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify assets without downloading or changing files")
    parser.add_argument("--assets-dir", type=Path, default=ROOT / "app/assets/fonts")
    args = parser.parse_args()
    try:
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        if lock["schema"] != 1:
            raise FontPreparationError("Unsupported font lock schema")
        created = prepare_fonts(args.assets_dir, lock, check_only=args.check)
    except (OSError, ValueError, RuntimeError, KeyError, zipfile.BadZipFile) as error:
        print(f"Font preparation failed: {error}", file=sys.stderr)
        return 1
    print("PASS: pinned offline fonts verified" + ("; prepared " + ", ".join(created) if created else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

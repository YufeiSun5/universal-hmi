"""Assemble independently verified desktop and Web releases with artifact hashes."""
import argparse
import json
import shutil
import tarfile

from build_release import sha256
from common import ROOT


def main(targets=("linux", "windows")):
    web = ROOT / "dist/web"
    web_manifest = json.loads((web / "build-manifest.json").read_text())
    for target in targets:
        folder = ROOT / "dist" / target
        manifest_path = folder / "build-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        assert manifest["mode"] == "release" and web_manifest["mode"] == "release"
        assert manifest["git_revision"] == web_manifest["git_revision"], "Desktop and Web revisions differ"
        assert manifest["source_sha256"] == web_manifest["source_sha256"], "Desktop and Web source hashes differ"
        for name, expected in manifest["artifacts"].items():
            assert sha256(folder / name) == expected, f"Desktop artifact changed: {target}/{name}"
        if (folder / "web").exists():
            shutil.rmtree(folder / "web")
        shutil.copytree(web, folder / "web")
        manifest["artifacts"].update({path.relative_to(folder).as_posix(): sha256(path) for path in (folder / "web").rglob("*") if path.is_file()})
        manifest["package_contains_web"] = True
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    linux = ROOT / "dist/linux"
    for name in ("universal_hmi", "universal-hmi-server"):
        (linux / name).chmod(0o755)
    output = ROOT / "dist/final"
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / "universal-hmi-linux-x64.tar.gz"
    with tarfile.open(archive_path, "w:gz") as archive:
        archive.add(linux, arcname="universal-hmi")
    (output / "SHA256SUMS").write_text(f"{sha256(archive_path)}  {archive_path.name}\n")
    print("PASS: desktop/Web identities and artifact hashes verified; final packages assembled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", nargs="+", choices=("linux", "windows"), default=["linux", "windows"])
    main(tuple(parser.parse_args().targets))

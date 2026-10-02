"""Copy the backend into a verified desktop release and extend its manifest."""
import argparse
import json
import shutil

from build_release import BUILD_PATHS, artifact_inventory, require_universal_macos, sha256
from common import ROOT
from package_final import load_manifest, verify_artifacts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", choices=("linux", "windows", "macos"))
    args = parser.parse_args()
    bundle = ROOT / BUILD_PATHS[args.target]
    server = ROOT / "dist" / ("universal-hmi-server.exe" if args.target == "windows" else "universal-hmi-server")
    manifest_path = bundle / "build-manifest.json"
    manifest = load_manifest(bundle, args.target, "Desktop release")
    verify_artifacts(bundle, manifest, "Desktop release")
    assert server.is_file() and not server.is_symlink() and server.stat().st_size, f"Backend missing or invalid: {server}"
    backend_slices = require_universal_macos(server) if args.target == "macos" else None
    server_path = "Contents/MacOS/" + server.name if args.target == "macos" else server.name
    destination = bundle / server_path
    readme = bundle / ("Contents/Resources/README.txt" if args.target == "macos" else "README.txt")
    for path in (destination, readme):
        for parent in (path, *path.parents):
            if parent == bundle:
                break
            assert not parent.is_symlink(), f"Package destination is a symlink: {parent}"
    shutil.copy2(server, destination)
    if args.target != "windows":
        destination.chmod(0o755)
    readme.parent.mkdir(parents=True, exist_ok=True)
    readme.write_text("Universal HMI\nStart universal_hmi (Windows: universal_hmi.exe; macOS: open Universal HMI.app).\nThe bundled Go backend starts automatically on 127.0.0.1:18080.\nData: Linux $XDG_DATA_HOME/universal-hmi, Windows %LOCALAPPDATA%/universal-hmi, macOS ~/Library/Application Support/universal-hmi.\nA running compatible local backend is reused and is not stopped when this window closes.\nProduction sources require explicit connect.\nmacOS development packages are not developer-signed or notarized.\n", encoding="utf-8")
    manifest.update(artifact_inventory(bundle, allow_symlinks=args.target == "macos"))
    manifest["backend_sha256"] = sha256(destination)
    if backend_slices:
        manifest["backend_slice_sha256"] = backend_slices
        manifest.setdefault("macho_slice_sha256", {})[server_path] = backend_slices
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    verify_artifacts(bundle, manifest, "Desktop with backend")
    print(f"PASS: {args.target} desktop bundle includes backend SHA256 {manifest['artifacts'][server_path]}")


if __name__ == "__main__":
    main()

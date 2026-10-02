"""Copy the backend into a verified desktop release and extend its manifest."""
import argparse
import json
import shutil

from build_release import sha256
from common import ROOT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", choices=("linux", "windows"))
    args = parser.parse_args()
    bundle = ROOT / ("app/build/linux/x64/release/bundle" if args.target == "linux" else "app/build/windows/x64/runner/Release")
    server = ROOT / "dist" / ("universal-hmi-server" if args.target == "linux" else "universal-hmi-server.exe")
    manifest_path = bundle / "build-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert manifest["mode"] == "release" and manifest["target"] == args.target
    shutil.copy2(server, bundle / server.name)
    if args.target == "linux":
        (bundle / server.name).chmod(0o755)
    (bundle / "README.txt").write_text("Universal HMI\nStart universal_hmi (or universal_hmi.exe).\nThe bundled Go backend starts automatically on 127.0.0.1:18080.\nData: Linux $XDG_DATA_HOME/universal-hmi, Windows %LOCALAPPDATA%/universal-hmi.\nA running compatible local backend is reused and is not stopped when this window closes.\nProduction sources require explicit connect.\n", encoding="utf-8")
    manifest["artifacts"].update({server.name: sha256(bundle / server.name), "README.txt": sha256(bundle / "README.txt")})
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {args.target} desktop bundle includes backend SHA256 {manifest['artifacts'][server.name]}")


if __name__ == "__main__":
    main()

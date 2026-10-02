"""Copy the backend into a verified desktop release and extend its manifest."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

from build_release import BUILD_PATHS, artifact_inventory, require_universal_macos, sha256
from common import ROOT
from package_final import load_manifest, verify_artifacts


WINDOWS_CRT_REQUIRED = {"msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"}
WINDOWS_CRT_DOCUMENTATION = "https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution"


def require_windows(condition, message):
    if not condition:
        raise ValueError(message)


def require_amd64_pe(path):
    """Check native runtime DLL architecture without executing or loading it."""
    require_windows(path.is_file() and not path.is_symlink(), f"Runtime DLL missing or linked: {path.name}")
    size = path.stat().st_size
    with path.open("rb") as stream:
        dos = stream.read(64)
        require_windows(len(dos) == 64 and dos[:2] == b"MZ", f"Runtime DLL is not PE: {path.name}")
        offset = struct.unpack_from("<I", dos, 60)[0]
        require_windows(64 <= offset <= size - 26, f"Invalid PE header: {path.name}")
        stream.seek(offset)
        header = stream.read(26)
        require_windows(header[:4] == b"PE\x00\x00" and struct.unpack_from("<H", header, 4)[0] == 0x8664
                        and struct.unpack_from("<H", header, 24)[0] == 0x20B,
                        f"Runtime DLL is not AMD64 PE32+: {path.name}")


def locate_windows_crt(environment=None):
    """Use the active MSVC redist, otherwise the latest installed VS C++ redist.

    Only Microsoft's installed redistribution directory is read. No System32
    fallback, downloads, package installs, or debug_nonredist bytes are allowed.
    """
    environment = os.environ if environment is None else environment
    active = environment.get("VCToolsRedistDir")
    if active:
        redist = Path(active).resolve()
        require_windows(redist.parent.name.lower() == "msvc" and redist.parent.parent.name.lower() == "redist",
                        "VCToolsRedistDir must identify the installed VC/Redist/MSVC/version directory")
        candidates = [redist]
    else:
        vc = environment.get("VCINSTALLDIR")
        if vc:
            vc = Path(vc).resolve()
        else:
            program_files = environment.get("ProgramFiles(x86)", environment.get("ProgramFiles"))
            require_windows(program_files, "Cannot locate Microsoft's installed vswhere.exe")
            vswhere = Path(program_files) / "Microsoft Visual Studio/Installer/vswhere.exe"
            require_windows(vswhere.is_file(), "Microsoft's installed vswhere.exe is required")
            result = subprocess.check_output([
                str(vswhere), "-latest", "-products", "*", "-requires",
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"
            ], text=True, encoding="utf-8").strip().splitlines()
            require_windows(len(result) == 1 and result[0].strip(), "No unambiguous installed Visual Studio C++ toolset")
            vc = Path(result[0].strip()) / "VC"
        root = vc / "Redist/MSVC"
        require_windows(root.is_dir(), "Installed Visual Studio C++ redistributable directory is missing")
        candidates = [path for path in root.iterdir()
                      if path.is_dir() and re.fullmatch(r"\d+(?:\.\d+){2,3}", path.name)]
        candidates.sort(key=lambda path: tuple(int(part) for part in path.name.split(".")), reverse=True)
    require_windows(candidates, "No installed release MSVC redistributable version")
    for redist in candidates:
        crt = redist / "x64/Microsoft.VC143.CRT"
        if crt.is_dir():
            require_windows(not any("debug" in part.lower() for part in crt.parts), "Debug runtime cannot be redistributed")
            return crt, redist.name
    raise ValueError("Installed x64 Microsoft.VC143.CRT release redistributable is missing")


def prepare_windows_runtime(bundle, environment=None):
    """Validate all source and existing destination bytes before mutating bundle."""
    directory, version = locate_windows_crt(environment)
    files = {}
    for path in sorted(directory.iterdir()):
        if path.suffix.lower() != ".dll":
            continue
        name = path.name.lower()
        require_windows(name not in files and not name.endswith("d.dll"), "Duplicate or debug MSVC runtime DLL")
        require_amd64_pe(path)
        files[name] = (path, sha256(path))
    require_windows(WINDOWS_CRT_REQUIRED <= files.keys(), "Required release VC++ runtime DLLs are missing")
    existing = {path.name.lower(): path for path in bundle.iterdir()}
    for name, (_, digest) in files.items():
        if name in existing:
            destination = existing[name]
            require_windows(destination.name == name and not destination.is_symlink()
                            and destination.is_file() and sha256(destination) == digest,
                            f"Conflicting existing VC++ runtime DLL: {name}; rebuild a clean release")
    return files, {"architecture": "x64", "version": version,
                   "source": f"Visual Studio/VC/Redist/MSVC/{version}/x64/Microsoft.VC143.CRT",
                   "redistribution": WINDOWS_CRT_DOCUMENTATION,
                   "files": {name: digest for name, (_, digest) in files.items()}}


def verify_windows_runtime(bundle, manifest):
    """Do not certify a Windows installer that relies on the build host's CRT."""
    runtime = manifest.get("windows_vc_runtime")
    require_windows(isinstance(runtime, dict) and runtime.get("architecture") == "x64",
                    "Windows bundle lacks app-local VC++ runtime provenance")
    version = runtime.get("version")
    require_windows(isinstance(version, str) and re.fullmatch(r"(?:\d+(?:\.\d+){2,3}|v143)", version),
                    "Invalid VC++ runtime version")
    require_windows(runtime.get("source") == f"Visual Studio/VC/Redist/MSVC/{version}/x64/Microsoft.VC143.CRT",
                    "Invalid VC++ runtime redistribution origin")
    files = runtime.get("files")
    require_windows(isinstance(files, dict) and WINDOWS_CRT_REQUIRED <= files.keys(),
                    "Required app-local VC++ runtime DLLs are missing")
    for name, expected in files.items():
        require_windows(isinstance(name, str) and re.fullmatch(r"[a-z0-9_]+\.dll", name)
                        and not name.endswith("d.dll"), "Invalid or debug VC++ runtime DLL")
        path = bundle / name
        require_amd64_pe(path)
        require_windows(manifest.get("artifacts", {}).get(name) == expected and sha256(path) == expected,
                        f"App-local VC++ runtime hash differs: {name}")
    return runtime


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
    runtime_files, runtime = prepare_windows_runtime(bundle) if args.target == "windows" else ({}, None)
    server_path = "Contents/MacOS/" + server.name if args.target == "macos" else server.name
    destination = bundle / server_path
    readme = bundle / ("Contents/Resources/README.txt" if args.target == "macos" else "README.txt")
    for path in (destination, readme):
        for parent in (path, *path.parents):
            if parent == bundle:
                break
            assert not parent.is_symlink(), f"Package destination is a symlink: {parent}"
    for name, (source, _) in runtime_files.items():
        shutil.copy2(source, bundle / name)
    shutil.copy2(server, destination)
    if args.target != "windows":
        destination.chmod(0o755)
    readme.parent.mkdir(parents=True, exist_ok=True)
    readme.write_text("Universal HMI\nStart universal_hmi (Windows: universal_hmi.exe; macOS: open Universal HMI.app).\nThe bundled Go backend starts automatically on 127.0.0.1:18080.\nData: Linux $XDG_DATA_HOME/universal-hmi, Windows %LOCALAPPDATA%/universal-hmi, macOS ~/Library/Application Support/universal-hmi.\nA running compatible local backend is reused and is not stopped when this window closes.\nProduction sources require explicit connect.\nmacOS development packages are not developer-signed or notarized.\n", encoding="utf-8")
    manifest.update(artifact_inventory(bundle, allow_symlinks=args.target == "macos"))
    manifest["backend_sha256"] = sha256(destination)
    if runtime:
        manifest["windows_vc_runtime"] = runtime
        verify_windows_runtime(bundle, manifest)
    if backend_slices:
        manifest["backend_slice_sha256"] = backend_slices
        manifest.setdefault("macho_slice_sha256", {})[server_path] = backend_slices
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    verify_artifacts(bundle, manifest, "Desktop with backend")
    print(f"PASS: {args.target} desktop bundle includes backend SHA256 {manifest['artifacts'][server_path]}")


if __name__ == "__main__":
    main()

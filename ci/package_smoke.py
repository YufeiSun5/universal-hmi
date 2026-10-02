"""Verify an assembled Linux release, owned sidecar close, and reused sidecar close.

Use --display :N on an existing desktop. --xvfb is only for an isolated CI runner.
All logs and lifecycle evidence are preserved, including on failure.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

from build_release import sha256
from common import ROOT, display_environment, health, port_available, request, stop, wait_for


def close_window(window, env):
    # WM_DELETE_WINDOW is the same GTK close request as the window close button;
    # unlike killing the process, it exercises AppLifecycleListener onExitRequested.
    x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    class Data(ctypes.Union):
        _fields_ = [("b", ctypes.c_char * 20), ("s", ctypes.c_short * 10), ("l", ctypes.c_long * 5)]
    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int), ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong), ("format", ctypes.c_int), ("data", Data)]
    class Event(ctypes.Union):
        _fields_ = [("client", ClientMessage), ("pad", ctypes.c_long * 24)]
    display = x11.XOpenDisplay(env["DISPLAY"].encode())
    assert display, "Cannot open selected desktop"
    try:
        event = Event()
        event.client.type = 33
        event.client.display = display
        event.client.window = int(window)
        event.client.message_type = x11.XInternAtom(display, b"WM_PROTOCOLS", 0)
        event.client.format = 32
        event.client.data.l[0] = x11.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
        event.client.data.l[1] = 0
        x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(Event)]
        assert x11.XSendEvent(display, int(window), 0, 0, ctypes.byref(event)) != 0
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay(display)


def window_for(process, env):
    def find():
        result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(process.pid)], env=env, text=True, capture_output=True)
        return result.stdout.strip().splitlines()[-1] if result.returncode == 0 and result.stdout.strip() else None
    return wait_for(find, description="packaged application window")


def child_backend_pid(parent_pid, executable, proc_root=Path('/proc')):
    """PPid is portable across procfs builds; task/*/children is optional."""
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            status = dict(line.split(':', 1) for line in (entry / 'status').read_text().splitlines() if ':' in line)
            if int(status.get('PPid', '-1').strip()) == parent_pid and (entry / 'exe').resolve() == executable:
                return int(entry.name)
        except (OSError, ValueError):
            continue
    return None


def wait_for_desktop_exit(process, log_path, evidence, scenario, timeout=15):
    """Preserve a failed exit and require engine teardown before process exit."""
    outcome = {"scenario": scenario, "pid": process.pid, "log": log_path.name}
    evidence.setdefault("desktop_exits", []).append(outcome)
    started = time.monotonic()
    try:
        outcome["exit_code"] = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        outcome["timed_out"] = True
        raise AssertionError(f"{scenario}: desktop did not close within {timeout}s; see {log_path.name}") from error
    finally:
        outcome["close_wait_ms"] = round((time.monotonic() - started) * 1000, 3)
    assert outcome["exit_code"] == 0, f"{scenario}: desktop exited with code {outcome['exit_code']}; see {log_path.name}"
    log = log_path.read_text()
    disposed = log.find("HMI lifecycle: engine disposed")
    shutdown = log.find("HMI lifecycle: application shutdown complete")
    outcome["engine_disposed_before_shutdown"] = 0 <= disposed < shutdown
    assert outcome["engine_disposed_before_shutdown"], f"{scenario}: engine outlived application shutdown; see {log_path.name}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / "dist/linux")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/package-evidence")
    parser.add_argument("--display")
    parser.add_argument("--xvfb", action="store_true")
    parser.add_argument("--review-close", action="store_true", help="Wait for operator CUA normal close; no scripted window actions")
    parser.add_argument("--reuse-close-attempts", type=int, default=10, help="Immediate visible-window close repetitions (operator review uses one)")
    args = parser.parse_args()
    if args.reuse_close_attempts < 1:
        parser.error("--reuse-close-attempts must be positive")
    args.bundle = args.bundle.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    base = "http://127.0.0.1:18080"
    assert port_available(18080), "Port 18080 already in use; package test requires its own backend and must not mutate yours"
    manifest = json.loads((args.bundle / "build-manifest.json").read_text())
    assert manifest["mode"] == "release" and manifest["target"] == "linux"
    assert manifest["bundled_engine_sha256"] == manifest["official_engine_sha256"]
    assert sha256(args.bundle / "lib/libflutter_linux_gtk.so") == manifest["official_engine_sha256"]
    assert sha256(args.bundle / "lib/libapp.so") == manifest["aot_sha256"]
    for name, digest in manifest["artifacts"].items():
        assert sha256(args.bundle / name) == digest, f"Artifact hash mismatch: {name}"
    evidence = {"source_sha256": manifest["source_sha256"], "git_revision": manifest["git_revision"], "release_engine_verified": True, "aot_verified": True, "checks": {}}
    app = backend = None
    owned_pid = None
    try:
        with tempfile.TemporaryDirectory(prefix="hmi-package-") as data, display_environment(args.display, args.xvfb) as display_env:
            env = dict(display_env, XDG_DATA_HOME=data, HMI_LIFECYCLE_TRACE="1")
            with (args.output / "owned-desktop.log").open("w") as log:
                app = subprocess.Popen([str(args.bundle / "universal_hmi")], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            ready = wait_for(lambda: health(base) if app.poll() is None else None, description="automatic sidecar with verified health identity")
            assert app.poll() is None, f"Desktop exited after health with code {app.returncode}; see owned-desktop.log"
            owned_pid = child_backend_pid(app.pid, args.bundle / "universal-hmi-server")
            assert owned_pid is not None, "Automatic backend is not a child of the packaged desktop"
            evidence["owned_backend_pid"] = owned_pid
            evidence["health"] = ready
            for path, expected in (("/", b"flutter_bootstrap.js"), ("/flutter_bootstrap.js", b"flutter")):
                with urllib.request.urlopen(base + path, timeout=5) as response:
                    assert response.status == 200 and expected in response.read(), f"Bundled Web asset missing: {path}"
            request(base, "POST", "/api/v1/demo", {"enabled": True})
            request(base, "PUT", "/api/v1/storage", {"enabled": True, "interval_ms": 1000, "changed_only": False, "retention_days": 30, "point_ids": []})
            wait_for(lambda: len(request(base, "GET", "/api/v1/runtime")["values"]) == 90, description="demo values in packaged app")
            wait_for(lambda: (Path(data) / "universal-hmi/history.db").is_file(), description="independent history store")
            history = wait_for(lambda: (value if (value := request(base, "GET", "/api/v1/history?limit=1")).get("stats", {}).get("count", 0) > 0 else None), description="independent persisted history rows")
            evidence["history_count"] = history["stats"]["count"]
            if args.review_close:
                print("REVIEW_READY: inspect native release and close normally via CUA (10 minute limit)", flush=True)
            else:
                window = window_for(app, env)
                subprocess.run(["import", "-window", window, str(args.output / "packaged-desktop.png")], env=env, check=True)
                close_window(window, env)
            wait_for_desktop_exit(app, args.output / "owned-desktop.log", evidence, "owned", timeout=600 if args.review_close else 15)
            wait_for(lambda: port_available(18080), timeout=10, description="owned backend stopped after normal close")
            evidence["checks"]["owned_backend_stops_on_window_close"] = True
            with (args.output / "reused-backend.log").open("w") as log:
                backend = subprocess.Popen([str(args.bundle / "universal-hmi-server"), "--data-dir", str(Path(data) / "reused"), "--web-dir", str(args.bundle / "web")], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            wait_for(lambda: health(base), description="existing compatible backend")
            attempts = 1 if args.review_close else args.reuse_close_attempts
            evidence["reused_close_attempts"] = attempts
            for attempt in range(1, attempts + 1):
                log_path = args.output / f"reused-desktop-{attempt:02d}.log"
                with log_path.open("w") as log:
                    app = subprocess.Popen([str(args.bundle / "universal_hmi")], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                if args.review_close:
                    print("REUSE_READY: close the second window normally via CUA; existing backend must survive", flush=True)
                else:
                    # Close as soon as a real window is visible. Do not add a
                    # startup sleep: this is the fast-exit teardown regression.
                    window = window_for(app, env)
                    close_window(window, env)
                wait_for_desktop_exit(app, log_path, evidence, f"reused-{attempt}", timeout=600 if args.review_close else 15)
                assert backend.poll() is None, f"Reused backend exited after desktop close {attempt}"
                health(base)
            evidence["checks"]["reused_backend_survives_window_close"] = True
            evidence["checks"]["same_origin_web_and_independent_history"] = True
            print("PASS: verified release/AOT + automatic backend + same-origin Web + owned/reused normal-close lifecycle")
    finally:
        if app is not None:
            try:
                os.killpg(app.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        stop(app)
        stop(backend)
        if owned_pid is not None:
            try:
                if Path(f"/proc/{owned_pid}/exe").resolve() == args.bundle / "universal-hmi-server":
                    os.kill(owned_pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
        (args.output / "package-smoke.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()

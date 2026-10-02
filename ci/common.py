"""Small process/HTTP helpers for local-only acceptance fixtures."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def request(base, method, path, body=None, timeout=30):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(base + path, data, {"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{method} {path}: HTTP {error.code}: {error.read().decode()}") from error


def wait_for(predicate, *, timeout=20, description="condition"):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ValueError, RuntimeError) as error:
            last_error = error
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {description}; last error: {last_error}")


def health(base):
    result = request(base, "GET", "/health", timeout=2)
    assert result.get("status") == "ok" and result.get("service") == "universal-hmi", result
    return result


def port_available(port):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def stop(process, timeout=10):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


@contextlib.contextmanager
def display_environment(display=None, xvfb=False):
    """Never replace an existing desktop; Xvfb is explicit and privately owned."""
    if display:
        if xvfb:
            raise ValueError("Choose --display or --xvfb, not both")
        yield dict(os.environ, DISPLAY=display)
        return
    if not xvfb:
        existing = os.environ.get("DISPLAY")
        if not existing:
            raise RuntimeError("Provide --display for your existing desktop, or --xvfb on an isolated CI runner")
        yield dict(os.environ)
        return
    number = next((n for n in range(90, 120) if not Path(f"/tmp/.X11-unix/X{n}").exists()), None)
    if number is None:
        raise RuntimeError("No unused private X display")
    proc = subprocess.Popen(["Xvfb", f":{number}", "-screen", "0", "1440x900x24", "-nolisten", "tcp"])
    try:
        wait_for(lambda: Path(f"/tmp/.X11-unix/X{number}").exists(), description="private Xvfb")
        yield dict(os.environ, DISPLAY=f":{number}")
    finally:
        stop(proc)

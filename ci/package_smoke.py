"""Launch the assembled Linux desktop bundle and verify its automatic backend and Web assets."""
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import urllib.request

root = pathlib.Path.cwd()
base = "http://127.0.0.1:18080"
def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)

with tempfile.TemporaryDirectory(prefix="hmi-package-") as data:
    display = subprocess.Popen(["Xvfb", ":98", "-screen", "0", "1280x720x24"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = None
    try:
        time.sleep(.5)
        env = dict(os.environ, DISPLAY=":98", XDG_DATA_HOME=data)
        app = subprocess.Popen([str(root / "dist/linux/universal_hmi")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 15
        ready = False
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError("Packaged desktop exited before becoming ready")
            try:
                ready = request("/health")["status"] == "ok"
                if ready:
                    break
            except Exception:
                time.sleep(.2)
        assert ready, "Bundled backend did not start automatically"
        with urllib.request.urlopen(base + "/", timeout=5) as response:
            assert b"flutter_bootstrap.js" in response.read(), "Bundled Web page missing"
        with urllib.request.urlopen(base + "/flutter_bootstrap.js", timeout=5) as response:
            assert response.status == 200 and len(response.read()) > 100
        request("/api/v1/demo", {"enabled": True})
        request("/api/v1/storage", {"enabled": True, "interval_ms": 1000, "changed_only": False, "retention_days": 30, "point_ids": []})
        time.sleep(1.5)
        runtime = request("/api/v1/runtime")
        assert len(runtime["values"]) == 90 and runtime["demo"] is True
        assert (pathlib.Path(data) / "universal-hmi/history.db").is_file()
        print("PASS: final Linux release bundle -> automatic Go sidecar -> same-origin Flutter Web -> 30 stations/90 values -> independent storage")
    finally:
        if app is not None:
            try:
                os.killpg(app.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            app.wait(timeout=10)
        display.terminate()
        display.wait(timeout=10)

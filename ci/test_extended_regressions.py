"""Executable HTTP regression contracts against isolated synthetic local data.

Run with HMI_QA_SERVER=/absolute/path/to/universal-hmi-server python3 -m unittest
discover -s ci -p test_extended_regressions.py -v. These tests use a real server
process and temporary state, not a deployed account or physical device. They
complement in-process Go tests with restart, HTTP and configured capacity checks.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

from common import ROOT, stop, wait_for


class ExecutableContracts(unittest.TestCase):
    def setUp(self):
        self.server = Path(os.environ.get("HMI_QA_SERVER", ROOT / "dist/universal-hmi-server")).resolve()
        self.assertTrue(self.server.is_file(), f"Build server first: {self.server}")
        self.temporary = tempfile.TemporaryDirectory(prefix="hmi-extended-regressions-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = self.root / "data"
        self.log = (self.root / "server.log").open("a+")
        self.addCleanup(self.log.close)
        self.process = None
        self.addCleanup(lambda: stop(self.process))
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.start()

    def start(self, *flags):
        self.process = subprocess.Popen([
            str(self.server), "--listen", f"127.0.0.1:{self.port}",
            "--data-dir", str(self.data), *flags,
        ], stdout=self.log, stderr=subprocess.STDOUT)
        wait_for(lambda: self.api("GET", "/health")["status"] == "ok", description="isolated QA server")

    def exchange(self, method, path, body=None, *, headers=None, raw=None):
        payload = raw if raw is not None else (None if body is None else json.dumps(body, separators=(",", ":")).encode())
        request = urllib.request.Request(self.base + path, payload,
            {"Content-Type": "application/json", **(headers or {})}, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.read(), dict(response.headers)

    def api(self, method, path, body=None):
        status, raw, _ = self.exchange(method, path, body)
        self.assertTrue(200 <= status < 300, (method, path, status, raw[:1000]))
        return json.loads(raw)

    def point(self, name="sensor", **fields):
        definition = {"station": "QA", "name": name, "source_type": "manual",
            "data_type": "FLOAT", "stale_ms": 10000, **fields}
        return self.api("POST", "/api/v1/points", definition), definition

    def sample(self, point, value):
        self.api("POST", f"/api/v1/points/{point['id']}/sample", {"value": value})

    def value(self, point):
        return next(value for value in self.api("GET", "/api/v1/runtime")["values"] if value["point_id"] == point["id"])

    def history(self, query=""):
        return self.api("GET", "/api/v1/history" + ("?" + query if query else ""))

    def test_75000_point_batch_rejected_atomically_not_claimed_supported(self):
        prior, _ = self.point("existing")
        definitions = [{"station": f"Source{i // 15000 + 1}-IO{(i // 500) % 30 + 1}",
            "name": f"Point{i % 500 + 1}", "data_type": "FLOAT", "source_type": "manual"} for i in range(75000)]
        status, raw, _ = self.exchange("POST", "/api/v1/points/batch", {"items": definitions})
        self.assertEqual(status, 422, raw[:1000])
        self.assertIn("20000", raw.decode())
        self.assertEqual([p["id"] for p in self.api("GET", "/api/v1/points")["items"]], [prior["id"]])
        self.assertEqual(len(json.loads((self.data / "points.json").read_text())), 1)

    def test_20000_point_http_boundary_survives_restart_and_rejects_overflow(self):
        definitions = [{"station": "capacity", "name": f"P{i}", "data_type": "FLOAT", "source_type": "manual"} for i in range(20000)]
        created = self.api("POST", "/api/v1/points/batch", {"items": definitions})["items"]
        self.assertEqual(len(created), 20000)
        version = self.api("POST", "/api/v1/apply")["version"]
        status, _, _ = self.exchange("POST", "/api/v1/points", {**definitions[0], "name": "overflow"})
        self.assertEqual(status, 422)
        stop(self.process)
        self.start()
        loaded = self.api("GET", "/api/v1/points")["items"]
        self.assertEqual({p["id"] for p in loaded}, {p["id"] for p in created})
        self.assertEqual(self.api("GET", "/api/v1/runtime")["version"], version)

    def test_saved_scaling_requires_apply_old_version_cannot_write_new_runtime(self):
        point, definition = self.point(scale_factor=2, offset=10, writable=True)
        version = self.api("POST", "/api/v1/apply")["version"]
        self.sample(point, 21)
        self.assertEqual(self.value(point)["value"], 52)
        self.api("POST", "/api/v1/snapshot")
        frozen = self.history()["items"]
        self.api("PUT", f"/api/v1/points/{point['id']}", {**definition, "scale_factor": -0.5, "offset": 20})
        self.sample(point, 22)
        self.assertEqual(self.value(point)["value"], 54)
        self.assertEqual(self.api("GET", "/api/v1/runtime")["version"], version)
        new_version = self.api("POST", "/api/v1/apply")["version"]
        self.assertNotEqual(new_version, version)
        command = {"command_id": "stale-configuration", "point_id": point["id"], "value": 15, "version": version}
        status, _, _ = self.exchange("POST", "/api/v1/write", command)
        self.assertEqual(status, 422)
        command.update(command_id="new-configuration", version=new_version)
        result = self.api("POST", "/api/v1/write", command)
        self.assertEqual(result["state"], "readback_confirmed")
        self.assertEqual(self.value(point)["raw"], 10)
        self.assertEqual(self.value(point)["value"], 15)
        self.assertEqual(self.history()["items"], frozen)

    def test_crash_restart_preserves_history_policy_and_dedupe_without_replaying_rules(self):
        point, _ = self.point(writable=True, scale_factor=2, offset=10)
        version = self.api("POST", "/api/v1/apply")["version"]
        command = {"command_id": "persisted-command", "point_id": point["id"], "value": 52, "version": version}
        first = self.api("POST", "/api/v1/write", command)
        policy = {"enabled": True, "interval_ms": 200, "retention_days": 7, "point_ids": [point["id"]]}
        self.api("PUT", "/api/v1/storage?station=QA", policy)
        rule = {"id": "restart-rule", "name": "restart must disable", "enabled": True,
            "station": "QA", "logic": "and", "trigger": "rising", "cooldown_ms": 200,
            "conditions": [{"point_id": point["id"], "op": ">", "value": 1}], "actions": [{"type": "snapshot"}]}
        self.api("PUT", "/api/v1/rules", {"items": [rule]})
        wait_for(lambda: self.history()["stats"]["count"] >= 3, description="periodic and condition storage")
        # Kill our own synthetic process after durable responses; SQLite WAL must recover.
        self.process.kill()
        self.process.wait(timeout=5)
        self.start()
        frozen = self.history()["items"]
        count = self.history()["stats"]["count"]
        runtime = self.api("GET", "/api/v1/runtime")
        self.assertTrue(self.api("GET", "/api/v1/storage?station=QA")["enabled"])
        self.assertFalse(runtime["rules"][0]["enabled"])
        self.assertIsNone(self.value(point)["value"])
        again = self.api("POST", "/api/v1/write", command)
        self.assertEqual(again, first)
        self.assertIsNone(self.value(point)["value"], "Duplicate command replayed local write after restart")
        time.sleep(0.7)
        self.assertEqual(self.history()["stats"]["count"], count, "Storage replayed absent runtime samples")
        self.assertEqual(self.history()["items"], frozen)
        changed = {**command, "value": 54}
        self.assertEqual(self.exchange("POST", "/api/v1/write", changed)[0], 422)

    def test_history_frozen_pagination_excludes_new_samples(self):
        point, _ = self.point(scale_factor=0.25, offset=-2)
        self.api("POST", "/api/v1/apply")
        for raw in range(5):
            self.sample(point, raw)
            self.api("POST", "/api/v1/snapshot")
        first = self.history("limit=2")
        boundary = first["boundary"]
        self.sample(point, 999)
        self.api("POST", "/api/v1/snapshot")
        frozen = self.history(f"before={boundary}&limit=2&offset=2")
        final = self.history(f"before={boundary}&limit=2&offset=4")
        self.assertEqual(first["stats"]["count"], 5)
        self.assertEqual(frozen["stats"], first["stats"])
        rows = first["items"] + frozen["items"] + final["items"]
        self.assertEqual(len(rows), 5)
        self.assertEqual(sorted(row["raw"] for row in rows), list(range(5)))
        self.assertEqual(self.history()["stats"]["count"], 6)

    def test_real_process_mcp_readonly_envelope_guards_and_write_opt_in(self):
        headers = {"Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"}
        def rpc(method, params=None, **kwargs):
            return self.exchange("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, headers=headers, **kwargs)
        inventory = json.loads(rpc("tools/list")[1])["result"]["tools"]
        self.assertNotIn("points_create", {tool["name"] for tool in inventory})
        params = {"name": "points_create", "arguments": {"station": "MCP", "name": "forbidden", "source_type": "manual", "data_type": "FLOAT"}}
        denied = json.loads(rpc("tools/call", params)[1])
        self.assertEqual(denied["error"]["code"], -32003)
        self.assertEqual(self.exchange("PUT", "/api/v1/mcp/settings", {"mode": "write", "revision": 1})[0], 403)
        stop(self.process)
        self.start("--mcp-write")
        settings = self.api("GET", "/api/v1/mcp/settings")
        self.assertEqual(settings["mode"], "read_only")
        self.assertNotIn("points_create", {tool["name"] for tool in json.loads(rpc("tools/list")[1])["result"]["tools"]})
        settings = self.api("PUT", "/api/v1/mcp/settings", {"mode": "write", "revision": settings["revision"]})
        self.assertEqual(settings["mode"], "write")
        self.assertEqual(len(json.loads(rpc("tools/list")[1])["result"]["tools"]), 33)
        no_id = {"jsonrpc": "2.0", "method": "tools/call", "params": params}
        self.assertEqual(self.exchange("POST", "/mcp", no_id, headers=headers)[0], 400)
        duplicate = b'{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/call","params":{}}'
        self.assertEqual(self.exchange("POST", "/mcp", headers=headers, raw=duplicate)[0], 400)
        self.assertEqual(self.api("GET", "/api/v1/points")["items"], [])
        created = json.loads(rpc("tools/call", params)[1])["result"]
        self.assertFalse(created.get("isError", False), created)
        self.assertEqual(len(self.api("GET", "/api/v1/points")["items"]), 1)
        settings = self.api("PUT", "/api/v1/mcp/settings", {"mode": "off", "revision": settings["revision"]})
        self.assertEqual(rpc("tools/list")[0], 503)
        self.api("PUT", "/api/v1/mcp/settings", {"mode": "read_only", "revision": settings["revision"]})
        self.assertEqual(json.loads(rpc("tools/call", params)[1])["error"]["code"], -32003)
        stop(self.process)
        self.start("--mcp-write")
        self.assertEqual(self.api("GET", "/api/v1/mcp/settings")["mode"], "read_only")

    def test_real_process_rejects_rebinding_cross_origin_and_unsecured_remote_start(self):
        for method, path in [("GET", "/health"), ("GET", "/api/v1/points"), ("OPTIONS", "/api/v1/points"), ("POST", "/mcp")]:
            with self.subTest(method=method, path=path):
                status, _, _ = self.exchange(method, path, headers={"Host": "attacker.invalid", "Origin": "http://attacker.invalid"})
                self.assertEqual(status, 403)
        status, _, _ = self.exchange("POST", "/api/v1/snapshot", headers={"Origin": "https://attacker.invalid"})
        self.assertEqual(status, 403)
        forbidden = self.root / "must-not-be-created"
        result = subprocess.run([str(self.server), "--listen", "0.0.0.0:0", "--data-dir", str(forbidden)], capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"authentication and TLS", result.stderr)
        self.assertFalse(forbidden.exists(), "Unsafe startup created data before failing closed")


if __name__ == "__main__":
    unittest.main(verbosity=2)

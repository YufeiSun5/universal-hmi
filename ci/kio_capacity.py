"""Real local KingIO/MQTT capacity fixture: 5 brokers, 30 stations, 15,000 points.

Only synthetic loopback data is used. The publisher speaks the documented Objs /
PVs format. This is a protocol and capacity fixture, not a production-device claim.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import urlparse
import subprocess
import tempfile
import threading
import time

from common import ROOT, health, port_available, request, stop, wait_for


class CapacityFixture:
    broker_count = 5
    station_count = 30
    per_station = 500
    topic = "datachange_capacity"

    def __init__(self, base="http://127.0.0.1:18080", *, output=None, port_start=18890, control_port=18980):
        self.base = base
        self.output = Path(output or ROOT / "dist/capacity")
        self.output.mkdir(parents=True, exist_ok=True)
        self.port_start = port_start
        self.control_port = control_port
        self.brokers = []
        self.publishers = []
        self.logs = []
        self.points = []
        self.thread = None
        self.stop_event = threading.Event()
        self.paused = threading.Event()
        self.sequence = 0
        self.last_published = None
        self.publish_error = None
        self.control_server = None
        self.publish_lock = threading.RLock()
        self.published = {str(i): {"messages": 0, "samples": 0, "batches": 0, "expected_decode_errors": 0} for i in range(5)}
        self.phases = []
        self.bad_quality_points = set()
        self.evidence = {"broker_count": 5, "station_count": 30, "points_per_station": 500, "point_count": 15000, "transport": "5 actual loopback Mosquitto brokers", "checks": {}}

    def api(self, method, path, body=None):
        return request(self.base, method, path, body)

    def values(self):
        return {v["point_id"]: v for v in self.api("GET", "/api/v1/runtime")["values"]}

    @staticmethod
    def source_index(station):
        return (station - 1) // 6

    @staticmethod
    def path(station, point):
        # Identical paths and topics exist in every broker: source identity matters.
        return f"Local{(station - 1) % 6 + 1:02d}.Point{point:04d}"

    @staticmethod
    def value(station, point, sequence=0):
        return station * 1000 + point + sequence

    def publish(self, source, payload, *, retained=False):
        command = ["mosquitto_pub", "-h", "127.0.0.1", "-p", str(self.port_start + source), "-t", self.topic, "-q", "1", "-s"]
        if retained:
            command.append("-r")
        subprocess.run(command, input=json.dumps(payload, separators=(",", ":")).encode(), check=True, timeout=10)
        counters = self.published[str(source)]
        count = len(payload.get("Objs", []))
        counters["messages"] += 1
        counters["samples"] += count
        counters["batches"] += int(count > 0)

    def payload(self, source, sequence, *, instant=None):
        instant = instant or datetime.now(timezone.utc)
        # PVs.2 plus each object's relative milliseconds is the authentic KIO form.
        base = instant - timedelta(milliseconds=125)
        return {"PVs": {"2": base.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + " +0000", "3": 192}, "Objs": [
            {"N": self.path(station, point), "1": self.value(station, point, sequence), "2": 125, **({"3": 0} if (station, point) in self.bad_quality_points else {})}
            for station in range(source * 6 + 1, source * 6 + 7)
            for point in range(1, self.per_station + 1)
        ]}

    def prepare(self):
        health(self.base)
        assert not self.api("GET", "/api/v1/points")["items"], "Capacity fixture requires its own empty backend data directory"
        for source in range(self.broker_count):
            port = self.port_start + source
            assert port_available(port), f"Fixture port {port} is already in use; never replace another broker"
            config = self.output / f"mosquitto-{source}.conf"
            config.write_text(f"listener {port} 127.0.0.1\nallow_anonymous true\npersistence false\n")
            log = (self.output / f"mosquitto-{source}.log").open("w")
            self.logs.append(log)
            proc = subprocess.Popen(["mosquitto", "-c", str(config)], stdout=log, stderr=subprocess.STDOUT)
            self.brokers.append(proc)
            wait_for(lambda: not port_available(port), description=f"broker {source}")
            assert proc.poll() is None, f"Broker {source} failed"
        sources = [{"id": f"capacity-{source}", "name": f"Local KIO {source + 1}", "broker": f"tcp://127.0.0.1:{self.port_start + source}", "topic": self.topic, "protocol": "kingio", "client_id": f"capacity-{source}", "writer": "capacity-fixture", "ack_timeout_ms": 2000} for source in range(5)]
        self.api("PUT", "/api/v1/sources", {"items": sources})
        definitions = [{"station": f"IO-{station:02d}", "name": f"Point{point:04d}", "source_type": "mqtt", "data_type": "FLOAT", "unit": "kPa", "source_id": f"capacity-{self.source_index(station)}", "source_path": self.path(station, point), "topic": self.topic, "scale_factor": 1, "offset": 0, "stale_ms": 3000, "rw_mode": "R"} for station in range(1, 31) for point in range(1, 501)]
        self.points = self.api("POST", "/api/v1/points/batch", {"items": definitions})["items"]
        assert len(self.points) == 15000
        self.point_by_identity = {(p["station"], p["source_path"]): p for p in self.points}
        self.api("POST", "/api/v1/apply")
        (self.output / "points.json").write_text(json.dumps(self.points))
        stale_payload = self.payload(0, 0, instant=datetime.now(timezone.utc) - timedelta(minutes=2))
        stale_payload["Objs"] = stale_payload["Objs"][:1]
        self.publish(0, stale_payload, retained=True)
        for source in sources:
            self.api("POST", f"/api/v1/sources/{source['id']}/connect")
        first = self.point(1, 1)
        retained = wait_for(lambda: (value if (value := self.values().get(first["id"], {})).get("quality") == "stale" else None), description="old retained KIO value")
        assert retained["quality"] == "stale", retained
        self.evidence["checks"]["retained_source_timestamp_stays_stale"] = True
        # Clear broker retention. Empty payload is transport retention deletion.
        subprocess.run(["mosquitto_pub", "-h", "127.0.0.1", "-p", str(self.port_start), "-t", self.topic, "-q", "1", "-r", "-n"], check=True)
        self.published["0"]["messages"] += 1
        self.published["0"]["expected_decode_errors"] += 1
        self.publish_cycle()
        wait_for(lambda: len(values := self.values()) == 15000 and all(v["quality"] == "good" for v in values.values()), timeout=45, description="15,000 MQTT runtime values")
        values = self.values()
        assert len(values) == 15000
        for station in range(1, 31):
            for number in (1, 500):
                p = self.point(station, number)
                value = values[p["id"]]
                assert value["value"] == self.value(station, number, self.sequence), (p, value)
                assert value["quality"] == "good", value
        self.evidence["checks"]["source_topic_path_isolation"] = True
        self.evidence["checks"]["quality_192_and_default_timestamp_offset"] = True
        self.protocol_checks()
        self.api("POST", "/api/v1/snapshot")
        catalog = wait_for(lambda: self.api("GET", "/api/v1/history/catalog") if len(self.api("GET", "/api/v1/history/catalog")["items"]) >= 15000 else None, timeout=45, description="15,000-point history catalog")
        assert len(catalog["items"]) >= 15000 and not catalog.get("truncated", False), catalog.keys()
        self.evidence["history_catalog_count"] = len(catalog["items"])
        self.evidence["checks"]["history_catalog_includes_all_points"] = True
        runtime = self.api("GET", "/api/v1/runtime")
        self.check_queue(runtime)
        self.write_evidence()
        return self

    def point(self, station, number):
        return self.point_by_identity[(f"IO-{station:02d}", self.path(station, number))]

    def protocol_checks(self):
        p = self.point(1, 1)
        before = self.values()[p["id"]]
        # Defaults are only applied to an object that actually exists in Objs.
        self.publish(0, {"PVs": {"1": 999999, "2": datetime.now(timezone.utc).isoformat(), "3": 192}, "Objs": []})
        time.sleep(0.2)
        after = self.values()[p["id"]]
        assert before["value"] == after["value"] and before["source_time"] == after["source_time"], "Absent object inherited a default value"
        self.evidence["checks"]["missing_object_does_not_generate_update"] = True
        instant = datetime.now(timezone.utc)
        base = instant - timedelta(milliseconds=137)
        self.publish(0, {"PVs": {"1": 8765, "2": base.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + " +0000", "3": 192}, "Objs": [{"N": p["source_path"], "2": 137}]})
        default = wait_for(lambda: self.values().get(p["id"], {}) if self.values().get(p["id"], {}).get("value") == 8765 else None, description="KIO PV defaults")
        parsed = datetime.fromisoformat(default["source_time"].replace("Z", "+00:00"))
        assert abs((parsed - instant).total_seconds()) < 0.003, (parsed, instant)
        assert default["quality"] == "good"
        self.evidence["checks"]["listed_object_defaults_and_millisecond_offset"] = True
        # Missing explicit quality must never become GOOD.
        self.publish(0, {"PVs": {"2": datetime.now(timezone.utc).isoformat()}, "Objs": [{"N": p["source_path"], "1": 7654}]})
        bad = wait_for(lambda: self.values().get(p["id"], {}) if self.values().get(p["id"], {}).get("value") == 7654 else None, description="missing-quality value")
        assert bad["quality"] != "good"
        self.evidence["checks"]["missing_quality_is_not_good"] = True
        self.publish_cycle()
        wait_for(lambda: self.values()[p["id"]]["quality"] == "good", description="quality recovery")

    def check_queue(self, runtime):
        assert "dropped" in runtime and isinstance(runtime["dropped"], int) and runtime["dropped"] >= 0
        queue = runtime.get("queue", {})
        # The runtime contract exposes both the bounded ingest capacity and loss.
        assert isinstance(queue.get("capacity"), int) and queue["capacity"] > 0, "Runtime queue capacity must be explicit"
        assert 0 <= queue["depth"] <= queue["capacity"], queue
        metrics = runtime.get("source_metrics", {})
        assert len(metrics) == self.broker_count, "Every live broker must expose transport counters"
        for source, counters in metrics.items():
            assert counters["capacity"] > 0 and 0 <= counters["queued"] <= counters["capacity"], (source, counters)
            assert counters["accepted"] >= counters["processed"] >= 1, (source, counters)
            assert counters["dropped"] >= 0 and counters["received"] >= counters["accepted"], (source, counters)
        assert runtime["dropped"] == 0 and all(c["dropped"] == 0 for c in metrics.values()), "15,000-point baseline dropped samples/messages"
        self.evidence["source_metrics"] = metrics
        self.evidence["queue"] = queue
        self.evidence["dropped_samples"] = runtime["dropped"]
        self.evidence["checks"]["bounded_queue_and_drop_counter_visible"] = True

    def publish_cycle(self):
        with self.publish_lock:
            self.sequence += 1
            instant = datetime.now(timezone.utc)
            for source in range(5):
                self.publish(source, self.payload(source, self.sequence, instant=instant))
            self.last_published = instant.isoformat()

    def set_overview_faults(self, enabled):
        """Real MQTT quality differences prove station-scoped overview routes."""
        with self.publish_lock:
            self.bad_quality_points = {(1, 1), (2, 1), (2, 2)} if enabled else set()
            self.publish_cycle()
        self.evidence["overview_fault_fixture"] = {"expected_bad_quality": {"IO-01": 1, "IO-02": 2}, "active": enabled}

    def pause(self):
        self.paused.set()
        # Wait for a cycle already in flight, so a paused interval is unambiguous.
        with self.publish_lock:
            pass

    def phase(self, name):
        now = time.monotonic()
        if self.phases and "ended_monotonic" not in self.phases[-1]:
            self.phases[-1]["ended_monotonic"] = now
        self.phases.append({"name": name, "started_monotonic": now, "started_unix": time.time()})
        (self.output / "phases.json").write_text(json.dumps(self.phases, indent=2) + "\n")

    def settle_accounting(self):
        self.pause()
        def settled():
            runtime = self.api("GET", "/api/v1/runtime")
            metrics = runtime.get("source_metrics", {})
            if len(metrics) != 5:
                return None
            for number, expected in self.published.items():
                counters = metrics[f"capacity-{number}"]
                if any(counters[key] != expected["messages"] for key in ("received", "accepted", "processed")):
                    return None
                if counters["samples"] != expected["samples"] or counters["queued"] or counters["in_flight"]:
                    return None
            queue = runtime["queue"]
            samples = sum(p["samples"] for p in self.published.values())
            batches = sum(p["batches"] for p in self.published.values())
            if queue["accepted_samples"] != samples or queue["processed_samples"] != samples:
                return None
            if queue["accepted_batches"] != batches or queue["processed_batches"] != batches or queue["depth"] or queue["in_flight_batches"]:
                return None
            return runtime
        runtime = wait_for(settled, timeout=20, description="published / transport / runtime accounting to drain")
        self.check_queue(runtime)
        for number, expected in self.published.items():
            assert runtime["source_metrics"][f"capacity-{number}"]["decode_errors"] == expected["expected_decode_errors"]
        self.evidence["published"] = self.published
        self.evidence["checks"]["published_transport_runtime_accounting_exact"] = True
        self.write_evidence()
        return {"published": self.published, "queue": runtime["queue"], "source_metrics": runtime["source_metrics"]}

    def start(self):
        def run():
            while not self.stop_event.is_set():
                started = time.monotonic()
                with self.publish_lock:
                    if not self.paused.is_set():
                        try:
                            self.publish_cycle()
                        except Exception as error:
                            self.publish_error = str(error)
                            self.stop_event.set()
                            return
                self.stop_event.wait(max(0.01, 1 - (time.monotonic() - started)))
        self.thread = threading.Thread(target=run, name="local-kio-publisher", daemon=True)
        self.thread.start()
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                data = {"paused": fixture.paused.is_set(), "sequence": fixture.sequence, "last_published": fixture.last_published, "error": fixture.publish_error}
                body = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                if self.path == "/pause":
                    fixture.pause()
                elif self.path == "/resume":
                    fixture.paused.clear()
                elif self.path == "/faults/overview-on":
                    fixture.set_overview_faults(True)
                elif self.path == "/faults/off":
                    fixture.set_overview_faults(False)
                elif self.path.startswith("/phase/"):
                    fixture.phase(self.path.rsplit("/", 1)[-1])
                elif self.path == "/settle":
                    fixture.settle_accounting()
                else:
                    self.send_error(404)
                    return
                self.do_GET()

            def log_message(self, *_):
                pass

        assert port_available(self.control_port), "Fixture control port already in use"
        self.control_server = ThreadingHTTPServer(("127.0.0.1", self.control_port), Handler)
        threading.Thread(target=self.control_server.serve_forever, daemon=True).start()
        return self

    def write_evidence(self):
        self.evidence["published"] = self.published
        self.evidence["phases"] = self.phases
        self.evidence["sequence"] = self.sequence
        self.evidence["last_published"] = self.last_published
        self.evidence["publisher_error"] = self.publish_error
        (self.output / "capacity.json").write_text(json.dumps(self.evidence, indent=2) + "\n")

    def close(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=15)
        if self.control_server:
            self.control_server.shutdown()
            self.control_server.server_close()
        for broker in self.brokers:
            stop(broker)
        for log in self.logs:
            log.close()
        self.write_evidence()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    parser.add_argument("--server", type=Path, help="Start this binary with an isolated data directory")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/capacity")
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--serve", action="store_true", help="Keep publishing until interrupted")
    args = parser.parse_args()
    backend = None
    fixture = CapacityFixture(args.base, output=args.output)
    with tempfile.TemporaryDirectory(prefix="hmi-capacity-") as data:
        try:
            if args.server:
                port = urlparse(args.base).port or 80
                assert port_available(port), "Backend port is occupied; refusing to reuse unrelated data"
                with (fixture.output / "backend.log").open("w") as log:
                    backend = subprocess.Popen([str(args.server.resolve()), "--data-dir", data, "--listen", f"127.0.0.1:{port}"], stdout=log, stderr=subprocess.STDOUT)
                wait_for(lambda: health(args.base), description="capacity backend")
            fixture.prepare().start()
            print("READY: 5 local brokers / 30 stations / 15,000 KIO values", flush=True)
            deadline = time.monotonic() + args.duration
            while args.serve or time.monotonic() < deadline:
                if fixture.publish_error:
                    raise RuntimeError(fixture.publish_error)
                time.sleep(0.5)
            fixture.settle_accounting()
            print("PASS: KIO capacity fixture")
        except KeyboardInterrupt:
            pass
        finally:
            fixture.close()
            stop(backend)


if __name__ == "__main__":
    main()

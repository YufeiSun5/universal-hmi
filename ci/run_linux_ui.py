"""Run native Linux integration and a sustained real-MQTT profile.

--display selects an existing desktop without creating or replacing a display.
--xvfb is explicit for isolated CI. This script owns only the fixture processes
and test app it starts. Run release packaging afterward, never concurrently.
"""
from __future__ import annotations

import argparse
import hashlib
import math
import platform
import json
import os
from pathlib import Path
import statistics
import signal
import subprocess
import tempfile
import threading
import time

from common import ROOT, display_environment, health, port_available, stop, wait_for
from kio_capacity import CapacityFixture
from build_release import sources


class Sampler:
    """Linux process CPU and resident set sampled every 500 ms."""
    def __init__(self, backend_pid, output):
        self.backend_pid = backend_pid
        self.output = output
        self.samples = []
        self.stop_event = threading.Event()
        self.previous = {}
        self.ticks_per_second = os.sysconf("SC_CLK_TCK")
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def processes(self):
        result = {self.backend_pid: "backend"}
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                executable = (entry / "exe").resolve()
                if executable.name == "universal_hmi" and str(ROOT / "app/build/linux/x64/profile") in str(executable):
                    result[int(entry.name)] = "flutter_profile"
            except OSError:
                continue
        return result

    def run(self):
        while not self.stop_event.is_set():
            now = time.monotonic()
            for pid, role in self.processes().items():
                try:
                    stat = (Path("/proc") / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
                    ticks = int(stat[11]) + int(stat[12])
                    rss_kib = next(int(line.split()[1]) for line in (Path("/proc") / str(pid) / "status").read_text().splitlines() if line.startswith("VmRSS:"))
                    previous = self.previous.get(pid)
                    cpu = None if previous is None else 100 * (ticks - previous[1]) / self.ticks_per_second / (now - previous[0])
                    self.previous[pid] = (now, ticks)
                    self.samples.append({"elapsed_seconds": now - self.started, "monotonic_seconds": now, "pid": pid, "role": role, "rss_mib": rss_kib / 1024, "cpu_percent_one_core": cpu})
                except (OSError, StopIteration, ValueError):
                    pass
            self.stop_event.wait(0.5)

    def close(self, window=None):
        self.stop_event.set()
        self.thread.join(timeout=2)
        summary = {}
        ui_rows = [row for row in self.samples if row["role"] == "flutter_profile"]
        interval = window or ((ui_rows[0]["monotonic_seconds"], ui_rows[-1]["monotonic_seconds"]) if ui_rows else None)
        for role in ("backend", "flutter_profile"):
            rows = [row for row in self.samples if row["role"] == role and (interval is None or interval[0] <= row["monotonic_seconds"] <= interval[1])]
            if rows:
                cpu = [row["cpu_percent_one_core"] for row in rows if row["cpu_percent_one_core"] is not None]
                summary[role] = {"sample_count": len(rows), "sampled_seconds": rows[-1]["elapsed_seconds"] - rows[0]["elapsed_seconds"], "rss_mib_max": max(row["rss_mib"] for row in rows), "cpu_percent_mean": statistics.fmean(cpu) if cpu else None, "cpu_percent_p50": statistics.median(cpu) if cpu else None, "cpu_percent_p95": sorted(cpu)[math.ceil(len(cpu) * .95) - 1] if cpu else None, "cpu_percent_max": max(cpu) if cpu else None, "rss_mib_p50": statistics.median(row["rss_mib"] for row in rows), "rss_mib_p95": sorted(row["rss_mib"] for row in rows)[math.ceil(len(rows) * .95) - 1]}
        self.output.write_text(json.dumps({"interval_ms": 500, "summary_window_monotonic": interval, "summary_window_seconds": interval[1] - interval[0] if interval else None, "cpu_units": "100 percent equals one CPU core", "summary": summary, "samples": self.samples}, indent=2) + "\n")
        return summary


def run_owned(command, *, env, log, timeout=900):
    """A separate process group bounds cleanup to the app/driver we launched."""
    process = subprocess.Popen(command, cwd=ROOT / "app", env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
        if status:
            raise subprocess.CalledProcessError(status, command)
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        stop(process)


def start_backend(server, data, output):
    assert port_available(18080), "Port 18080 is occupied; native fixture must not reuse your backend data"
    with output.open("w") as log:
        process = subprocess.Popen([str(server), "--data-dir", str(data)], stdout=log, stderr=subprocess.STDOUT)
    wait_for(lambda: health("http://127.0.0.1:18080"), description="native fixture backend")
    return process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display")
    parser.add_argument("--xvfb", action="store_true")
    parser.add_argument("--server", type=Path, default=ROOT / "dist/universal-hmi-server")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/profile")
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--preflight", action="store_true", help="Only the two interaction preflight cycles; never a full performance acceptance")
    parser.add_argument("--flow", action="store_true", help="Also run the small native input/export test on a separate fresh backend")
    args = parser.parse_args()
    assert args.duration >= 120, "Sustained acceptance must cover at least 120 seconds"
    args.server = args.server.resolve()
    args.server.chmod(0o755)
    args.output.mkdir(parents=True, exist_ok=True)
    backend = sampler = fixture = None
    source_before = sources()
    source_digest = hashlib.sha256(json.dumps(source_before, sort_keys=True).encode()).hexdigest()
    cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown")
    metadata = {"mode": "profile", "preflight_only": args.preflight, "required_steady_seconds": args.duration,
        "sample_interval_ms": 500, "python": platform.python_version(), "kernel": platform.release(),
        "platform": platform.platform(), "cpu_model": cpu_model, "logical_cpus": os.cpu_count(),
        "available_cpu_affinity": sorted(os.sched_getaffinity(0)), "source_sha256_before": source_digest,
        "source_files": source_before, "git_revision_before": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "status": "running"}
    (args.output / "run-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="hmi-native-") as data, display_environment(args.display, args.xvfb) as env:
        # Isolated preferences avoid leaking test station/tab selection to a user's workspace.
        env = dict(env, XDG_CONFIG_HOME=str(Path(data) / "config"), XDG_DATA_HOME=str(Path(data) / "desktop-data"))
        try:
            if args.flow:
                backend = start_backend(args.server, Path(data) / "flow", args.output / "flow-backend.log")
                with (args.output / "native-flow.log").open("w") as log:
                    run_owned(["flutter", "test", "--no-pub", "integration_test/flow_test.dart", "-d", "linux"], env=env, log=log)
                stop(backend)
                wait_for(lambda: port_available(18080), description="flow backend stopped")
            backend = start_backend(args.server, Path(data) / "capacity", args.output / "capacity-backend.log")
            fixture = CapacityFixture(output=args.output / "capacity")
            fixture.prepare().start()
            fixture.phase("preflight")
            sampler = Sampler(backend.pid, args.output / "cpu-rss.json")
            sampler.thread.start()
            env['HMI_PROFILE_REPORT'] = str((args.output / "native-profile.json").resolve())
            command = ["flutter", "drive", "--no-pub", "--profile", "--driver=test_driver/profile_driver.dart", "--target=integration_test/capacity_profile_test.dart", "-d", "linux", f"--dart-define=HMI_PROFILE_SECONDS={args.duration}", "--dart-define=API_BASE_URL=http://127.0.0.1:18080", "--dart-define=HMI_FIXTURE_URL=http://127.0.0.1:18980"]
            if args.preflight:
                command.append("--dart-define=HMI_PREFLIGHT_ONLY=true")
            (args.output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
            print("Running native profile with 5 real local brokers and 15,000 values", flush=True)
            with (args.output / "flutter-drive.log").open("w") as log:
                run_owned(command, env=env, log=log)
            steady = next((phase for phase in fixture.phases if phase["name"] == "steady"), None)
            window = (steady["started_monotonic"], steady["ended_monotonic"]) if steady and "ended_monotonic" in steady else None
            summary = sampler.close(window)
            sampler = None
            report = json.loads((args.output / "native-profile.json").read_text())
            assert report["preflight_cycles"] >= 2
            assert not fixture.publish_error, fixture.publish_error
            fixture.settle_accounting()
            if args.preflight:
                assert report["full_acceptance"] is False and report["status"] == "preflight_passed_only"
                metadata["status"] = "preflight_passed_only"
                print("PASS: two native interaction preflight cycles only; full sustained acceptance NOT RUN")
            else:
                assert steady and window[1] - window[0] >= 120, "Steady CPU/RSS window shorter than120s"
                assert summary.get("flutter_profile", {}).get("sampled_seconds", 0) >= 119, "Native CPU/RSS coverage incomplete"
                assert report["measured_seconds"] >= 120 and report["full_acceptance"] is True
                assert report["pause_ms"] >= 10000 and report["steady_interaction_cycles"] >= 4
                assert report["rendered_value_changes"] > 10 and report["frames"]["count"] > 30
                assert report["checks"] and all(report["checks"].values())
                assert any(item["phase"] == "steady" for item in report["operation_latency_ms"])
                metadata["status"] = "passed"
                print("PASS: >=120s steady with repeated interactions, separate10s pause/recovery, exact accounting, CPU/RSS percentiles and frameP99")
        finally:
            source_after = sources()
            metadata["git_revision_after"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            metadata["source_sha256_after"] = hashlib.sha256(json.dumps(source_after, sort_keys=True).encode()).hexdigest()
            metadata["source_unchanged"] = source_before == source_after
            if metadata["status"] == "running":
                metadata["status"] = "failed"
            if not metadata["source_unchanged"]:
                metadata["status"] = "failed_source_changed"
            (args.output / "run-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            if sampler:
                sampler.close()
            if fixture:
                fixture.close()
            stop(backend)
            assert source_before == source_after, "Source changed during native acceptance; result invalid"


if __name__ == "__main__":
    main()

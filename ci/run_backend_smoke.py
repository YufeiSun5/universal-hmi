"""Run generic MQTT and 15,000-point KIO fixtures against isolated local data."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

from common import ROOT, health, port_available, stop, wait_for
from kio_capacity import CapacityFixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=ROOT / "dist/universal-hmi-server")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/backend-evidence")
    args = parser.parse_args()
    args.server = args.server.resolve()
    args.server.chmod(0o755)
    args.output.mkdir(parents=True, exist_ok=True)
    backend = broker = fixture = None
    with tempfile.TemporaryDirectory(prefix="hmi-backend-smoke-") as data:
        try:
            assert port_available(18080) and port_available(18884), "Fixture ports occupied; refusing to replace existing services"
            with (args.output / "generic-backend.log").open("w") as log:
                backend = subprocess.Popen([str(args.server), "--data-dir", str(Path(data) / "generic")], stdout=log, stderr=subprocess.STDOUT)
            wait_for(lambda: health("http://127.0.0.1:18080"), description="generic fixture backend")
            with (args.output / "generic-broker.log").open("w") as log:
                broker = subprocess.Popen(["mosquitto", "-p", "18884"], stdout=log, stderr=subprocess.STDOUT)
            wait_for(lambda: not port_available(18884), description="generic fixture broker")
            with (args.output / "generic-smoke.log").open("w") as log:
                subprocess.run([sys.executable, str(ROOT / "ci/smoke.py")], stdout=log, stderr=subprocess.STDOUT, check=True)
            stop(broker)
            stop(backend)
            wait_for(lambda: port_available(18080), description="generic backend stopped")
            with (args.output / "capacity-backend.log").open("w") as log:
                backend = subprocess.Popen([str(args.server), "--data-dir", str(Path(data) / "capacity")], stdout=log, stderr=subprocess.STDOUT)
            wait_for(lambda: health("http://127.0.0.1:18080"), description="capacity backend")
            fixture = CapacityFixture(output=args.output / "capacity")
            fixture.prepare()
            fixture.settle_accounting()
            print("PASS: generic MQTT write deduplication, inverse scaling, isolated 5-broker/30-station/15,000-point KIO capacity")
        finally:
            if fixture:
                fixture.close()
            stop(broker)
            stop(backend)


if __name__ == "__main__":
    main()

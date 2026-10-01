"""Exercise the real Linux Flutter runner, then capture its release UI."""
import base64
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.request

root=pathlib.Path.cwd().parent
server=root/"dist/universal-hmi-server"
server.chmod(0o755)
with tempfile.TemporaryDirectory(prefix="hmi-linux-") as data:
    backend=subprocess.Popen([str(server),"--data-dir",data],stdout=subprocess.DEVNULL)
    try:
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            try:
                with urllib.request.urlopen("http://127.0.0.1:18080/health",timeout=1) as r:
                    if json.load(r)["status"]=="ok":
                        break
            except Exception:
                time.sleep(.1)
        subprocess.run(["xvfb-run","-a","flutter","test","integration_test/flow_test.dart","-d","linux"],check=True)
        # A second clean backend data directory is used for the MQTT/API fixture.
        backend.terminate();backend.wait(timeout=10)
        mqtt_data=pathlib.Path(data)/"mqtt"
        backend=subprocess.Popen([str(server),"--data-dir",str(mqtt_data)],stdout=subprocess.DEVNULL)
        time.sleep(.8)
        broker=subprocess.Popen(["mosquitto","-p","18884"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            time.sleep(.5)
            subprocess.run(["python",str(root/"ci/smoke.py")],check=True)
        finally:
            broker.terminate();broker.wait(timeout=10)
        req=urllib.request.Request("http://127.0.0.1:18080/api/v1/demo",json.dumps({"enabled":True}).encode(),{"Content-Type":"application/json"},method="POST")
        with urllib.request.urlopen(req,timeout=10):pass
        output=root/"dist/screenshots";output.mkdir(parents=True,exist_ok=True)
        display=subprocess.Popen(["Xvfb",":99","-screen","0","1440x900x24"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        env=dict(os.environ,DISPLAY=":99")
        time.sleep(.6)
        app=subprocess.Popen([str(root/"app/build/linux/x64/release/bundle/universal_hmi")],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            time.sleep(4)
            subprocess.run(["import","-window","root",str(output/"linux-workspace.png")],env=env,check=True)
            subprocess.run(["convert",str(output/"linux-workspace.png"),"-resize","1120x700","-quality","75",str(output/"linux-workspace.jpg")],check=True)
            print("HMI_SCREENSHOT "+base64.b64encode((output/"linux-workspace.jpg").read_bytes()).decode())
        finally:
            app.terminate();app.wait(timeout=10);display.terminate();display.wait(timeout=10)
    finally:
        if backend.poll() is None:
            backend.terminate();backend.wait(timeout=10)

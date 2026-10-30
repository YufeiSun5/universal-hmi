"""Isolated launcher regression: service marker forbids database/backend startup."""
import json
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LauncherServiceTest(unittest.TestCase):
    def test_lazy_service_reuse_and_unavailable(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"remote_config_sha256":"","remote_enabled":false}')
            def log_message(self, *args):
                pass
        with tempfile.TemporaryDirectory(prefix='hmi-service-launcher-') as temp:
            root = Path(temp)/'project'
            root.mkdir()
            (root/'service-host.json').write_text('{}')
            server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
            thread = threading.Thread(target=server.serve_forever,daemon=True)
            thread.start()
            project = {'port':server.server_port,'data':str(root/'data'), 'app':'missing-app.exe', 'remoteConfig':''}
            (root/'project.json').write_text(json.dumps(project))
            command = ['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'packaging/windows-lazy/Start-HMI.ps1'),'-NoUI','-ProjectRoot',str(root),'-LegacyRoot',str(Path(temp)/'legacy')]
            try:
                ready = subprocess.run(command,capture_output=True,text=True,timeout=25)
                self.assertEqual(ready.returncode,0,ready.stdout+ready.stderr)
            finally:
                server.shutdown()
                server.server_close()
            stopped = subprocess.run(command,capture_output=True,text=True,timeout=25)
            self.assertNotEqual(stopped.returncode,0)
            for name in ('data','postgres-data','private-settings.json'):
                self.assertFalse((root/name).exists(),name+' was created in service-managed mode')
            explicit_stop = subprocess.run(command+['-Stop'],capture_output=True,text=True,timeout=25)
            self.assertNotEqual(explicit_stop.returncode,0)

class RemoteOnlyEntrypointTest(unittest.TestCase):
    def test_remote_entry_only_starts_client(self):
        import shutil
        with tempfile.TemporaryDirectory(prefix='hmi-remote-entry-') as temp:
            root=Path(temp)
            script=root/'Start-RemoteClient.ps1'
            shutil.copy2(ROOT/'packaging/Start-RemoteClient.ps1',script)
            (root/'universal_hmi.exe').write_bytes(b'isolated mock only')
            capture=root/'captured.json'
            # Intercept process creation inside a separate PowerShell session.
            code="function Start-Process { param($FilePath,$ArgumentList,$WorkingDirectory) @{file=$FilePath;args=$ArgumentList;work=$WorkingDirectory}|ConvertTo-Json|Set-Content -LiteralPath '"+str(capture)+"' }; & '"+str(script)+"' -View developer -ConnectionSettings"
            result=subprocess.run(['powershell.exe','-NoProfile','-Command',code],capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            actual=json.loads(capture.read_text(encoding='utf-8-sig'))
            self.assertEqual(actual['args'],['--view=developer','--remote-only','--connection-settings'])
            self.assertEqual(Path(actual['file']),root/'universal_hmi.exe')
            self.assertEqual(sorted(p.name for p in root.iterdir()),['Start-RemoteClient.ps1','captured.json','universal_hmi.exe'])

if __name__ == '__main__':
    unittest.main()

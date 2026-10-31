"""Public-disabled repair adoption: static contracts plus real PowerShell when available."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = [ROOT / 'packaging/Remote-Access.ps1', ROOT / 'packaging/windows-lazy/Remote-Access.ps1']
POWERSHELL = shutil.which('powershell.exe') or shutil.which('pwsh')


class PublicRemoteConfigurationTest(unittest.TestCase):
    def test_helpers_identical_and_preserve_crlf(self):
        self.assertEqual(SCRIPTS[0].read_bytes(), SCRIPTS[1].read_bytes())
        for path in SCRIPTS + [ROOT / 'packaging/windows-lazy/Start-HMI.ps1', ROOT / 'packaging/remote-access.example.json']:
            raw = path.read_bytes()
            self.assertNotIn(b'\n', raw.replace(b'\r\n', b''))

    def test_repair_path_requires_explicit_false_error_and_raw_digest(self):
        source = SCRIPTS[0].read_text()
        raw_helper = source.split('function Get-RemoteFileDigest', 1)[1].split('function Get-RemoteDigest', 1)[0]
        self.assertIn('ReadAllBytes($RemoteConfig)', raw_helper)
        self.assertNotIn('ConvertFrom-Json', raw_helper)
        self.assertNotIn('certificate', raw_helper)
        self.assertIn('($actual.remote_enabled -is [bool])', source)
        self.assertIn('($actual.remote_enabled -eq $false)', source)
        self.assertIn('![string]::IsNullOrEmpty([string]$actual.remote_config_error)', source)
        self.assertIn('if ($repairOnly) { $expected=Get-RemoteFileDigest $RemoteConfig }', source)
        self.assertIn('else { $expected=Get-RemoteDigest $RemoteConfig }', source)
        self.assertIn('$actual.remote_config_sha256 -cne $expected', source)
        self.assertIn("foreach($name in @('certificate','private_key'))", source)

    def test_new_drafts_disabled_schema_two_without_existing_overwrite(self):
        example = json.loads((ROOT / 'packaging/remote-access.example.json').read_text())
        self.assertEqual(example['schema'], 2)
        self.assertIs(example['enabled'], False)
        self.assertEqual(example['web_allowlist'], [])
        launcher = (ROOT / 'packaging/windows-lazy/Start-HMI.ps1').read_text()
        self.assertIn('if(!(Test-Path -LiteralPath $remoteTemplate)){Write-Json $remoteTemplate @{schema=2;enabled=$false;web_allowlist=@();', launcher)

    @unittest.skipUnless(POWERSHELL, 'PowerShell runtime unavailable; static checks are not execution proof')
    def test_actual_powershell_adoption(self):
        with tempfile.TemporaryDirectory(prefix='hmi-public-config-') as temp:
            work = Path(temp)
            config = work / 'remote.json'
            # Deliberately invalid JSON must remain repairable without JSON/cert reads.
            config.write_text('{"enabled":true, invalid')
            script = work / 'test.ps1'
            quote = lambda value: str(value).replace("'", "''")
            script.write_text("$ErrorActionPreference='Stop'\n. '" + quote(SCRIPTS[0]) + "'\n$path='" + quote(config) + "'\n" + r'''
function Invoke-RestMethod { param($Uri,$TimeoutSec) return $script:actual }
function Expect-Rejected {
  $rejected=$false
  try { Assert-RemoteDeployment 'http://127.0.0.1:1' $path } catch { $rejected=$true }
  if(!$rejected){throw 'unsafe adoption accepted'}
}
$raw=Get-RemoteFileDigest $path
$script:actual=@{remote_config_sha256=$raw;remote_enabled=$false;remote_config_error='invalid'}
Assert-RemoteDeployment 'http://127.0.0.1:1' $path
$actual.remote_config_sha256='mismatch'; Expect-Rejected
$actual.remote_config_sha256=$raw
foreach($enabled in @($true,'false',$null)) { $actual.remote_enabled=$enabled; Expect-Rejected }
$actual.remote_enabled=$false; $actual.remote_config_error=''; Expect-Rejected
$dir=Split-Path -Parent $path
[IO.File]::WriteAllText((Join-Path $dir 'cert.pem'),'synthetic certificate')
[IO.File]::WriteAllText((Join-Path $dir 'key.pem'),'synthetic key')
[IO.File]::WriteAllText($path,'{"schema":2,"enabled":true,"certificate":"cert.pem","private_key":"key.pem","web_allowlist":[]}')
$actual.remote_enabled=$true; $actual.remote_config_error=''
$actual.remote_config_sha256=Get-RemoteDigest $path
Assert-RemoteDeployment 'http://127.0.0.1:1' $path
[IO.File]::WriteAllText((Join-Path $dir 'cert.pem'),'changed certificate'); Expect-Rejected
$actual.remote_config_sha256=Get-RemoteFileDigest $path; Expect-Rejected
''')
            result = subprocess.run([POWERSHELL, '-NoProfile', '-File', str(script)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

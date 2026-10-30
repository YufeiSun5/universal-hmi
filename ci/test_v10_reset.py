"""Isolated v10 launcher safety tests. Native PG/CLI calls are mocked only in a temporary script copy."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESET = ROOT / 'packaging/windows-lazy/Reset-Project-v10.ps1'
MOCK = r'''function Run-Tool($Exe,$Arguments,$Name) {
  Add-Content -LiteralPath (Join-Path $work 'mock-calls.txt') -Value $Name
  switch($Name) {
    'rebuild-status' {if($script:committed -or ((Test-Path -LiteralPath (Join-Path $ProjectRoot 'data/mock-marker')) -and $env:V10_TEST_MISSING_MARKER -ne '1')){return '{"status":"already_applied"}'};return '{"status":"pending"}'}
    'rebuild-plan' {return ('{"status":"ready","preview_token":"'+('a'*64)+'"}')}
    'rebuild-commit' {
      if($env:V10_TEST_FAIL_COMMIT -eq '1'){throw 'mock transaction rejected'}
      $script:committed=$true
      [IO.File]::WriteAllText((Join-Path $ProjectRoot 'data/mock-marker'),'applied')
      [IO.File]::WriteAllText((Join-Path $ProjectRoot 'data\mock-business.json'),'cleaned')
      return '{"status":"applied"}'
    }
    default {return ''}
  }
}
'''

@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell/ACL required')
class V10ResetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v10-reset-', dir=ROOT / '.local')
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.bundle = self.root / 'bundle'
        for folder in (self.project/'data', self.project/'postgres-data', self.bundle/'postgresql/bin'):
            folder.mkdir(parents=True)
        for name, value in {
            'private-settings.json': {'schema':1,'pgMajor':18,'pgPort':65239},
            'data/database.json': {'dsn':'fixture-no-native-connection'},
            'data/mock-business.json': {'original':True},
        }.items():
            (self.project/name).write_text(json.dumps(value), encoding='utf-8')
        (self.project/'postgres-data/PG_VERSION').write_text('18\n', encoding='ascii')
        (self.bundle/'build-manifest.json').write_text(json.dumps({'source_sha256':'b'*64}), encoding='utf-8')
        for name in ('universal-hmi-rebuild.exe','postgresql/bin/pg_ctl.exe'):
            (self.bundle/name).write_bytes(b'not executable; mocked only in test copy')
        source=RESET.read_text(encoding='utf-8-sig')
        begin=source.index('function Run-Tool('); end=source.index('function Invoke-Rebuild(',begin)
        (self.bundle/'Reset-Project-v10.ps1').write_text(source[:begin]+MOCK+source[end:],encoding='utf-8-sig')
        self.original=self.inventory(self.project)
        self.gate=self.root/'project-maintenance'/hashlib.sha256(str(self.project).lower().encode()).hexdigest().upper()/'process-rebuild-v10.json'
    def tearDown(self):
        self.temp.cleanup()
    @staticmethod
    def inventory(root):
        return {p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
    def run_reset(self, fail=False, missing_marker=False):
        env=os.environ.copy();env.pop('PSModulePath',None);env['V10_TEST_FAIL_COMMIT']='1' if fail else '0';env['V10_TEST_MISSING_MARKER']='1' if missing_marker else '0'
        return subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(self.bundle/'Reset-Project-v10.ps1'),'-ProjectRoot',str(self.project),'-NoUI'],capture_output=True,text=True,env=env)
    def assert_start_blocked(self):
        for name in ('Start-HMI.ps1','Remote-Access.ps1'):
            shutil.copy2(ROOT/'packaging/windows-lazy'/name,self.bundle/name)
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(self.bundle/'Start-HMI.ps1'),'-ProjectRoot',str(self.project),'-NoUI'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('rebuild is pending or failed',result.stderr)
    def test_success_full_backup_and_repeat_keeps_new_data(self):
        result=self.run_reset();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        receipt=json.loads(self.gate.read_text(encoding='utf-8-sig'));self.assertEqual(receipt['status'],'applied')
        manifest=Path(receipt['backup_manifest']); data=json.loads(manifest.read_text(encoding='utf-8-sig'))
        self.assertEqual(data['files'],self.original)
        self.assertEqual(self.inventory(Path(data['backup_root'])/'project'),self.original)
        self.assertTrue(data['verified'])
        self.assertEqual(receipt['backup_manifest_sha256'],hashlib.sha256(manifest.read_bytes()).hexdigest())
        (self.project/'data/mock-business.json').write_text('new user content',encoding='utf-8')
        again=self.run_reset();self.assertEqual(again.returncode,0,again.stderr)
        self.assertIn('already_applied',again.stdout)
        self.assertEqual((self.project/'data/mock-business.json').read_text(),'new user content')
        self.assertEqual(len(list((self.root/'project-backups').iterdir())),1)
    def test_commit_failure_keeps_backup_blocks_start_and_recovers(self):
        result=self.run_reset(True);self.assertNotEqual(result.returncode,0)
        receipt=json.loads(self.gate.read_text(encoding='utf-8-sig'));self.assertEqual(receipt['status'],'failed')
        manifest=json.loads(Path(receipt['backup_manifest']).read_text(encoding='utf-8-sig'))
        self.assertEqual(self.inventory(Path(manifest['backup_root'])/'project'),self.original)
        self.assertEqual(self.inventory(self.project),self.original)
        errors=list(self.gate.parent.rglob('maintenance-error.json'));self.assertEqual(len(errors),1)
        diagnostic=json.loads(errors[0].read_text());self.assertIn('stage',diagnostic);self.assertIn('exception_type',diagnostic);self.assertIn('script_stack_trace',diagnostic)
        self.assert_start_blocked()
        retry=self.run_reset();self.assertEqual(retry.returncode,0,retry.stderr)
        self.assertEqual(json.loads(self.gate.read_text())['status'],'applied')
    def test_completed_receipt_missing_db_marker_blocks_without_cleanup(self):
        first=self.run_reset();self.assertEqual(first.returncode,0,first.stderr)
        (self.project/'data/mock-business.json').write_text('restored original content',encoding='utf-8')
        before=self.inventory(self.project)
        result=self.run_reset(missing_marker=True);self.assertNotEqual(result.returncode,0)
        self.assertIn('HMI remains blocked',result.stderr)
        self.assertEqual(self.inventory(self.project),before)
        self.assertEqual(len(list((self.root/'project-backups').iterdir())),1)
        receipt=json.loads(self.gate.read_text());self.assertEqual(receipt['status'],'failed');self.assertTrue(receipt['conflict'])
        self.assert_start_blocked()
        before=self.inventory(self.project) # Ordinary startup may append its failure log.
        retry=self.run_reset();self.assertNotEqual(retry.returncode,0)
        self.assertEqual(self.inventory(self.project),before)

    def test_pending_gate_blocks_before_server(self):
        self.gate.parent.mkdir(parents=True)
        self.gate.write_text(json.dumps({'status':'pending','project_root':str(self.project)}),encoding='utf-8')
        self.assert_start_blocked()
    def test_backup_junction_rejected_before_marker_or_external_write(self):
        target=self.root/'outside';target.mkdir()
        link=self.root/'project-maintenance'
        result=subprocess.run(['cmd.exe','/c','mklink','/J',str(link),str(target)],capture_output=True)
        self.assertEqual(result.returncode,0)
        try:
            result=self.run_reset();self.assertNotEqual(result.returncode,0)
            self.assertIn('validate-project',result.stderr)
            self.assertEqual(list(target.iterdir()),[])
            self.assertEqual(self.inventory(self.project),self.original)
        finally:
            os.rmdir(link)
    def test_native_success_and_nonzero_exit_are_distinct(self):
        source=RESET.read_text(encoding='utf-8-sig')
        begin=source.index('function Run-Tool(');end=source.index('function Invoke-Rebuild(',begin)
        zero=self.root/'zero.ps1';zero.write_text('exit 0',encoding='utf-8-sig')
        bad=self.root/'bad.ps1';bad.write_text('exit 42',encoding='utf-8-sig')
        native=self.root/'native-exit.ps1'
        native.write_text("$ErrorActionPreference='Stop';$work='"+str(self.root)+"'\n"+source[begin:end]+"\n$exe=Join-Path $PSHOME 'powershell.exe';$null=Run-Tool $exe @('-NoProfile','-File','"+str(zero)+"') 'exit0';try {$null=Run-Tool $exe @('-NoProfile','-File','"+str(bad)+"') 'exit42';throw 'unexpected success'} catch {if($_.Exception.Message -notlike '*command failed*'){throw}}",encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(native)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_native_descendant_handle_not_read_and_cli_json_is_read(self):
        go=ROOT/'.local/toolchains/go-1.24.7/go/bin/go.exe'
        if not go.exists():self.skipTest('Fixed local Go required for native descendant stub')
        source=self.root/'stdio.go';exe=self.root/'stdio.exe';pidfile=self.root/'child.pid'
        source.write_text('''package main
import("os";"os/exec";"strconv";"time";"fmt")
func main(){if os.Args[1]=="child"{fmt.Println("descendant retains stdout");time.Sleep(time.Minute);return};if os.Args[1]=="json"{fmt.Println(`{"status":"already_applied"}`);return};c:=exec.Command(os.Args[0],"child");c.Stdout=os.Stdout;c.Stderr=os.Stderr;if e:=c.Start();e!=nil{panic(e)};if e:=os.WriteFile(os.Args[2],[]byte(strconv.Itoa(c.Process.Pid)),0600);e!=nil{panic(e)}}
''',encoding='utf-8')
        env=os.environ.copy();env['GOROOT']=str(go.parents[1]);env['GOTOOLCHAIN']='local'
        subprocess.run([str(go),'build','-o',str(exe),str(source)],env=env,check=True,capture_output=True)
        script=RESET.read_text(encoding='utf-8-sig');begin=script.index('function Run-Tool(');end=script.index('function Invoke-Rebuild(',begin)
        runner=self.root/'handles.ps1'
        body="$ErrorActionPreference='Stop';$work='"+str(self.root)+"'\n"+script[begin:end]+"\ntry {$null=Run-Tool '"+str(exe)+"' @('pg','"+str(pidfile)+"') 'fake-pg-start';$json=Run-Tool '"+str(exe)+"' @('json') 'fake-cli' -ReadOutput;if(($json|ConvertFrom-Json).status -ne 'already_applied'){throw 'CLI JSON was not returned'};Write-Output 'PG returned without reading held handle; CLI JSON parsed'} finally {if(Test-Path '"+str(pidfile)+"'){$childId=[int](Get-Content '"+str(pidfile)+"');Stop-Process -Id $childId -ErrorAction SilentlyContinue}}"
        runner.write_text(body,encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner)],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_native_timeout_terminates_its_child(self):
        source=RESET.read_text(encoding='utf-8-sig')
        begin=source.index('function Run-Tool(');end=source.index('function Invoke-Rebuild(',begin)
        function=source[begin:end].replace('WaitForExit(120000)','WaitForExit(1600)')
        child=self.root/'sleep.ps1'
        child.write_text("[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'sleep.pid'),[string]$PID);Start-Sleep -Seconds 60",encoding='utf-8-sig')
        native=self.root/'native.ps1'
        native.write_text("$ErrorActionPreference='Stop';$work='"+str(self.root)+"'\n"+function+"\ntry {$null=Run-Tool (Join-Path $PSHOME 'powershell.exe') @('-NoProfile','-File','"+str(child)+"') 'timeout';exit 5} catch {if($_.Exception.Message -notlike '*timed out and was terminated*'){throw};$childId=[int](Get-Content (Join-Path $work 'sleep.pid'));if(Get-Process -Id $childId -ErrorAction SilentlyContinue){throw 'Timed-out child is still alive'};exit 0}",encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(native)],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_production_scripts_parse(self):
        for name in ('Reset-Project-v10.ps1','Start-HMI.ps1'):
            path=ROOT/'packaging/windows-lazy'/name
            command="$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('"+str(path)+"',[ref]$t,[ref]$e)|Out-Null;if($e){$e|Out-String|Write-Error;exit 1}"
            result=subprocess.run(['powershell.exe','-NoProfile','-Command',command],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_v12_owner_policy_uses_real_dotnet_acl_flags(self):
        source=RESET.read_text(encoding='utf-8-sig')
        policy=source[source.index('function Test-OwnerPolicy('):source.index('function Assert-AuthorizedOwner(')]
        runner=self.root/'owner-policy.ps1'
        body=r'''
$ErrorActionPreference='Stop'
$user='S-1-5-21-100-200-300-1001'
$admin='S-1-5-32-544'
function Make-Acl($owner,$grant=$user,$rights='FullControl',$prop='None',$protected=$true) {
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($owner)))
  $acl.SetAccessRuleProtection($protected,$false)
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($grant)),$rights,'ContainerInherit,ObjectInherit',$prop,'Allow')))
  return $acl
}
function Check($name,$acl,$enabled,$expected) {
  $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $actual=Test-OwnerPolicy $owner $user $enabled $acl.AreAccessRulesProtected ($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
  if($actual -ne $expected){throw ('Policy mismatch: '+$name)}
  Write-Output ('PASS '+$name)
}
Check 'current-user-owner' (Make-Acl $user) $false $true
Check 'elevated-admin-group-owner-explicit-user-full' (Make-Acl $admin) $true $true
Check 'admin-owner-not-elevated' (Make-Acl $admin) $false $false
Check 'foreign-owner' (Make-Acl 'S-1-5-21-100-200-300-1002') $true $false
Check 'group-only-grant' (Make-Acl $admin $admin) $true $false
Check 'user-modify-not-full' (Make-Acl $admin $user 'Modify') $true $false
Check 'inherit-only-not-directory-grant' (Make-Acl $admin $user 'FullControl' 'InheritOnly') $true $false
Check 'unprotected-acl' (Make-Acl $admin $user 'FullControl' 'None' $false) $true $false
$deny=Make-Acl $admin
$deny.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($user)),'Write','Deny')))
Check 'deny-rejected' $deny $true $false
$wide=Make-Acl $admin
$wide.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),'Write','Allow')))
Check 'untrusted-write-rejected' $wide $true $false
$read=Make-Acl $admin
$read.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),'ReadAndExecute','Allow')))
Check 'untrusted-read-only-allowed' $read $true $true
'''
        runner.write_text(policy+body,encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(result.stdout.count('PASS '),11)

    def test_v12_early_diagnostic_without_project_write_or_overwrite(self):
        runner=self.bundle/'Reset-Project-v10.ps1'
        diagnostic=self.root/'early-error.json'
        nonexistent=self.root/'absent-project'
        command=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner),'-ProjectRoot',str(nonexistent),'-NoUI','-DiagnosticPath',str(diagnostic)]
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        data=json.loads(diagnostic.read_text(encoding='utf-8-sig'))
        self.assertEqual(data['stage'],'validate-project')
        self.assertEqual(data['safe_error_code'],'project-validation-failed')
        self.assertNotIn('message',data)
        self.assertFalse(nonexistent.exists())
        self.assertFalse((self.root/'project-maintenance').exists())
        original=diagnostic.read_bytes()
        again=subprocess.run(command,capture_output=True,text=True)
        self.assertNotEqual(again.returncode,0)
        self.assertEqual(diagnostic.read_bytes(),original)

    def test_v12_new_admin_owned_private_directory_normalization_is_simulated(self):
        # This is an in-memory ACL simulation, not evidence of an elevated Windows token.
        source=RESET.read_text(encoding='utf-8-sig')
        functions=source[source.index('function Test-OwnerPolicy('):source.index('function Hash-File(')]
        functions=functions.replace('[IO.Directory]::GetAccessControl($Path)','(Mock-GetAcl $Path)').replace('[IO.Directory]::SetAccessControl($Path,$acl)','Mock-SetAcl $Path $acl')
        runner=self.root/'new-directory-owner.ps1'
        body=r'''
$ErrorActionPreference='Stop'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$script:adminEnabled=$true
$script:saved=@{}
function Mock-GetAcl($Path) {
  if($script:saved.ContainsKey($Path)){return $script:saved[$Path]}
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
  return $acl
}
function Mock-SetAcl($Path,$Acl){$script:saved[$Path]=$Acl}
$target=Join-Path $PSScriptRoot 'new-private'
Private-Directory $target
$acl=$script:saved[$target]
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value){throw 'New owner was not normalized'}
if(!$acl.AreAccessRulesProtected){throw 'New directory is not private'}
$existing=Join-Path $PSScriptRoot 'existing-foreign'
$null=New-Item -ItemType Directory -Path $existing
try {Private-Directory $existing;throw 'Existing unauthorized directory accepted'} catch {
  if($_.Exception.Message -ne 'Directory ownership authorization failed.'){throw}
}
if($script:saved.ContainsKey($existing)){throw 'Existing unauthorized directory ACL changed'}
$authorized=Join-Path $PSScriptRoot 'existing-authorized-admin'
$null=New-Item -ItemType Directory -Path $authorized
$approved=New-Object Security.AccessControl.DirectorySecurity
$approved.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
$approved.SetAccessRuleProtection($true,$false)
$approved.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
$script:saved[$authorized]=$approved
Private-Directory $authorized
if($script:saved[$authorized].GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){throw 'Existing authorized owner was changed'}
Write-Output 'PASS simulated new Administrators owner normalized; existing unauthorized owner untouched'
'''
        runner.write_text(functions+body,encoding='utf-8-sig')
        result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(runner)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

if __name__ == '__main__':
    unittest.main()

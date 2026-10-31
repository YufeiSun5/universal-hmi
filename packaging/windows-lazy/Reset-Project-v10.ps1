param(
  [string]$ProjectRoot=(Join-Path $env:LOCALAPPDATA 'UniversalHMI\project'),
  [switch]$NoUI,
  [string]$DiagnosticPath
)
# Maintenance only. Never starts the HMI server, HTTP listener, client or MQTT runtime.
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$locked=$false;$lock=$null;$pgStarted=$false;$gateFile=$null;$receipt=$null;$completedReceipt=$false;$script:maintenanceStage='validate-project';$script:maintenanceCode='project-validation-failed'
if(!$DiagnosticPath){$DiagnosticPath=Join-Path ([IO.Path]::GetTempPath()) ('UniversalHMI-maintenance-error-'+[Guid]::NewGuid().ToString('N')+'.json')}
function Save-Json($Path,$Value) {
  $temp=$Path+'.tmp';[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 16),$utf8)
  Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Test-OwnerPolicy($OwnerSid,$CurrentSid,[bool]$AdminEnabled,[bool]$Protected,$Rules) {
  if($OwnerSid -eq $CurrentSid){return $true}
  if($OwnerSid -ne 'S-1-5-32-544' -or !$AdminEnabled -or !$Protected){return $false}
  $explicitFull=$false
  $writeMask=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
  foreach($rule in $Rules) {
    if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny){return $false}
    $identity=$rule.IdentityReference.Value
    if(($rule.FileSystemRights -band $writeMask) -ne 0 -and $identity -notin @($CurrentSid,'S-1-5-18','S-1-5-32-544')){return $false}
    if($identity -eq $CurrentSid -and !$rule.IsInherited -and ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -and ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit) -and $rule.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl){$explicitFull=$true}
  }
  return $explicitFull
}
function Assert-AuthorizedOwner($Path) {
  $acl=[IO.Directory]::GetAccessControl($Path)
  $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $rules=$acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
  if(!(Test-OwnerPolicy $owner $sid.Value $script:adminEnabled $acl.AreAccessRulesProtected $rules)){throw 'Directory ownership authorization failed.'}
  return $acl
}
function Private-Directory($Path) {
  if(Test-Path -LiteralPath $Path){Assert-NoLinks $Path;$acl=Assert-AuthorizedOwner $Path} else {
    $ancestor=Split-Path -Parent $Path;while(!(Test-Path -LiteralPath $ancestor)){$ancestor=Split-Path -Parent $ancestor};Assert-NoLinks $ancestor
    # New-Item rejects a concurrently created target; never take ownership of an existing directory.
    $null=New-Item -ItemType Directory -Path $Path -ErrorAction Stop
    Assert-NoLinks $Path
    $acl=[IO.Directory]::GetAccessControl($Path)
    # Elevated Windows creators can default to Administrators as owner. Only our newly-created directory is normalized.
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value){$acl.SetOwner($sid)}
  }
  $acl.SetAccessRuleProtection($true,$false)
  foreach($existing in @($acl.Access)){$acl.RemoveAccessRuleSpecific($existing)}
  foreach($id in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
  }
  [IO.Directory]::SetAccessControl($Path,$acl)
  Assert-NoLinks $Path
  $null=Assert-AuthorizedOwner $Path
}
function Assert-NoLinks($Path) {
  $node=Get-Item -LiteralPath $Path -Force
  while($node) {
    if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse points are not supported for project maintenance.'}
    $node=$node.Parent
  }
}
function Hash-File($Path) {
  $stream=[IO.File]::OpenRead($Path);$hash=[Security.Cryptography.SHA256]::Create()
  try {return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()} finally {$stream.Dispose();$hash.Dispose()}
}
function File-Inventory($Root) {
  Assert-NoLinks $Root
  $result=[ordered]@{}
  foreach($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Project or backup contains a reparse point.'}
    if(!$item.PSIsContainer) {$result[$item.FullName.Substring($Root.Length+1).Replace('\','/')]=(Hash-File $item.FullName)}
  }
  return $result
}
function Acl-Inventory($Root) {
  $result=[ordered]@{'.'=([IO.Directory]::GetAccessControl($Root)).Sddl}
  foreach($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Project contains a reparse point.'}
    $key=$item.FullName.Substring($Root.Length+1).Replace('\','/')
    if($item.PSIsContainer){$result[$key]=([IO.Directory]::GetAccessControl($item.FullName)).Sddl} else {$result[$key]=([IO.File]::GetAccessControl($item.FullName)).Sddl}
  }
  return $result
}
function Same-Inventory($A,$B) {
  if($A.Count -ne $B.Count){return $false}
  foreach($key in $A.Keys){if(!$B.Contains($key) -or $A[$key] -cne $B[$key]){return $false}}
  return $true
}
function Run-Tool($Exe,$Arguments,$Name,[switch]$ReadOutput) {
  $script:maintenanceStage='native-'+$Name;$script:maintenanceCode='native-command-failed'
  $out=Join-Path $work ($Name+'.stdout');$err=Join-Path $work ($Name+'.stderr')
  foreach($arg in $Arguments){if([string]$arg -match '["\r\n]'){throw 'Unsupported native argument.'}}
  $quoted=@($Arguments|ForEach-Object {'"'+[string]$_+'"'}) -join ' '
  $p=Start-Process -FilePath $Exe -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  $null=$p.Handle # Keep a process handle so Windows PowerShell preserves the native ExitCode.
  if(!$p.WaitForExit(120000)){
    try {$p.Kill()} catch {throw ('Unable to terminate timed-out maintenance command PID '+$p.Id+'. HMI remains blocked.')}
    if(!$p.WaitForExit(10000)){throw ('Timed-out maintenance command has not exited, PID '+$p.Id+'. HMI remains blocked.')}
    throw ('Maintenance command timed out and was terminated: '+$Name)
  }
  if($p.ExitCode -ne 0){throw ('Maintenance command failed: '+$Name+'. See maintenance logs.')}
  # pg_ctl descendants retain the redirected handle after pg_ctl itself exits.
  # Only the short-lived Go CLI has JSON output to consume.
  if($ReadOutput){$script:maintenanceStage='read-output-'+$Name;return [IO.File]::ReadAllText($out)}
}
function Invoke-Rebuild($Operation,$Manifest,$Token) {
  $args=@('--database-config',(Join-Path $ProjectRoot 'data\database.json'),'--project-root',$ProjectRoot,'--migration-id','process-rebuild-v10','--operation',$Operation)
  if($Manifest){$args+=@('--backup-manifest',$Manifest)}
  if($Token){$args+=@('--preview-token',$Token)}
  $json=Run-Tool $tool $args ('rebuild-'+$Operation) -ReadOutput
  $script:maintenanceStage='decode-rebuild-'+$Operation
  return ($json | ConvertFrom-Json)
}
try {
  $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  if(!(Test-Path -LiteralPath (Join-Path $ProjectRoot 'private-settings.json'))){throw 'An initialized existing project is required.'}
  Assert-NoLinks $ProjectRoot
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $script:adminEnabled=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $script:maintenanceStage='authorize-project';$script:maintenanceCode='project-owner-unauthorized'
  $null=Assert-AuthorizedOwner $ProjectRoot
  $script:maintenanceStage='validate-project';$script:maintenanceCode='project-validation-failed'
  if(Test-Path -LiteralPath (Join-Path $ProjectRoot 'service-host.json')){throw 'Service-managed projects require explicit service maintenance; this installer will not stop a Windows Service.'}
  $sha=[Security.Cryptography.SHA256]::Create()
  try {$lockId=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($ProjectRoot.ToLowerInvariant())))).Replace('-','')} finally {$sha.Dispose()}
  $lock=New-Object Threading.Mutex($false,('Local\UniversalHMILazy'+$lockId))
  try {$locked=$lock.WaitOne(120000)} catch [Threading.AbandonedMutexException] {$locked=$true}
  if(!$locked){throw 'Another project entry is active. Retry after closing it.'}
  $parent=Split-Path -Parent $ProjectRoot
  $gateRoot=Join-Path (Join-Path $parent 'project-maintenance') $lockId
  Assert-NoLinks $parent
  $script:maintenanceCode='maintenance-directory-unauthorized'
  Private-Directory $gateRoot
  $script:maintenanceCode='project-validation-failed'
  $gateFile=Join-Path $gateRoot 'process-rebuild-v10.json'
  if(Test-Path -LiteralPath $gateFile) {
    $loaded=Get-Content -LiteralPath $gateFile -Raw|ConvertFrom-Json
    $receipt=[ordered]@{};foreach($property in $loaded.PSObject.Properties){$receipt[$property.Name]=$property.Value}
    if($receipt.project_root -ne $ProjectRoot -or $receipt.windows_sid -ne $sid.Value){throw 'Maintenance receipt identity mismatch.'}
    if($receipt.conflict){throw 'Completed receipt and database marker conflict. Explicit backup recovery is required; automatic cleanup is blocked.'}
    $completedReceipt=($receipt.status -eq 'applied' -or [bool]$receipt.completed_at)
  }
  $operationId=[Guid]::NewGuid().ToString('N')
  $work=Join-Path $gateRoot $operationId;Private-Directory $work
  $tool=Join-Path $PSScriptRoot 'universal-hmi-rebuild.exe'
  $pgbin=Join-Path $PSScriptRoot 'postgresql\bin'
  $cluster=Join-Path $ProjectRoot 'postgres-data'
  foreach($path in @($tool,(Join-Path $pgbin 'pg_ctl.exe'),(Join-Path $cluster 'PG_VERSION'),(Join-Path $ProjectRoot 'data\database.json'))){if(!(Test-Path -LiteralPath $path)){throw 'Complete v10 tools and initialized PostgreSQL project are required.'}}
  if((Get-Content -LiteralPath (Join-Path $cluster 'PG_VERSION') -Raw).Trim() -ne '18'){throw 'PostgreSQL 18 is required.'}
  $state=Get-Content -LiteralPath (Join-Path $ProjectRoot 'private-settings.json') -Raw|ConvertFrom-Json
  if($state.schema -ne 1 -or $state.pgMajor -ne 18){throw 'Unsupported private project settings.'}
  # A stopped project is a hard precondition. Never kill unknown processes or stop arbitrary services.
  foreach($proc in @(Get-CimInstance Win32_Process -Filter "Name='universal-hmi-server.exe' OR Name='universal_hmi.exe' OR Name='postgres.exe'")) {
    if(($proc.CommandLine -and $proc.CommandLine.IndexOf($ProjectRoot,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($proc.Name -eq 'universal_hmi.exe' -and $proc.ExecutablePath -and $proc.ExecutablePath.StartsWith((Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),[StringComparison]::OrdinalIgnoreCase))){throw 'Close both HMI clients and stop the project background before maintenance.'}
  }
  if(Get-NetTCPConnection -LocalPort ([int]$state.pgPort) -State Listen -ErrorAction SilentlyContinue){throw 'Private PostgreSQL is still running or its port is occupied. Stop the project background first.'}
  if($completedReceipt) {
    # Explicit repeated maintenance verifies the transaction marker. Ordinary startup never runs this path.
    # A previously completed migration needs no old backup to perform a read-only status check.
    $pgStarted=$true
    $null=Run-Tool (Join-Path $pgbin 'pg_ctl.exe') @('start','-D',$cluster,'-l',(Join-Path $work 'postgres.log'),'-w','-t','45') 'postgres-start'
    $status=Invoke-Rebuild 'status' $null $null
    if($status.status -ne 'already_applied') {
      $receipt.conflict=$true
      throw 'Completed receipt and database marker conflict. No cleanup was attempted; explicit backup recovery is required.'
    }
    $null=Run-Tool (Join-Path $pgbin 'pg_ctl.exe') @('stop','-D',$cluster,'-m','fast','-w','-t','45') 'postgres-stop'
    $pgStarted=$false
    $receipt.status='applied';$receipt.last_status_verified_at=(Get-Date -Format o)
    Save-Json $gateFile $receipt
    Write-Output 'already_applied; database transaction marker verified'
    exit 0
  }
  $application=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-manifest.json') -Raw|ConvertFrom-Json
  $receipt=[ordered]@{schema=1;migration_id='process-rebuild-v10';project_root=$ProjectRoot;windows_sid=$sid.Value;operation_id=$operationId;source_sha256=$application.source_sha256;tool_sha256=(Hash-File $tool);status='pending';started_at=(Get-Date -Format o);backup_manifest=$null}
  Save-Json $gateFile $receipt
  $script:maintenanceStage='backup-inventory';$script:maintenanceCode='backup-validation-failed'
  $originalAcl=([IO.Directory]::GetAccessControl($ProjectRoot)).Sddl
  $originalAcls=Acl-Inventory $ProjectRoot
  $before=File-Inventory $ProjectRoot
  if(!$before.Count){throw 'Refusing an empty project backup.'}
  [long]$bytes=0
  foreach($f in @(Get-ChildItem -LiteralPath $ProjectRoot -Force -Recurse -File)){$bytes+=$f.Length}
  $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($parent))
  if($drive.AvailableFreeSpace -lt ($bytes+[Math]::Max(268435456,[long]($bytes*0.1)))){throw 'Insufficient free disk space for a verified full project cold backup.'}
  $backupRoot=Join-Path (Join-Path $parent 'project-backups') ('v10-reset-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+$operationId)
  Private-Directory $backupRoot
  $copy=Join-Path $backupRoot 'project'
  $script:maintenanceStage='backup-copy'
  Copy-Item -LiteralPath $ProjectRoot -Destination $copy -Recurse -Force
  $script:maintenanceStage='backup-verify'
  $after=File-Inventory $ProjectRoot;$copied=File-Inventory $copy
  if(!(Same-Inventory $originalAcls (Acl-Inventory $ProjectRoot))){throw 'Project ACL changed during backup.'}
  if(!(Same-Inventory $before $after) -or !(Same-Inventory $before $copied)){throw 'Project changed during cold backup or backup bytes did not verify. No reset was attempted.'}
  $manifest=Join-Path $backupRoot 'manifest.json'
  Save-Json $manifest ([ordered]@{schema=1;migration_id='process-rebuild-v10';project_root=$ProjectRoot;windows_sid=$sid.Value;operation_id=$operationId;source_sha256=$receipt.source_sha256;tool_sha256=$receipt.tool_sha256;backup_root=$backupRoot;files=$before;project_acl_sddl=$originalAcl;source_acls=$originalAcls;verified=$true;completed_at=(Get-Date -Format o)})
  $receipt.backup_manifest=$manifest;Save-Json $gateFile $receipt
  # Start only private PostgreSQL, after the full cold backup is verified. The Go tool authenticates and checks the actual cluster/database identity.
  $pgStarted=$true
  $null=Run-Tool (Join-Path $pgbin 'pg_ctl.exe') @('start','-D',$cluster,'-l',(Join-Path $work 'postgres.log'),'-w','-t','45') 'postgres-start'
  $pgStarted=$true
  $status=Invoke-Rebuild 'status' $null $null
  if($status.status -eq 'already_applied'){$result=$status} else {
    if($status.status -ne 'pending'){throw 'Unexpected rebuild status.'}
    $plan=Invoke-Rebuild 'plan' $manifest $null
    if($plan.status -ne 'ready' -or $plan.preview_token -notmatch '^[a-fA-F0-9]{64}$'){throw 'The offline cleanup plan is not ready.'}
    Save-Json (Join-Path $work 'plan.json') $plan
    $result=Invoke-Rebuild 'commit' $manifest $plan.preview_token
    if($result.status -ne 'applied' -and $result.status -ne 'already_applied'){throw 'The offline cleanup did not commit.'}
  }
  $confirm=Invoke-Rebuild 'status' $null $null
  if($confirm.status -ne 'already_applied'){throw 'The committed migration marker did not verify.'}
  $null=Run-Tool (Join-Path $pgbin 'pg_ctl.exe') @('stop','-D',$cluster,'-m','fast','-w','-t','45') 'postgres-stop'
  $pgStarted=$false
  $receipt.status='applied';$receipt.completed_at=(Get-Date -Format o);$receipt.backup_manifest_sha256=(Hash-File $manifest)
  Save-Json (Join-Path $work 'result.json') $result
  Save-Json $gateFile $receipt
  Write-Output ('applied; verified full backup: '+$backupRoot)
} catch {
  $failure=$_
  $diagnostic=[ordered]@{schema=1;migration_id='process-rebuild-v10';stage=$script:maintenanceStage;safe_error_code=$script:maintenanceCode;exception_type=$failure.Exception.GetType().FullName;script_stack_trace=$failure.ScriptStackTrace}
  # Preserve early failures without creating or changing an unauthorized project directory.
  # CreateNew refuses an existing target, including a pre-existing redirected file.
  try {
    $diagnosticBytes=$utf8.GetBytes(($diagnostic|ConvertTo-Json -Depth 8))
    $diagnosticStream=New-Object IO.FileStream($DiagnosticPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$diagnosticStream.Write($diagnosticBytes,0,$diagnosticBytes.Length)} finally {$diagnosticStream.Dispose()}
  } catch {}
  if($work -and (Test-Path -LiteralPath $work)){try {Save-Json (Join-Path $work 'maintenance-error.json') $diagnostic} catch {}}
  if($receipt -and $gateFile){$receipt.status='failed';$receipt.error='Maintenance failed; preserve backup and inspect maintenance logs.';try {Save-Json $gateFile $receipt} catch {}}
  $message='Maintenance failed at '+$script:maintenanceStage+'; code='+$script:maintenanceCode+'. HMI remains blocked. Diagnostic: '+$DiagnosticPath
  if(!$NoUI){Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show($message+"`r`nHMI has not been started. Re-run v10 maintenance to recover.",'Universal HMI v10 maintenance')|Out-Null}
  Write-Error $message -ErrorAction Continue
  exit 1
} finally {
  if($pgStarted){try {$null=Run-Tool (Join-Path $pgbin 'pg_ctl.exe') @('stop','-D',$cluster,'-m','fast','-w','-t','45') 'postgres-stop-finally'} catch {}}
  if($locked){$lock.ReleaseMutex()};if($lock){$lock.Dispose()}
}

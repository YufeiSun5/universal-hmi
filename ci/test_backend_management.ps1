# Run in a fresh PowerShell process. All process discovery is mocked; no live
# process is terminated and no installed service is controlled.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../packaging/windows-lazy/Backend-Management.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('hmi-management-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$data=Join-Path $root 'data'
$database=Join-Path $data 'database.json'
$server=Join-Path $root 'universal-hmi-server.exe'
$script:process=[pscustomobject]@{ProcessId=4242;Name='universal-hmi-server.exe';ExecutablePath=$server;CreationDate='first';CommandLine=('"'+$server+'" --data-dir "'+$data+'" --database-config "'+$database+'"')}
$script:stopped=$false
function Get-NetTCPConnection { param($LocalPort,$State) [pscustomobject]@{OwningProcess=4242} }
function Get-CimInstance { param($ClassName,$Filter) $script:process }
function Invoke-RestMethod { param($Uri,$TimeoutSec) @{service='universal-hmi';authentication_required=$true} }
function Stop-Process { param($Id) $script:stopped=$true; throw 'Test must never terminate a process' }
function Expect-Rejected([scriptblock]$Action,[string]$Code) {
  try {& $Action;throw 'Action unexpectedly accepted'} catch {if($_.Exception.Message -notmatch ('^'+$Code+':')){throw}}
  if($script:stopped){throw 'Unsafe process termination attempted'}
}
try {
  $arguments=[HmiManagementNative]::Arguments('app.exe --data-dir "C:\space dir\data" --database-config=C:\db.json')
  if((Get-HmiArgument $arguments '--data-dir') -ne 'C:\space dir\data'){throw 'Quoted argument not preserved'}
  if((Get-HmiArgument $arguments '--database-config') -ne 'C:\db.json'){throw 'Equals argument not preserved'}
  Expect-Rejected {Get-HmiArgument @('app.exe','--data-dir','C:\one','--data-dir=C:\two') '--data-dir'} 'project_identity'
  $owned=Get-HmiOwnedBackend $root $data $database 18247 $server
  if($owned.ProcessId -ne 4242){throw 'Exact project not recognized'}
  $original=$script:process.CommandLine
  $script:process.CommandLine=$original.Replace($data,$data+'-other')
  Expect-Rejected {Get-HmiOwnedBackend $root $data $database 18247 $server} 'foreign_project'
  $script:process.CommandLine=$original
  $script:process.Name='other.exe';$script:process.ExecutablePath=Join-Path $root 'other.exe'
  Expect-Rejected {Get-HmiOwnedBackend $root $data $database 18247 $server} 'port_in_use'
  $script:process.Name='universal-hmi-server.exe';$script:process.ExecutablePath=$server
  $snapshot=$script:process.PSObject.Copy()
  $script:process.CreationDate='reused-pid'
  Expect-Rejected {Stop-HmiOwnedBackend $snapshot} 'project_identity'
  $mutex=Enter-HmiManagement $root
  try {
    $childFile=Join-Path $root 'mutex.ps1'
    $helper=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../packaging/windows-lazy/Backend-Management.ps1'))
    [IO.File]::WriteAllText($childFile,(". '"+$helper.Replace("'","''")+"'`ntry { `$lock=Enter-HmiManagement '"+$root+"'; `$lock.ReleaseMutex(); `$lock.Dispose(); exit 1 } catch { if(`$_.Exception.Message -match '^operation_busy:'){exit 0}; exit 2 }"))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childFile
    if($LASTEXITCODE -ne 0){throw 'Concurrent entry was not rejected'}
  } finally {$mutex.ReleaseMutex();$mutex.Dispose()}
  Write-Output 'PASS: quoted/duplicate arguments, exact project, foreign project, other program, PID reuse and concurrent entry'
} finally {
  # Only known individual files in this newly created test directory.
  foreach($name in @('backend-project-id.txt','mutex.ps1')) {
    $path=Join-Path $root $name
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
  }
  Remove-Item -LiteralPath $root
}

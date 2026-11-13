# Shared by installed launcher, explicit-project launcher, desktop controls and
# installer maintenance. PowerShell 5.1; no process is selected by name alone.
if(-not ('HmiManagementNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class HmiManagementNative {
  [DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static string[] Arguments(string command) {
    int count; IntPtr block=CommandLineToArgvW(command,out count);
    if(block==IntPtr.Zero) throw new InvalidOperationException("Cannot parse process command line");
    try { string[] result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(block,i*IntPtr.Size)); return result; }
    finally { LocalFree(block); }
  }
  public static void VerifyListener(string host,int port,string fingerprint) {
    using(var tcp=new TcpClient()) {
      if(!tcp.ConnectAsync(host,port).Wait(5000)) throw new TimeoutException("LAN connection timeout");
      using(var ssl=new SslStream(tcp.GetStream(),false,(sender,cert,chain,errors)=> {
        if(cert==null || (errors & SslPolicyErrors.RemoteCertificateNameMismatch)!=0) return false;
        using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-","").Equals(fingerprint,StringComparison.OrdinalIgnoreCase);
      })) {
        if(!ssl.AuthenticateAsClientAsync(host,new X509CertificateCollection(),SslProtocols.Tls12,false).Wait(5000)) throw new TimeoutException("LAN TLS verification timeout");
      }
    }
  }
}
'@
}
function Get-HmiPath([string]$Path) {
  if(!$Path -or ![IO.Path]::IsPathRooted($Path)){throw 'project_identity: An absolute project path is required.'}
  return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Get-HmiFileHash([string]$Path) {
  $sha=[Security.Cryptography.SHA256]::Create()
  $stream=[IO.File]::OpenRead($Path)
  try {return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()} finally {$stream.Dispose();$sha.Dispose()}
}
function Get-HmiArgument([string[]]$Arguments,[string]$Name) {
  $values=@()
  for($index=1;$index -lt $Arguments.Count;$index++) {
    if($Arguments[$index] -eq $Name) {
      if($index+1 -ge $Arguments.Count){throw 'project_identity: Missing process argument.'}
      $values+= $Arguments[$index+1]; $index++
    } elseif($Arguments[$index].StartsWith($Name+'=')) {$values+=$Arguments[$index].Substring($Name.Length+1)}
  }
  if($values.Count -gt 1){throw 'project_identity: Duplicate process identity argument.'}
  if($values.Count){return $values[0]}
  return $null
}
function Get-HmiProjectId([string]$Root) {
  $path=Join-Path $Root 'backend-project-id.txt'
  if(!(Test-Path -LiteralPath $path)) {
    $id=[Guid]::NewGuid().ToString('D')
    try {
      $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      try {$bytes=[Text.Encoding]::UTF8.GetBytes($id);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    } catch [IO.IOException] {if(!(Test-Path -LiteralPath $path)){throw}}
  }
  $id=([IO.File]::ReadAllText($path)).Trim()
  $parsed=[Guid]::Empty
  if(![Guid]::TryParse($id,[ref]$parsed)){throw 'project_identity: Invalid project identity file.'}
  return $id
}
function Enter-HmiManagement([string]$Root,[int]$TimeoutMs=0) {
  $sha=[Security.Cryptography.SHA256]::Create()
  try {$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-HmiPath $Root).ToLowerInvariant())))).Replace('-','')} finally {$sha.Dispose()}
  $mutex=New-Object Threading.Mutex($false,('Global\UniversalHMILazy'+$id))
  try {$acquired=$mutex.WaitOne($TimeoutMs)} catch [Threading.AbandonedMutexException] {$acquired=$true}
  if(!$acquired){$mutex.Dispose();throw 'operation_busy: Another entry is managing this project. Please retry after it finishes.'}
  return $mutex
}
function Write-HmiManagementStatus([string]$File,[string]$Phase,[string]$Message='',[string]$Code='',[string]$Recovery='') {
  if(!$File){return}
  $value=@{phase=$Phase;message=$Message;error_code=$Code;recovery=$Recovery;at=(Get-Date -Format o)}
  $temporary=$File+'.tmp'
  [IO.File]::WriteAllText($temporary,($value|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $File -Force
}
function Get-HmiOwnedBackend([string]$Root,[string]$Data,[string]$Database,[int]$Port,[string]$ExpectedServer) {
  $Data=Get-HmiPath $Data; $Database=Get-HmiPath $Database
  $listeners=@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  $owners=@($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
  # Also reject a duplicate belonging to this project on another loopback port.
  $projectProcesses=@(Get-CimInstance Win32_Process -Filter "Name='universal-hmi-server.exe'" | Where-Object {
    if(!$_.CommandLine){return $false}
    $arguments=[HmiManagementNative]::Arguments($_.CommandLine)
    $argument=Get-HmiArgument $arguments '--data-dir'
    return $argument -and [IO.Path]::IsPathRooted($argument) -and (Get-HmiPath $argument) -eq $Data
  })
  if($projectProcesses.Count -gt 1){throw 'duplicate_backend: Multiple processes use this project; no process was stopped.'}
  if(!$owners.Count) {
    if(!$projectProcesses.Count){return $null}
    $owners=@($projectProcesses[0].ProcessId)
  }
  if($owners.Count -ne 1){throw "port_in_use: Port $Port has multiple owners; no process was stopped."}
  $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($owners[0])"
  $description="port $Port, program $($process.Name), PID $($owners[0])"
  if(!$process -or !$process.ExecutablePath -or !$process.CommandLine -or [IO.Path]::GetFileName($process.ExecutablePath) -ne 'universal-hmi-server.exe') {
    throw "port_in_use: $description. Choose another port or close that program through its own interface."
  }
  $arguments=[HmiManagementNative]::Arguments($process.CommandLine)
  $actualData=Get-HmiArgument $arguments '--data-dir'
  $actualDatabase=Get-HmiArgument $arguments '--database-config'
  if(!$actualData -or !$actualDatabase -or (Get-HmiPath $actualData) -ne $Data -or (Get-HmiPath $actualDatabase) -ne $Database) {
    throw "foreign_project: $description belongs to another project. No process was stopped."
  }
  $bundle=Split-Path -Parent $process.ExecutablePath
  $recognized=(Get-HmiPath $process.ExecutablePath) -eq (Get-HmiPath $ExpectedServer)
  $readyPath=Join-Path $Root 'ready.json'
  if(!$recognized -and (Test-Path -LiteralPath $readyPath)) {
    $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json
    $recognized=$ready.data -and $ready.bundle -and (Get-HmiPath $ready.data) -eq $Data -and (Get-HmiPath $ready.bundle) -eq (Get-HmiPath $bundle)
  }
  # Cross-version adoption requires a real packaged HMI manifest as well as the
  # exact data/database arguments, never merely a similarly named executable.
  if(!$recognized) {
    $manifest=Join-Path $bundle 'build-manifest.json'
    if(Test-Path -LiteralPath $manifest) {
      $value=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
      $recognized=$value.target -eq 'windows' -and $value.source_sha256 -match '^[a-f0-9]{64}$' -and $value.backend_sha256 -eq (Get-HmiFileHash $process.ExecutablePath)
    }
  }
  if(!$recognized){throw "project_identity: Cannot verify package ownership for $description. No process was stopped."}
  $expectedId=Get-HmiProjectId $Root
  $actualId=Get-HmiArgument $arguments '--project-id'
  if($actualId -and $actualId -ne $expectedId){throw 'foreign_project: Backend project identity differs. No process was stopped.'}
  if($actualId) {
    $deployment=$null
    try {$deployment=Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/local/deployment" -TimeoutSec 3} catch {}
    if($deployment -and ($deployment.project_id -ne $expectedId -or [int]$deployment.process_id -ne [int]$process.ProcessId -or (Get-HmiPath $deployment.data_directory) -ne $Data)) {throw 'project_identity: Running backend identity verification failed.'}
  } else {
    $health=$null
    try {$health=Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3} catch {}
    if($health -and ($health.service -ne 'universal-hmi' -or !$health.authentication_required)){throw 'project_identity: Legacy backend health identity differs.'}
  }
  return $process
}
function Stop-HmiOwnedBackend($Process,[int]$TimeoutSeconds=30) {
  if(!$Process){return}
  $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.ProcessId)"
  if(!$current){return}
  if($current.CreationDate -ne $Process.CreationDate -or $current.ExecutablePath -ne $Process.ExecutablePath -or $current.CommandLine -ne $Process.CommandLine){throw 'project_identity: Process changed after inspection; no process was stopped.'}
  $arguments=[HmiManagementNative]::Arguments($current.CommandLine)
  $eventName=Get-HmiArgument $arguments '--shutdown-event'
  if($eventName) {
    $event=[Threading.EventWaitHandle]::OpenExisting($eventName)
    try {$null=$event.Set()} finally {$event.Dispose()}
  } else {
    # Legacy releases have no graceful control channel. The exact verified
    # process is terminated; the database is kept until its exit is confirmed.
    Stop-Process -Id $current.ProcessId -ErrorAction Stop
  }
  $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $remaining=Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.ProcessId)"
    if(!$remaining -or $remaining.CreationDate -ne $Process.CreationDate){return}
    Start-Sleep -Milliseconds 150
  } while((Get-Date) -lt $deadline)
  throw 'stop_timeout: Backend did not stop in time. Database remains running; a second backend was not started.'
}
function Get-HmiProjectService([string]$Root) {
  $configuration=Get-HmiPath (Join-Path $Root 'service-host.json')
  $matches=@(Get-CimInstance Win32_Service | Where-Object {
    if(!$_.PathName){return $false}
    $arguments=[HmiManagementNative]::Arguments($_.PathName)
    $path=Get-HmiArgument $arguments '--config'
    return $path -and [IO.Path]::IsPathRooted($path) -and (Get-HmiPath $path) -eq $configuration
  })
  if($matches.Count -ne 1){throw 'service_identity: Exactly one Windows service must reference this project configuration.'}
  return $matches[0]
}
function Invoke-HmiServiceTransition($Service,[string]$Action,[string]$StatusFile) {
  $controller=Get-Service -Name $Service.Name -ErrorAction Stop
  if($Action -in @('Stop','Restart') -and $controller.Status -ne 'Stopped') {
    Write-HmiManagementStatus $StatusFile 'stopping' '正在停止本工程 Windows 服务'
    $controller.Stop()
    try {$controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))} catch {throw 'stop_timeout: Windows service did not stop; no second backend was started.'}
  }
  if($Action -ne 'Stop' -and $controller.Status -ne 'Running') {
    Write-HmiManagementStatus $StatusFile 'starting' '正在启动本工程 Windows 服务'
    $controller.Start()
    try {$controller.WaitForStatus('Running',[TimeSpan]::FromSeconds(60))} catch {throw 'start_failed: Windows service did not reach Running.'}
  }
}
function Assert-HmiLANActual([string]$Base,[string]$Data) {
  $actual=Invoke-RestMethod "$Base/api/v1/local/deployment" -TimeoutSec 3
  if($actual.PSObject.Properties.Name -contains 'lan_in_sync' -and !$actual.lan_in_sync){
    $code=if($actual.lan_error_code){$actual.lan_error_code}else{'lan_apply_failed'}
    throw ($code+': '+$actual.lan_error)
  }
  $path=Join-Path $Data 'lan-access.json'
  if(!(Test-Path -LiteralPath $path)){return}
  $config=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if(!$config.enabled){return}
  if([IO.Path]::GetFileName($config.certificate) -ne $config.certificate){throw 'certificate_failed: Invalid LAN certificate path.'}
  $pem=[IO.File]::ReadAllText((Join-Path (Join-Path $Data 'lan-certificates') $config.certificate))
  $der=[Convert]::FromBase64String(($pem -replace '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s',''))
  $hash=[Security.Cryptography.SHA256]::Create()
  try {$fingerprint=([BitConverter]::ToString($hash.ComputeHash($der))).Replace('-','')} finally {$hash.Dispose()}
  try {[HmiManagementNative]::VerifyListener($config.address,[int]$config.port,$fingerprint)} catch {throw ('lan_apply_failed: '+$_.Exception.Message)}
  $managementOwners=@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([Uri]$Base).Port -State Listen -ErrorAction Stop|Select-Object -ExpandProperty OwningProcess -Unique)
  $lanOwners=@(Get-NetTCPConnection -LocalAddress $config.address -LocalPort ([int]$config.port) -State Listen -ErrorAction Stop|Select-Object -ExpandProperty OwningProcess -Unique)
  if($managementOwners.Count -ne 1 -or $lanOwners.Count -ne 1 -or $managementOwners[0] -ne $lanOwners[0]){throw 'lan_apply_failed: LAN listener does not belong to this backend.'}
}
function Restore-HmiLANConfiguration([string]$Data) {
  $checkpoint=Join-Path $Data 'lan-last-working.json'
  if(!(Test-Path -LiteralPath $checkpoint)){return $false}
  $restore=Get-Content -LiteralPath $checkpoint -Raw|ConvertFrom-Json
  if($restore.schema -ne 1){throw 'restore_failed: Invalid LAN recovery checkpoint.'}
  $path=Join-Path $Data 'lan-access.json'
  $revision=0
  if(Test-Path -LiteralPath $path) {
    $saved=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $revision=[long]$saved.revision
    [IO.File]::WriteAllText((Join-Path $Data 'lan-failed-apply.json'),($saved|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
  }
  $restore.revision=$revision+1
  $temporary=$path+'.restore.tmp'
  [IO.File]::WriteAllText($temporary,($restore|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $path -Force
  return $true
}

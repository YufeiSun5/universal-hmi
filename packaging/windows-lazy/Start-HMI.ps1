param(
  [ValidateSet('runtime','developer')][string]$View='runtime',
  [string]$ProjectRoot=(Join-Path $env:LOCALAPPDATA 'UniversalHMI\project'),
  [string]$LegacyRoot=(Join-Path $env:LOCALAPPDATA 'universal-hmi-mqtt-gis-trial-20261026-v2'),
  [switch]$NoUI,
  [switch]$Stop,
  [switch]$Restart,
  [string]$StatusFile,
  [switch]$InstalledMaintenance
)
# Windows PowerShell 5.1. All database business migration belongs to the Go CLI.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Remote-Access.ps1')
. (Join-Path $PSScriptRoot 'Backend-Management.ps1')
. (Join-Path $PSScriptRoot 'Startup-Window.ps1')
$bundle=$PSScriptRoot
$utf8=New-Object System.Text.UTF8Encoding($false)
$lock=$null
$locked=$false
function Write-Json($Path,$Value) {
  $temp=$Path+'.tmp'
  [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 12),$utf8)
  Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Assert-MaintenanceReady {
  # The receipt is outside the project: the cold backup contains the complete original tree.
  $gateHash=[Security.Cryptography.SHA256]::Create()
  try {$gateId=([BitConverter]::ToString($gateHash.ComputeHash($utf8.GetBytes($ProjectRoot.ToLowerInvariant())))).Replace('-','')} finally {$gateHash.Dispose()}
  $gateFile=Join-Path (Join-Path (Split-Path -Parent $ProjectRoot) 'project-maintenance') ($gateId+'\process-rebuild-v10.json')
  if(!$Stop -and (Test-Path -LiteralPath $gateFile)) {
    $gate=Get-Content -LiteralPath $gateFile -Raw | ConvertFrom-Json
    if($gate.status -ne 'applied' -or $gate.project_root -ne $ProjectRoot) {
      throw 'The v10 project rebuild is pending or failed. Keep the backup and rerun the v10 maintenance installer before starting HMI.'
    }
  }

}
function New-Secret {
  $bytes=New-Object byte[] 32
  $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
  try {$rng.GetBytes($bytes)} finally {$rng.Dispose()}
  return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
}
function Free-Port([int]$Preferred) {
  $socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Preferred)
  try {$socket.Start(); return $Preferred} catch {
    $socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $socket.Start(); return $socket.LocalEndpoint.Port
  } finally {$socket.Stop()}
}
function Log($Text) {
  $line=('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$Text)
  Add-Content -LiteralPath (Join-Path $ProjectRoot 'setup.log') -Value $line -Encoding UTF8
  if($NoUI){Write-Host $line}
  if(!$NoUI -and !$Stop) {
    $phase=switch -Wildcard ($Text) {
      '*Checking local*' {'正在核对工程与数据库'; break}
      '*Starting private*' {'正在启动本机数据库'; break}
      '*Importing and verifying*' {'正在迁移并核验工程数据'; break}
      '*Project ready*' {'准备就绪，正在打开监控界面'; break}
      default {'正在连接本机服务'}
    }
    Update-HmiStartupWindow $phase
  }
}
function Run-Native($Exe,$Arguments,$LogName) {
  $quoted=($Arguments | ForEach-Object {'"'+([string]$_).Replace('"','\"')+'"'}) -join ' '
  $process=Start-Process -FilePath $Exe -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ProjectRoot ($LogName+'.out')) -RedirectStandardError (Join-Path $ProjectRoot ($LogName+'.err'))
  $null=$process.Handle
  # pg_ctl deliberately leaves postgres running. Wait only for the launcher,
  # never for its descendant process tree or inherited pipe handles.
  if(!$process.WaitForExit(120000)){throw "Command timed out: $(Split-Path $Exe -Leaf). See $LogName.*."}
  if($process.ExitCode -ne 0){throw "Command failed: $(Split-Path $Exe -Leaf). See $LogName.*."}
}
function Sql($Database,$Query) {
  $sqlFile=Join-Path $ProjectRoot 'bootstrap.sql'
  [IO.File]::WriteAllText($sqlFile,$Query,$utf8)
  $prior=$env:PGPASSWORD
  try {
    $env:PGPASSWORD=$state.adminPassword
    $result=& (Join-Path $pgbin 'psql.exe') -X -w -h 127.0.0.1 -p $state.pgPort -U hmi_admin -d $Database -A -t -v ON_ERROR_STOP=1 -f $sqlFile 2>&1
    if($LASTEXITCODE -ne 0){throw 'PostgreSQL initialization query failed. Existing data has been retained.'}
    return ($result | Out-String).Trim()
  } finally {
    $env:PGPASSWORD=$prior
    Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
  }
}
function Tree-Hash($Path) {
  $items=Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName
  return (($items | ForEach-Object {
    $stream=[IO.File]::OpenRead($_.FullName)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$sum=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')} finally {$stream.Dispose();$hash.Dispose()}
    $_.FullName.Substring($Path.Length)+':'+$sum
  }) -join "`n")
}
function Owned-Server {
  return Get-HmiOwnedBackend $ProjectRoot $data $databaseConfig ([int]$state.httpPort) $server
}
function Backend-Phase([string]$Phase,[string]$Message) {
  Write-HmiManagementStatus $StatusFile $Phase $Message
}
function Wait-Backend([string]$Base,$Process,[bool]$VerifyLAN=$false,[string]$LanData) {
  for($attempt=0;$attempt -lt 60;$attempt++) {
    try {
      $health=Invoke-RestMethod "$Base/health" -TimeoutSec 1
      if($health.service -eq 'universal-hmi' -and $health.authentication_required) {
        if($VerifyLAN) {
          Assert-HmiLANActual $Base $LanData
        }
        return
      }
    } catch {
      if($_.Exception.Message -match '^(lan_apply_failed|certificate_failed|invalid_address|port_in_use|permission_denied):'){throw}
    }
    if($Process -and $Process.HasExited){throw 'start_failed: Backend exited before becoming healthy.'}
    Start-Sleep -Milliseconds 500
  }
  throw 'start_failed: Backend health verification timed out.'
}

try {
  if(!$NoUI -and !$Stop) {
    Start-HmiStartupWindow (Join-Path $bundle 'universal_hmi.exe') $View
  }
  $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $LegacyRoot=[IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\')
  if($InstalledMaintenance) {
    if(!$Stop -or !$NoUI){throw 'invalid_operation: Installed maintenance only stops a background.'}
    $readyPath=Join-Path $ProjectRoot 'ready.json'
    if(!(Test-Path -LiteralPath $readyPath)){exit 0}
    $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json
    if((Get-HmiPath $ready.data) -ne (Get-HmiPath (Join-Path $ProjectRoot 'data'))){throw 'project_identity: Installed project differs.'}
    $bundle=Get-HmiPath $ready.bundle
  }
  if($Stop -and $Restart){throw 'invalid_operation: Choose either stop or restart.'}
  if($Restart -or $Stop) {
    if(!(Test-Path -LiteralPath $ProjectRoot)){throw 'project_missing: Project is not initialized.'}
    if(!$StatusFile){$StatusFile=Join-Path $ProjectRoot 'backend-operation.json'}
    Backend-Phase 'preparing' '正在核对工程和后台归属'
  }
  if((Test-Path -LiteralPath (Join-Path $ProjectRoot 'service-host.json')) -and ($Stop -or $Restart)) {
    $administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(!$administrator) {
      $action=if($Stop){'-Stop'}else{'-Restart'}
      $arguments=@('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ProjectRoot',('"'+$ProjectRoot+'"'),'-NoUI',$action,'-StatusFile',('"'+$StatusFile+'"'))
      try {$elevated=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru; $elevated.WaitForExit();exit $elevated.ExitCode} catch {throw 'permission_denied: Windows service control requires administrator approval; no service was changed.'}
    }
  }
  $lock=Enter-HmiManagement $ProjectRoot $(if($Restart -or $Stop){0}else{120000})
  $locked=$true
  Assert-MaintenanceReady
  if($ProjectRoot -eq $LegacyRoot -or $ProjectRoot.StartsWith($LegacyRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $LegacyRoot.StartsWith($ProjectRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The new project and the legacy source must be separate directories.'
  }
  if(Test-Path -LiteralPath (Join-Path $ProjectRoot 'service-host.json')) {
    $service=Get-HmiProjectService $ProjectRoot
    $serviceProject=Get-Content -LiteralPath (Join-Path $ProjectRoot 'project.json') -Raw | ConvertFrom-Json
    $serviceBase="http://127.0.0.1:$([int]$serviceProject.port)"
    $serviceRemote=Resolve-RemoteConfig $serviceProject $ProjectRoot
    $action=if($Stop){'Stop'}elseif($Restart){'Restart'}else{'Start'}
    Invoke-HmiServiceTransition $service $action $StatusFile
    if($Stop){Backend-Phase 'stopped' '本工程 Windows 服务已停止，数据保留';exit 0}
    Backend-Phase 'verifying' '正在验证后台健康和实际监听'
    Wait-Backend $serviceBase $null ([bool]($Restart -or $StatusFile)) $serviceProject.data
    Assert-RemoteDeployment $serviceBase $serviceRemote
    Backend-Phase 'applied' '后台和内网监听已验证；原会话失效时请重新登录'
    if(!$NoUI){
      $env:HMI_API_BASE_URL="$serviceBase/"
      $env:HMI_PROJECT_DIR=[IO.Path]::GetFullPath($serviceProject.data)
      Start-Process -FilePath $serviceProject.app -ArgumentList "--view=$View --local-only" -WorkingDirectory (Split-Path -Parent $serviceProject.app)
    }
    Log 'Reused Windows Service background; launcher did not start PostgreSQL/backend.'
    exit 0
  }
  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
  # Credentials, identity keys and the cluster are private to this Windows user.
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl=[IO.Directory]::GetAccessControl($ProjectRoot,[Security.AccessControl.AccessControlSections]::Access)
  $acl.SetAccessRuleProtection($true,$false)
  foreach($existing in @($acl.Access)){$acl.RemoveAccessRuleSpecific($existing)}
  foreach($identity in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
  }
  [IO.Directory]::SetAccessControl($ProjectRoot,$acl)
  Assert-MaintenanceReady
  $statePath=Join-Path $ProjectRoot 'private-settings.json'
  $data=Join-Path $ProjectRoot 'data'
  $databaseConfig=Join-Path $data 'database.json'
  $cluster=Join-Path $ProjectRoot 'postgres-data'
  $pgbin=Join-Path $bundle 'postgresql\bin'
  $server=Join-Path $bundle 'universal-hmi-server.exe'
  $app=Join-Path $bundle 'universal_hmi.exe'
  foreach($file in @($server,$app,(Join-Path $pgbin 'pg_ctl.exe'),(Join-Path $pgbin 'initdb.exe'),(Join-Path $pgbin 'psql.exe'))) {
    if(!(Test-Path -LiteralPath $file)){throw 'The application/PostgreSQL package is incomplete. Reinstall the full offline package.'}
  }
  if(!(Test-Path -LiteralPath $statePath)) {
    if($Stop){Log 'No initialized background to stop.'; exit 0}
    if(Test-Path -LiteralPath $cluster){throw 'A cluster exists without its private settings. Restore the project backup; do not initialize over existing data.'}
    $state=[pscustomobject]@{schema=1;pgMajor=18;pgPort=(Free-Port 55432);httpPort=(Free-Port 18080);adminPassword=(New-Secret);appPassword=(New-Secret)}
    Write-Json $statePath $state
  } else {$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json}
  if($state.schema -ne 1 -or $state.pgMajor -ne 18){throw 'Unsupported project/PG version. Keep this project and use its matching installer.'}
  $base="http://127.0.0.1:$($state.httpPort)"
  if($Stop) {
    $owned=Owned-Server
    Backend-Phase 'stopping' '正在停止本工程后台'
    if($owned){Stop-HmiOwnedBackend $owned; Log 'HMI background stopped.'}
    if(Test-Path -LiteralPath (Join-Path $cluster 'PG_VERSION')) {
      & (Join-Path $pgbin 'pg_ctl.exe') status -D $cluster *> $null
      if($LASTEXITCODE -eq 0){Run-Native (Join-Path $pgbin 'pg_ctl.exe') @('stop','-D',$cluster,'-m','fast','-w','-t','30') 'postgres-control.log'}
    }
    Log 'PostgreSQL stopped; all project data retained.'
    Backend-Phase 'stopped' '后台与数据库已停止，工程数据保留'
    exit 0
  }
  $previousBackend=$null
  if($Restart) {
    if(!(Test-Path -LiteralPath $data) -or !(Test-Path -LiteralPath $databaseConfig)){throw 'project_missing: Restart will not initialize a new project.'}
    $previousBackend=Owned-Server
    Backend-Phase 'stopping' '正在停止本工程后台，数据库保持运行'
    Stop-HmiOwnedBackend $previousBackend
    Backend-Phase 'starting' '正在启动后台并应用已保存配置'
  }
  Log 'Checking local PostgreSQL and project...'
  if(!(Test-Path -LiteralPath (Join-Path $cluster 'PG_VERSION'))) {
    # Initialize in a staging directory. A crash never turns a partial cluster into a ready one.
    $staging=Join-Path $ProjectRoot ('postgres-init-'+[Guid]::NewGuid().ToString('N'))
    $pwfile=Join-Path $ProjectRoot 'init-password.tmp'
    try {
      [IO.File]::WriteAllText($pwfile,$state.adminPassword,$utf8)
      Run-Native (Join-Path $pgbin 'initdb.exe') @('-D',$staging,'-U','hmi_admin','--pwfile',$pwfile,'--auth=scram-sha-256','--encoding=UTF8','--locale=C') 'postgres-init.log'
      $config="`nlisten_addresses = '127.0.0.1'`nport = $($state.pgPort)`npassword_encryption = 'scram-sha-256'`nmax_connections = 30`nshared_buffers = '128MB'`n"
      [IO.File]::AppendAllText((Join-Path $staging 'postgresql.conf'),$config,$utf8)
      Move-Item -LiteralPath $staging -Destination $cluster
    } finally {Remove-Item -LiteralPath $pwfile -Force -ErrorAction SilentlyContinue}
  }
  if((Get-Content -LiteralPath (Join-Path $cluster 'PG_VERSION') -Raw).Trim() -ne '18'){throw 'PostgreSQL major version mismatch.'}
  & (Join-Path $pgbin 'pg_ctl.exe') status -D $cluster *> $null
  if($LASTEXITCODE -ne 0) {
    if(Get-NetTCPConnection -LocalPort $state.pgPort -State Listen -ErrorAction SilentlyContinue){throw 'The private PostgreSQL port is occupied. No other database has been modified.'}
    Log 'Starting private PostgreSQL...'
    Run-Native (Join-Path $pgbin 'pg_ctl.exe') @('start','-D',$cluster,'-l',(Join-Path $ProjectRoot 'postgres.log'),'-w','-t','45') 'postgres-control.log'
  }
  # Authentication plus the actual data directory prevents adopting an unrelated PG.
  $actualCluster=Sql 'postgres' 'SHOW data_directory;'
  if([IO.Path]::GetFullPath($actualCluster).TrimEnd('\') -ne $cluster){throw 'PostgreSQL project identity mismatch.'}
  if((Sql 'postgres' "SELECT count(*) FROM pg_roles WHERE rolname='hmi_app';") -eq '0') {
    $null=Sql 'postgres' "CREATE ROLE hmi_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$($state.appPassword)';"
  }
  if((Sql 'postgres' "SELECT count(*) FROM pg_database WHERE datname='universal_hmi';") -eq '0') {
    $null=Sql 'postgres' 'CREATE DATABASE universal_hmi OWNER hmi_app;'
  }
  $snapshot=Join-Path $ProjectRoot 'legacy-backup'
  if(!(Test-Path -LiteralPath $data)) {
    if((Test-Path -LiteralPath $LegacyRoot) -and !(Test-Path -LiteralPath $snapshot)) {
      $old=@(Get-CimInstance Win32_Process -Filter "Name='universal-hmi-server.exe' OR Name='universal_hmi.exe'" | Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($LegacyRoot) -or $_.ExecutablePath -like '*Universal HMI MQTT GIS Trial*') })
      if($old.Count){throw 'Close yesterday''s HMI application and its background before migration. The original data is unchanged.'}
      if(Test-Path -LiteralPath (Join-Path $LegacyRoot 'database.json')){throw 'The legacy project already uses a database configuration; automatic SQLite migration has been stopped.'}
      Log 'Backing up yesterday''s project...'
      $before=Tree-Hash $LegacyRoot
      $copy=Join-Path $ProjectRoot ('legacy-copy-'+[Guid]::NewGuid().ToString('N'))
      Copy-Item -LiteralPath $LegacyRoot -Destination $copy -Recurse
      if((Tree-Hash $LegacyRoot) -cne $before -or (Tree-Hash $copy) -cne $before){throw 'Legacy files changed during backup. Close the old application and retry.'}
      Move-Item -LiteralPath $copy -Destination $snapshot
      Write-Json (Join-Path $ProjectRoot 'legacy-source.json') @{source=$LegacyRoot;backedUpAt=(Get-Date -Format o)}
    }
    $copy=Join-Path $ProjectRoot ('data-copy-'+[Guid]::NewGuid().ToString('N'))
    if(Test-Path -LiteralPath $snapshot){Copy-Item -LiteralPath $snapshot -Destination $copy -Recurse} else {New-Item -ItemType Directory -Path $copy | Out-Null}
    Move-Item -LiteralPath $copy -Destination $data
  }
  if(!(Test-Path -LiteralPath $databaseConfig)) {
    Write-Json $databaseConfig @{dsn="postgres://hmi_app:$($state.appPassword)@127.0.0.1:$($state.pgPort)/universal_hmi?sslmode=disable"}
  }
  # The backend commits this marker atomically with imported rows. A crash between
  # database commit and launcher completion therefore does not repeat the import.
  $migrated=$false
  if((Sql 'universal_hmi' "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='config';") -eq '1') {
    $migrated=(Sql 'universal_hmi' "SELECT count(*) FROM config WHERE key='postgres_migration' AND value='{`"completed`":true}';") -eq '1'
  }
  if(!$migrated) {
    Log 'Importing and verifying project data...'
    Run-Native $server @('--listen','127.0.0.1:0','--data-dir',$data,'--database-config',$databaseConfig,'--migrate-sqlite') 'migration.log'
    if((Sql 'universal_hmi' "SELECT count(*) FROM config WHERE key='postgres_migration';") -ne '1'){throw 'The backend did not commit the migration marker.'}
  }
  $projectPath=Join-Path $ProjectRoot 'project.json'
  if(!(Test-Path -LiteralPath $projectPath)){Write-Json $projectPath @{schema=1;remoteConfig='remote-access.json'}}
  $remoteTemplate=Join-Path $ProjectRoot 'remote-access.json'
  if(!(Test-Path -LiteralPath $remoteTemplate)){Write-Json $remoteTemplate @{schema=2;enabled=$false;web_allowlist=@();mobile_enabled=$false;origin='';listen='0.0.0.0:18443';certificate='certificates/server-cert.pem';private_key='certificates/server-key.pem'}}
  $project=Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json
  $remoteConfig=Resolve-RemoteConfig $project $ProjectRoot
  $base="http://127.0.0.1:$($state.httpPort)"
  $owned=Owned-Server
  if(!$owned) {
    $managedProjectId=Get-HmiProjectId $ProjectRoot
    $shutdownName='Global\UniversalHMIStop-'+[Guid]::NewGuid().ToString('N')
    $shutdownHandle=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$shutdownName)
    $arguments=@('--listen',"127.0.0.1:$($state.httpPort)",'--data-dir',('"'+$data+'"'),'--web-dir',('"'+(Join-Path $bundle 'web')+'"'),'--database-config',('"'+$databaseConfig+'"'),'--identity','--identity-local-setup','--public-origin',$base,'--project-id',$managedProjectId,'--shutdown-event',$shutdownName)
    if($remoteConfig){$arguments+=@('--remote-config',('"'+$remoteConfig+'"'))}
    $child=Start-Process -FilePath $server -ArgumentList $arguments -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ProjectRoot 'server-out.log') -RedirectStandardError (Join-Path $ProjectRoot 'server-error.log')
  }
  Backend-Phase 'verifying' '正在验证后台健康和实际内网监听'
  Wait-Backend $base $child ([bool]($Restart -or $StatusFile)) $data
  Assert-RemoteDeployment $base $remoteConfig
  Backend-Phase 'applied' '后台已生效；连接恢复后请重新登录'
  Write-Json (Join-Path $ProjectRoot 'ready.json') @{url=$base;bundle=$(if($owned){Split-Path -Parent $owned.ExecutablePath}else{$bundle});data=$data;postgresPort=$state.pgPort;view=$View;readyAt=(Get-Date -Format o)}
  Log "Project ready: $base"
  if(!$NoUI) {
    $env:HMI_API_BASE_URL="$base/"
    $env:HMI_PROJECT_DIR=[IO.Path]::GetFullPath($data)
    Start-Process -FilePath $app -ArgumentList "--view=$View --local-only" -WorkingDirectory $bundle
  }
} catch {
  Close-HmiStartupWindow
  $failure=$_.Exception.Message
  $recovery=''
  if($Restart -and $previousBackend -and $failure -notmatch 'stop_timeout|operation_busy|foreign_project|project_identity') {
    try {
      Backend-Phase 'restoring' '正在尝试恢复原可用后台与内网配置'
      $newOwned=Owned-Server
      Stop-HmiOwnedBackend $newOwned
      $null=Restore-HmiLANConfiguration $data
      $oldArguments=@([HmiManagementNative]::Arguments($previousBackend.CommandLine)|Select-Object -Skip 1)
      $oldShutdown=Get-HmiArgument ([HmiManagementNative]::Arguments($previousBackend.CommandLine)) '--shutdown-event'
      if($oldShutdown){$restoreEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$oldShutdown);$null=$restoreEvent.Reset()}
      $quoted=($oldArguments|ForEach-Object {'"'+$_.Replace('"','\"')+'"'}) -join ' '
      $restored=Start-Process -FilePath $previousBackend.ExecutablePath -ArgumentList $quoted -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ProjectRoot 'server-out.log') -RedirectStandardError (Join-Path $ProjectRoot 'server-error.log')
      Wait-Backend $base $restored $true $data
      $recovery='previous_backend_restored'
    } catch {$recovery='restore_failed';$failure+='; restore: '+$_.Exception.Message}
  }
  if($Restart -and $service -and $failure -notmatch 'stop_timeout|operation_busy|foreign_project|project_identity|permission_denied|Access|denied|拒绝') {
    try {
      Backend-Phase 'restoring' '正在恢复服务的原内网配置'
      Invoke-HmiServiceTransition $service 'Stop' $StatusFile
      $null=Restore-HmiLANConfiguration $serviceProject.data
      Invoke-HmiServiceTransition $service 'Start' $StatusFile
      Wait-Backend $serviceBase $null $true $serviceProject.data
      $recovery='previous_backend_restored'
    } catch {$recovery='restore_failed';$failure+='; restore: '+$_.Exception.Message}
  }
  $code=if($failure -match '^([a-z_]+):'){$Matches[1]}elseif($failure -match 'Access|denied|拒绝'){'permission_denied'}else{'start_failed'}
  Write-HmiManagementStatus $StatusFile 'failed' $failure $code $recovery
  $message=$failure+"`r`nProject and logs: "+$ProjectRoot
  try {Log ('FAILED: '+$_.Exception.Message)} catch {}
  if($NoUI){Write-Error $message -ErrorAction Continue} else {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($message,'智慧供热集中监控系统启动失败') | Out-Null
  }
  exit 1
} finally {
  Close-HmiStartupWindow
  if($shutdownHandle){$shutdownHandle.Dispose()}
  if($restoreEvent){$restoreEvent.Dispose()}
  if($locked){$lock.ReleaseMutex()}
  if($lock){$lock.Dispose()}
}

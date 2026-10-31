param(
  [ValidateSet('runtime','developer')][string]$View='runtime',
  [Parameter(Mandatory=$true)][string]$ProjectConfig
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Remote-Access.ps1')
try {
  $serviceManaged=Test-Path -LiteralPath (Join-Path (Split-Path -Parent $ProjectConfig) 'service-host.json')
  $project = Get-Content -LiteralPath $ProjectConfig -Raw | ConvertFrom-Json
  foreach($name in @('app','server','web','data','databaseConfig')) {
    if (!(Test-Path -LiteralPath $project.$name)) { throw "工程启动文件不存在：$name" }
  }
  $remoteConfig=Resolve-RemoteConfig $project (Split-Path -Parent ([IO.Path]::GetFullPath($ProjectConfig)))
  $port=[int]$project.port
  if($port -lt 1024 -or $port -gt 65535){throw '工程端口无效'}
  $base="http://127.0.0.1:$port"
  $launchLock=New-Object System.Threading.Mutex($false,"Local\UniversalHMIProject$port")
  if(!$launchLock.WaitOne(15000)){throw '另一个入口正在启动工程，请稍后重试'}
  try {
    $listener=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if($listener) {
      $owner=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
      if($owner.ExecutablePath -ne $project.server -or !$owner.CommandLine.Contains($project.data) -or !$owner.CommandLine.Contains($project.databaseConfig)) {
        throw '工程端口由其他程序或工程使用，请先检查该服务。'
      }
    } else {
      if($serviceManaged){throw '此工程由Windows服务管理。服务尚未就绪，请管理员检查并启动对应服务；入口不会启动第二个后台。'}
      $logDir=Split-Path -Parent $ProjectConfig
      $arguments=@('--listen',"127.0.0.1:$port",'--data-dir',('"'+$project.data+'"'),'--web-dir',('"'+$project.web+'"'),'--database-config',('"'+$project.databaseConfig+'"'),'--identity','--identity-local-setup','--public-origin',$base)
      if($remoteConfig){$arguments+=@('--remote-config',('"'+$remoteConfig+'"'))}
      $child=Start-Process -FilePath $project.server -ArgumentList $arguments -WorkingDirectory $logDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logDir 'server-out.log') -RedirectStandardError (Join-Path $logDir 'server-error.log')
    }
    $ready=$false
    for($i=0;$i -lt 30;$i++) {
      try {
        $health=Invoke-RestMethod "$base/health" -TimeoutSec 1
        if($health.service -eq 'universal-hmi' -and $health.authentication_required){$ready=$true;break}
      } catch {}
      if($child -and $child.HasExited){break}
      Start-Sleep -Milliseconds 300
    }
    if($ready){Assert-RemoteDeployment $base $remoteConfig}
    if(!$ready){throw '工程服务未就绪。请检查本机 PostgreSQL 是否运行，以及工程目录中的 server-error.log。'}
  } finally {
    $launchLock.ReleaseMutex()
    $launchLock.Dispose()
  }
  $env:HMI_API_BASE_URL="$base/"
  $env:HMI_PROJECT_DIR=[IO.Path]::GetFullPath($project.data)
  Start-Process -FilePath $project.app -ArgumentList "--view=$View --local-only" -WorkingDirectory (Split-Path -Parent $project.app)
} catch {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Universal HMI 启动失败') | Out-Null
  exit 1
}


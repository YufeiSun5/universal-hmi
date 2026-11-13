param([Parameter(Mandatory=$true)][string]$ProjectRoot,[switch]$Background)
$ErrorActionPreference='Stop'
try {
  if(![IO.Path]::IsPathRooted($ProjectRoot) -or $ProjectRoot -match '["\r\n]'){throw 'Invalid project path.'}
  $payload=([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'active-payload.txt'))).Trim()
  if($payload -notmatch '^[A-Za-z0-9_.-]+$' -or $payload -in @('.','..')){throw 'Invalid installed payload identity.'}
  $bundle=Join-Path (Join-Path $PSScriptRoot 'versions') $payload
  $script=Join-Path $bundle 'Start-HMI.ps1'
  if(!(Test-Path -LiteralPath $script)){throw 'Installed startup entry missing.'}
  $parameters=@('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$script,'-ProjectRoot',$ProjectRoot,'-View','runtime')
  if($Background){$parameters+='-NoUI'}
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @parameters
  $result=$LASTEXITCODE
  if($result -ne 0){exit $result}
  # Keep the scheduled job alive while its owned backend runs. Disabling future
  # startup does not stop an active project; normal Stop remains authoritative.
  if($Background) {
    . (Join-Path $bundle 'Backend-Management.ps1')
    $project=Get-Content -LiteralPath (Join-Path $ProjectRoot 'project.json') -Raw|ConvertFrom-Json
    if(!(Test-Path -LiteralPath (Join-Path $ProjectRoot 'service-host.json'))) {
      $owned=Get-HmiOwnedBackend $ProjectRoot $project.data $project.databaseConfig ([int]$project.port) $project.server
      if($owned){Wait-Process -Id $owned.ProcessId -ErrorAction SilentlyContinue}
    }
  }
  exit 0
} catch {
  # No credentials or connection strings are included in this operational log.
  if(Test-Path -LiteralPath $ProjectRoot){[IO.File]::AppendAllText((Join-Path $ProjectRoot 'autostart.log'),((Get-Date -Format o)+' startup failed: '+$_.Exception.Message+"`r`n"),(New-Object Text.UTF8Encoding($false)))}
  exit 1
}

param(
 [ValidateSet('runtime','developer')][string]$View='runtime',
 [switch]$ConnectionSettings
)
$ErrorActionPreference='Stop'
$app=Join-Path $PSScriptRoot 'universal_hmi.exe'
if(!(Test-Path -LiteralPath $app)){throw 'Remote client executable is missing.'}
$arguments=@("--view=$View",'--remote-only')
if($ConnectionSettings){$arguments+='--connection-settings'}
Start-Process -FilePath $app -ArgumentList $arguments -WorkingDirectory $PSScriptRoot

param([ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$Name='UniversalHMI')
$ErrorActionPreference='Stop'
$service=Get-CimInstance Win32_Service -Filter "Name='$Name'"
if(!$service){throw 'Service not found.'}
if($service.PathName -notmatch '(?i)service-host\.exe"?\s+--config\s+'){throw 'Refusing to remove a service that is not a Universal HMI service host.'}
Stop-Service -Name $Name
$current=Get-Service -Name $Name
$current.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(120))
& sc.exe delete $Name
if($LASTEXITCODE -ne 0){throw 'Service removal failed.'}
Write-Output 'Service registration removed. Project/database files, configuration and ACLs retained. Review service-host.log before restarting PostgreSQL manually.'

param(
 [Parameter(Mandatory=$true)][string]$ServiceBundleRoot,
 [Parameter(Mandatory=$true)][string]$ServiceHost,
 [Parameter(Mandatory=$true)][string]$ProjectConfig,
 [Parameter(Mandatory=$true)][string]$PostgresBin,
 [Parameter(Mandatory=$true)][string]$PostgresData,
 [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$Name='UniversalHMI',
 [switch]$Start
)
$ErrorActionPreference='Stop'
function Assert-NoReparseAncestor([string]$Path) {
 $cursor=[IO.Path]::GetFullPath($Path)
 while($cursor) {
  $item=Get-Item -LiteralPath $cursor -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse-point paths are not allowed: $cursor"}
  $parent=Split-Path -Parent $cursor
  if(!$parent -or $parent -eq $cursor){break}
  $cursor=$parent
 }
}
function Test-Within([string]$Parent,[string]$Path) {
 return $Path.StartsWith($Parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-SafeAcl([string]$Path,[bool]$AllowServiceWrite,[bool]$Ancestor=$false) {
 $allowed=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',$operatorSid)
 if($AllowServiceWrite){$allowed+='S-1-5-19'}
 $write=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
 if($Ancestor){$write=$write -band (-bnot [int][Security.AccessControl.FileSystemRights]::Write)}
 $acl=Get-Acl -LiteralPath $Path
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
  if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and $rule.IdentityReference.Value -notin $allowed){throw "Untrusted write permission on $Path for $($rule.IdentityReference.Value)"}
 }
 $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
 if($owner -notin $allowed){throw "Untrusted owner on $Path ($owner). Prepare a properly owned dedicated bundle."}
}
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(!$admin){throw 'Run this optional installer from an elevated PowerShell.'}
if(Get-Service -Name $Name -ErrorAction SilentlyContinue){throw 'Service exists. Remove the old service explicitly before replacing its configuration.'}
$operatorSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach($key in @('ServiceBundleRoot','ServiceHost','ProjectConfig','PostgresBin','PostgresData')) {
 $path=[IO.Path]::GetFullPath((Get-Variable -Name $key -ValueOnly))
 if($path.StartsWith('\\')){throw 'Unattended service paths must be local disks.'}
 Assert-NoReparseAncestor $path
 Set-Variable -Name $key -Value (Resolve-Path -LiteralPath $path).Path
}
$ServiceBundleRoot=$ServiceBundleRoot.TrimEnd('\')
$root=Split-Path -Parent $ProjectConfig
$profiles=[IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users'))
foreach($shared in @([IO.Path]::GetPathRoot($ServiceBundleRoot),$env:ProgramData,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:windir,$profiles)) {
 if($shared -and $ServiceBundleRoot.Equals($shared.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw 'ServiceBundleRoot must be a dedicated deployment subdirectory, not a shared system directory.'}
}
if(Test-Within $profiles $ServiceBundleRoot){throw 'Use a dedicated service bundle outside user profiles.'}
if(!(Test-Within $ServiceBundleRoot $root)){throw 'ProjectConfig must be inside a separate project subdirectory of ServiceBundleRoot.'}
if(Get-ChildItem -LiteralPath $ServiceBundleRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1){throw 'The dedicated service bundle cannot contain junctions or symbolic links.'}
$project=Get-Content -LiteralPath $ProjectConfig -Raw | ConvertFrom-Json
foreach($key in @('server','app','web','data','databaseConfig')){if(!$project.$key){throw "Complete project.json is required; missing $key. Configure the ordinary offline project first."}}
if([int]$project.port -lt 1024 -or [int]$project.port -gt 65535){throw 'project.json port is invalid.'}
foreach($key in @('server','app','web','data','databaseConfig','remoteConfig')) {
 if(!$project.$key){continue}
 $path=[string]$project.$key
 if(![IO.Path]::IsPathRooted($path)){$path=Join-Path $root $path}
 $path=[IO.Path]::GetFullPath($path)
 if(!(Test-Within $ServiceBundleRoot $path)){throw "$key must be inside ServiceBundleRoot."}
 Assert-NoReparseAncestor $path
 $project.$key=$path
}
foreach($path in @($ServiceHost,$PostgresBin,$PostgresData)){if(!(Test-Within $ServiceBundleRoot $path)){throw 'Every service-owned path must stay inside the explicitly dedicated ServiceBundleRoot.'}}
foreach($path in @($ServiceHost,$PostgresBin,$project.server,$project.app,$project.web)){if(Test-Within $root $path){throw 'Program and web files must be outside the service-writable project subdirectory.'}}
foreach($path in @($project.data,$project.databaseConfig,$PostgresData)){if(!(Test-Within $root $path)){throw 'Data, databaseConfig and PostgresData must stay inside the project subdirectory.'}}
if($project.remoteConfig -and !(Test-Within $root $project.remoteConfig)){throw 'remoteConfig must stay inside the project subdirectory.'}
$certificatePaths=@()
if($project.remoteConfig){
 $remote=Get-Content -LiteralPath $project.remoteConfig -Raw|ConvertFrom-Json
 if($remote.enabled){
  foreach($key in @('certificate','private_key')){
   $path=[string]$remote.$key
   if(!$path){throw "Enabled remote configuration is missing $key."}
   if(![IO.Path]::IsPathRooted($path)){$path=Join-Path (Split-Path -Parent $project.remoteConfig) $path}
   $path=[IO.Path]::GetFullPath($path)
   if(!(Test-Within $root $path)){throw 'TLS certificate/key must stay inside the project subdirectory.'}
   Assert-NoReparseAncestor $path
   $certificatePaths+=$path
  }
 }
}
$config=Join-Path $root 'service-host.json'
if(Test-Path -LiteralPath $config){throw 'service-host.json already exists. Review and remove it explicitly before reinstalling.'}
# Inspect ownership/ACLs before executing the host elevated. Do not repair a
# writable downloaded executable; prepare it inside a protected bundle first.
$critical=@($ServiceBundleRoot,$ServiceHost,$PostgresBin,$project.server,$project.app,$project.web,$ProjectConfig,$project.databaseConfig)
$critical+=$certificatePaths
$critical+=@(Get-ChildItem -LiteralPath $ServiceBundleRoot -Recurse -File -Force | Where-Object { $_.Extension -in @('.exe','.dll','.ps1','.json') } | ForEach-Object FullName)
foreach($path in $critical|Select-Object -Unique){Assert-SafeAcl $path $false}
$ancestor=Split-Path -Parent $ServiceBundleRoot
while($ancestor){
 Assert-SafeAcl $ancestor $false $true
 $parent=Split-Path -Parent $ancestor
 if(!$parent -or $parent -eq $ancestor){break}
 $ancestor=$parent
}
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($config,(@{projectConfig=$ProjectConfig;postgresBin=$PostgresBin;postgresData=$PostgresData}|ConvertTo-Json),$utf8)
& $ServiceHost --config $config --check
if($LASTEXITCODE -ne 0){Remove-Item -LiteralPath $config;throw 'Preflight failed; inspect service-host.log. No service installed.'}
# Only the explicitly supplied dedicated bundle is changed. Shared external
# package/PostgreSQL directories have been rejected, never granted new access.
& icacls.exe $ServiceBundleRoot /reset /T /C | Out-Null
if($LASTEXITCODE -ne 0){throw 'Dedicated bundle ACL reset failed. No service installed.'}
& icacls.exe $ServiceBundleRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX' "*${operatorSid}:(OI)(CI)F" | Out-Null
if($LASTEXITCODE -ne 0){throw 'Dedicated bundle ACL update failed. No service installed.'}
& icacls.exe $root /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Project ACL update failed. No service installed.'}
foreach($path in ($critical+@($config))|Select-Object -Unique){Assert-SafeAcl $path (Test-Within $root $path)}
$binary='"'+$ServiceHost+'" --config "'+$config+'" --name '+$Name
& sc.exe create $Name binPath= $binary start= auto obj= 'NT AUTHORITY\LocalService' DisplayName= "Universal HMI ($Name)"
if($LASTEXITCODE -ne 0){throw 'Windows service creation failed.'}
if($Start){Start-Service -Name $Name;Write-Output 'Start requested. Check service-host.log and the authenticated deployment endpoint for readiness.'}
else{Write-Output "Installed without starting. Review paths/ACLs, then Start-Service $Name. Logs: $root\service-host.log"}

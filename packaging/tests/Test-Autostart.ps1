# Exercise scheduling/registry decisions without installing host startup entries
# or using a real Windows password. Native paths and Windows parsing are real.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixture=Join-Path $root '.local\autostart-v66\policy-fixture'
$project=Join-Path $fixture 'project';$install=Join-Path $fixture 'installed'
$null=New-Item -ItemType Directory -Force $project,$install
[IO.File]::WriteAllText((Join-Path $project 'project.json'),'{}')
[IO.File]::WriteAllText((Join-Path $install 'Autostart-Launch.ps1'),'# fixture only')
$core=Join-Path (Split-Path -Parent $PSScriptRoot) 'windows-lazy\Autostart-Core.ps1'
foreach($name in @('Autostart-Core.ps1','Autostart-Settings.ps1','Autostart-Launch.ps1')) {
 $errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $core) $name),[ref]$null,[ref]$errors)
 if($errors){throw ($errors|Out-String)}
}
. $core
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$context=Get-HmiStartupContext $project $install $sid
$absent=Get-HmiStartupContext (Join-Path $fixture 'never-started\project') $install $sid -AllowMissingProject
if(!$absent.ProjectRoot.EndsWith('never-started\project')){throw 'Missing project uninstall context failed'}
$task=$null;$registry=@{};$registrations=0;$removals=0;$service=$null
function Get-ScheduledTask {param($ErrorAction) if($script:task){return $script:task}}
function Get-ScheduledTaskInfo {param($TaskName,$TaskPath) return [pscustomobject]@{LastRunTime=[datetime]'2026-11-10';LastTaskResult=0}}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction) return $script:registry[$LiteralPath+'|'+$Name]}
function New-Item {param($Path,[switch]$Force) }
function New-ItemProperty {param($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force) $script:registry[$LiteralPath+'|'+$Name]=$Value}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction) $script:registry.Remove($LiteralPath+'|'+$Name)}
function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory) return [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
function New-ScheduledTaskTrigger {param([switch]$AtStartup) if(!$AtStartup){throw 'Not a boot trigger'};return [pscustomobject]@{Delay=''}}
function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval)
 if(!$StartWhenAvailable -or !$AllowStartIfOnBatteries -or !$DontStopIfGoingOnBatteries -or $MultipleInstances -ne 'IgnoreNew' -or $ExecutionTimeLimit -ne [TimeSpan]::Zero){throw 'Incorrect unattended settings'}
 return [pscustomobject]@{Count=$RestartCount}
}
function Register-ScheduledTask {param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$User,$Password,$RunLevel,$Description,[switch]$Force,$ErrorAction)
 if($User -ne $context.Account -or $Password -ne 'fixture-not-a-user-password' -or $RunLevel -ne 'Limited' -or $Trigger.Delay -ne 'PT30S'){throw 'Unexpected credential/principal/trigger contract'}
 $script:registrations++
 $script:task=[pscustomobject]@{TaskName=$TaskName;TaskPath=$TaskPath;Actions=@($Action);State='Ready';Description=$Description;Principal=[pscustomobject]@{UserId=$context.UserSID;RunLevel='Limited';LogonType='Password'}}
}
function Enable-ScheduledTask {param($TaskName,$TaskPath) $script:task.State='Ready'}
function Disable-ScheduledTask {param($TaskName,$TaskPath) $script:task.State='Disabled'}
function Unregister-ScheduledTask {param($TaskName,$TaskPath,[switch]$Confirm) $script:task=$null;$script:removals++}
function Get-HmiProjectService {param($Root) if($Root -ne $context.ProjectRoot){throw 'wrong service project'};return $script:service}
function Set-Service {param($Name,$StartupType) if($Name -ne 'FixtureOnly'){throw 'wrong service'};$script:service.StartMode=$(if($StartupType -eq 'Automatic'){'Auto'}else{'Manual'})}
function Assert-Rejected([scriptblock]$Action){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};if(!$rejected){throw 'Expected rejection'}}
$state=Get-HmiStartupState $context
if($state.boot_enabled -or $state.login_enabled){throw 'New project starts enabled'}
Assert-Rejected {Set-HmiStartup $context $true $true $null}
if($registrations -ne 0 -or $registry.Count -ne 0){throw 'Missing password mutated state'}
$password=ConvertTo-SecureString 'fixture-not-a-user-password' -AsPlainText -Force
$state=Set-HmiStartup $context $true $true $password
if(!$state.boot_enabled -or !$state.login_enabled -or $registrations -ne 1){throw 'Enable/readback failed'}
$state=Set-HmiStartup $context $true $true $null
if($registrations -ne 1){throw 'Repeated save replaced credentials'}
$approved=$context.RunPath.Replace('\CurrentVersion\Run','\CurrentVersion\Explorer\StartupApproved\Run')+'|'+$context.Name
$registry[$approved]=[byte[]]@(3,0,0,0)
if((Get-HmiStartupState $context).login_enabled){throw 'Windows disabled startup not reflected'}
$null=Set-HmiStartup $context $true $true $null
if(!(Get-HmiStartupState $context).login_enabled){throw 'Explicit re-enable did not repair Windows disabled entry'}
$task.Description='foreign task'
Assert-Rejected {Set-HmiStartup $context $false $false $null}
Assert-Rejected {Remove-HmiStartup $context}
if($removals){throw 'Foreign task removed'}
$task.Description=$context.Marker
$task.Principal.RunLevel='Highest'
Assert-Rejected {Set-HmiStartup $context $false $false $null}
$task.Principal.RunLevel='Limited'
$state=Set-HmiStartup $context $false $false $null
if($state.boot_enabled -or $state.login_enabled -or !$task){throw 'Disable did not preserve stopped future task'}
$null=Set-HmiStartup $context $true $true $null
Remove-HmiStartup $context
if($task -or $registry.Count -or $removals -ne 1){throw 'Owned cleanup incomplete'}
$service=[pscustomobject]@{Name='FixtureOnly';StartMode='Manual'}
$marker=Join-Path $project 'service-host.json';[IO.File]::WriteAllText($marker,'{}')
try {
 $state=Set-HmiStartup $context $true $false $null
 if(!$state.boot_enabled -or $state.mode -ne 'service' -or $registrations -ne 1){throw 'Service mode created duplicate task'}
 $state=Set-HmiStartup $context $false $false $null
 if($state.boot_enabled -or $service.StartMode -ne 'Manual'){throw 'Service disable failed'}
} finally {Remove-Item -LiteralPath $marker}
$password.Dispose()
Write-Output 'Autostart policy tests passed: native path/parse; mocked scheduling, readback, credential boundary, foreign ownership, Windows disabled entry, service reuse and cleanup. No host startup entries were installed.'

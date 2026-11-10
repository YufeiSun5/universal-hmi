# Windows Task Scheduler owns unattended credentials. Nothing here persists or
# logs passwords; a task runs as the selected existing user at limited privilege.
if(-not ('HmiAutostartPath' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HmiAutostartPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetLongPathName(string path, StringBuilder output, uint size);
  public static string Expand(string path) {
    var output=new StringBuilder(32768);
    uint n=GetLongPathName(path,output,(uint)output.Capacity);
    if(n==0 || n>=output.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return output.ToString().TrimEnd('\\');
  }
}
'@
}
function Get-HmiStartupContext([string]$ProjectRoot,[string]$InstallRoot,[string]$UserSID,[switch]$AllowMissingProject) {
  foreach($p in @($ProjectRoot,$InstallRoot)) {
    if(!$p -or ![IO.Path]::IsPathRooted($p) -or $p.StartsWith('\\') -or $p -match '["\r\n]'){throw '请选择本机绝对路径，路径不能包含引号或换行。'}
    $cursor=[IO.Path]::GetFullPath($p)
    while($cursor) {
      if(Test-Path -LiteralPath $cursor) {
        $item=Get-Item -LiteralPath $cursor -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '自启动工程及安装目录不能经过目录链接。'}
      } elseif(!$AllowMissingProject -or $p -eq $InstallRoot) {throw '工程或安装目录不存在。'}
      $parent=Split-Path -Parent $cursor;if(!$parent -or $parent -eq $cursor){break};$cursor=$parent
    }
  }
  if($UserSID -notmatch '^S-1-5-21-(\d+-){3}\d+$' -and $UserSID -notmatch '^S-1-12-1-(\d+-){3}\d+$'){throw 'Windows用户身份无效。'}
  $account=([Security.Principal.SecurityIdentifier]::new($UserSID)).Translate([Security.Principal.NTAccount]).Value
  $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $existingRoot=$ProjectRoot;$suffix=''
  while(!(Test-Path -LiteralPath $existingRoot)) {$suffix='\'+(Split-Path -Leaf $existingRoot)+$suffix;$existingRoot=Split-Path -Parent $existingRoot}
  $ProjectRoot=[HmiAutostartPath]::Expand($existingRoot)+$suffix
  $InstallRoot=[HmiAutostartPath]::Expand([IO.Path]::GetFullPath($InstallRoot))
  if(!$AllowMissingProject -and !(Test-Path -LiteralPath (Join-Path $ProjectRoot 'project.json'))){throw '请先正常启动一次本工程，再配置自启动。'}
  $launcher=Join-Path $InstallRoot 'Autostart-Launch.ps1'
  if(!(Test-Path -LiteralPath $launcher)){throw '安装缺少自启动入口，请覆盖安装新版完整包。'}
  $hash=[Security.Cryptography.SHA256]::Create()
  try {$id=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())))).Replace('-','').Substring(0,24)} finally {$hash.Dispose()}
  $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $args='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$launcher+'" -ProjectRoot "'+$ProjectRoot+'"'
  return [pscustomobject]@{ProjectRoot=$ProjectRoot;InstallRoot=$InstallRoot;UserSID=$UserSID;Account=$account;Name=('UniversalHMI-'+$id);Marker=('UniversalHMI startup v1 | '+$ProjectRoot+' | '+$InstallRoot+' | '+$UserSID);Executable=$ps;BootArguments=($args+' -Background');LoginCommand=('"'+$ps+'" '+$args);RunPath=('Registry::HKEY_USERS\'+$UserSID+'\Software\Microsoft\Windows\CurrentVersion\Run')}
}
function Get-HmiStartupTask($Context) {
  $found=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -eq $Context.Name -and $_.TaskPath -eq '\'})
  if($found.Count -gt 1){throw '自启动任务身份重复，未修改。'}
  if(!$found.Count){return $null}
  $task=$found[0]
  if($task.Description -ne $Context.Marker -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne $Context.Executable -or $task.Actions[0].Arguments -ne $Context.BootArguments){throw '同名自启动任务不属于此安装和工程，未修改。'}
  $sid=try {([Security.Principal.NTAccount]::new($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value} catch {$task.Principal.UserId}
  if($sid -ne $Context.UserSID -or $task.Principal.RunLevel -ne 'Limited' -or $task.Principal.LogonType -ne 'Password'){throw '任务运行账号或权限与本工程自启动配置不符，未修改。'}
  return $task
}
function Get-HmiLoginStartup($Context) {
  $value=Get-ItemPropertyValue -LiteralPath $Context.RunPath -Name $Context.Name -ErrorAction SilentlyContinue
  if($value -and $value -ne $Context.LoginCommand){throw '同名登录启动项不属于此安装和工程，未修改。'}
  return [bool]$value
}
function Get-HmiStartupState($Context) {
  $task=Get-HmiStartupTask $Context
  $service=$null
  if(Test-Path -LiteralPath (Join-Path $Context.ProjectRoot 'service-host.json')) {$service=Get-HmiProjectService $Context.ProjectRoot}
  if($service -and $task){throw '本工程同时存在服务和计划任务自启动，请先关闭原计划任务，避免重复入口。'}
  $info=if($task){Get-ScheduledTaskInfo -TaskName $Context.Name -TaskPath '\'}else{$null}
  $login=Get-HmiLoginStartup $Context
  $approved=Get-ItemPropertyValue -LiteralPath ($Context.RunPath.Replace('\CurrentVersion\Run','\CurrentVersion\Explorer\StartupApproved\Run')) -Name $Context.Name -ErrorAction SilentlyContinue
  if($approved -and $approved[0] -notin @(2,6)){$login=$false}
  return [pscustomobject]@{boot_enabled=($(if($service){$service.StartMode -eq 'Auto'}else{$task -and $task.State -ne 'Disabled'}));login_enabled=$login;mode=$(if($service){'service'}else{'task'});account=$Context.Account;service_name=$(if($service){$service.Name}else{''});task_state=$(if($task){[string]$task.State}else{'未配置'});last_run=$(if($info -and $info.LastRunTime.Year -gt 2000){$info.LastRunTime.ToString('o')}else{''});last_result=$(if($info){$info.LastTaskResult}else{$null})}
}
function Set-HmiStartup($Context,[bool]$Boot,[bool]$Login,[Security.SecureString]$Password) {
  $before=Get-HmiStartupState $Context
  $task=Get-HmiStartupTask $Context
  # Validate login destination before changing the boot task.
  $null=Get-HmiLoginStartup $Context
  if($before.mode -eq 'service') {
    Set-Service -Name $before.service_name -StartupType $(if($Boot){'Automatic'}else{'Manual'})
  } elseif($Boot) {
    if(!$task -or ($Password -and $Password.Length -gt 0)) {
      if(!$Password -or $Password.Length -eq 0){throw '首次启用后台开机启动需要当前Windows账号的密码（不是PIN）。密码只交给Windows任务计划程序保存。'}
      $action=New-ScheduledTaskAction -Execute $Context.Executable -Argument $Context.BootArguments -WorkingDirectory $Context.InstallRoot
      $trigger=New-ScheduledTaskTrigger -AtStartup
      $trigger.Delay='PT30S'
      $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
      $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
      try {
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $null=Register-ScheduledTask -TaskName $Context.Name -TaskPath '\' -Action $action -Trigger $trigger -Settings $settings -User $Context.Account -Password $plain -RunLevel Limited -Description $Context.Marker -Force -ErrorAction Stop
      } finally {$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    } else {$null=Enable-ScheduledTask -TaskName $Context.Name -TaskPath '\'}
  } elseif($task) {$null=Disable-ScheduledTask -TaskName $Context.Name -TaskPath '\'}
  if($Login) {
    $null=New-Item -Path $Context.RunPath -Force
    $null=New-ItemProperty -LiteralPath $Context.RunPath -Name $Context.Name -PropertyType String -Value $Context.LoginCommand -Force
    $approvedPath=$Context.RunPath.Replace('\CurrentVersion\Run','\CurrentVersion\Explorer\StartupApproved\Run')
    $null=New-Item -Path $approvedPath -Force
    $null=New-ItemProperty -LiteralPath $approvedPath -Name $Context.Name -PropertyType Binary -Value ([byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0)) -Force
  } elseif(Get-HmiLoginStartup $Context) {Remove-ItemProperty -LiteralPath $Context.RunPath -Name $Context.Name}
  $after=Get-HmiStartupState $Context
  if([bool]$after.boot_enabled -ne $Boot -or [bool]$after.login_enabled -ne $Login){throw 'Windows读回的自启动状态与所选设置不一致，请重新读取核对。'}
  return $after
}
function Remove-HmiStartup($Context) {
  $task=Get-HmiStartupTask $Context
  $login=Get-HmiLoginStartup $Context
  if($task){Unregister-ScheduledTask -TaskName $Context.Name -TaskPath '\' -Confirm:$false}
  if($login){Remove-ItemProperty -LiteralPath $Context.RunPath -Name $Context.Name}
  if($login){Remove-ItemProperty -LiteralPath ($Context.RunPath.Replace('\CurrentVersion\Run','\CurrentVersion\Explorer\StartupApproved\Run')) -Name $Context.Name -ErrorAction SilentlyContinue}
  # Existing SCM service belongs to its separate deployment installer.
}

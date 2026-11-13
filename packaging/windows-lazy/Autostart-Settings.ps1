param([Parameter(Mandatory=$true)][string]$ProjectRoot,[string]$UserSID,[switch]$Inspect,[switch]$Remove,[switch]$Elevated)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
if(!$UserSID){$UserSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
$installRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'Backend-Management.ps1')
. (Join-Path $PSScriptRoot 'Autostart-Core.ps1')
try {
  $context=Get-HmiStartupContext $ProjectRoot $installRoot $UserSID -AllowMissingProject:$Remove
  if($Inspect){Get-HmiStartupState $context | ConvertTo-Json -Compress;exit 0}
  if($Remove -and !(Get-HmiStartupTask $context) -and !(Get-HmiLoginStartup $context)){exit 0}
  $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(!$admin) {
    if($Elevated){throw 'Windows管理员确认未完成。'}
    $args=@('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ProjectRoot',('"'+$context.ProjectRoot+'"'),'-UserSID',$UserSID,'-Elevated')
    if($Remove){$args+='-Remove'}
    $process=Start-Process -FilePath $context.Executable -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru
    $process.WaitForExit();exit $process.ExitCode
  }
  if($Remove){Remove-HmiStartup $context;exit 0}
  Add-Type -AssemblyName PresentationFramework
  [xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="智慧供热 · 自启动配置" Width="610" Height="565" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen" Background="#F5F7F9" FontFamily="Microsoft YaHei UI" FontSize="14">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="本机自启动" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,18"/>
  <StackPanel Grid.Row="1">
   <TextBlock Name="Account" TextWrapping="Wrap" Margin="0,0,0,12"/>
   <CheckBox Name="Boot" Content="开机启动后台（无需登录Windows）" Margin="0,6,0,8"/>
   <TextBlock Text="采集与网页服务使用原工程配置。更改开关不停止当前后台。" TextWrapping="Wrap" Foreground="#536779" Margin="24,0,0,16"/>
   <CheckBox Name="Login" Content="登录Windows后自动打开运行界面" Margin="0,6,0,8"/>
   <TextBlock Text="运行界面仍按原账号权限登录，不保存软件登录密码。" Foreground="#536779" TextWrapping="Wrap" Margin="24,0,0,18"/>
   <TextBlock Name="PasswordLabel" Text="Windows账号密码（首次启用后台或更新凭据时填写，不是PIN）" TextWrapping="Wrap" Margin="0,0,0,8"/>
   <PasswordBox Name="Password" Height="34" Padding="6"/>
   <TextBlock Name="Note" Text="密码仅交给Windows任务计划程序；不写入工程、迁移包或日志。Windows密码变更后，请在这里重新保存凭据。" TextWrapping="Wrap" FontSize="12" Foreground="#536779" Margin="0,8,0,14"/>
   <TextBlock Name="Status" TextWrapping="Wrap" Margin="0,4,0,0"/>
  </StackPanel>
  <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button Name="Refresh" Content="重新读取" Width="94" Height="36" Margin="0,0,10,0"/><Button Name="Save" Content="保存配置" Width="100" Height="36" Margin="0,0,10,0"/><Button Name="Close" Content="关闭" Width="80" Height="36"/></StackPanel>
 </Grid>
</Window>
'@
  $window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
  $ui=@{};foreach($n in @('Account','Boot','Login','Password','PasswordLabel','Note','Status','Refresh','Save','Close')){$ui[$n]=$window.FindName($n)}
  $ui.Account.Text='Windows账号：'+$context.Account
  function Show-State {
    $state=Get-HmiStartupState $context
    $ui.Boot.IsChecked=[bool]$state.boot_enabled;$ui.Login.IsChecked=[bool]$state.login_enabled
    $service=$state.mode -eq 'service';$ui.Password.IsEnabled=!$service
    if($service){$ui.Note.Text='本工程已由Windows服务管理；开机开关修改原服务的启动类型，不另建后台任务。'}
    $ui.Status.Foreground=[Windows.Media.Brushes]::DarkSlateGray
    $ui.Status.Text='Windows已读回：后台开机 '+$(if($state.boot_enabled){'开启'}else{'关闭'})+'；登录界面 '+$(if($state.login_enabled){'开启'}else{'关闭'})
    if($state.last_run){$ui.Status.Text+="`n上次任务时间："+$state.last_run+'；结果码：'+$state.last_result}
  }
  $ui.Refresh.Add_Click({try{Show-State}catch{$ui.Status.Foreground=[Windows.Media.Brushes]::Firebrick;$ui.Status.Text=$_.Exception.Message}})
  $ui.Save.Add_Click({
    $ui.Save.IsEnabled=$false
    try {$null=Set-HmiStartup $context ([bool]$ui.Boot.IsChecked) ([bool]$ui.Login.IsChecked) $ui.Password.SecurePassword;$ui.Password.Clear();Show-State;$ui.Status.Text+="`n已保存。下次开机/登录时执行。"}
    catch {$ui.Password.Clear();$ui.Status.Foreground=[Windows.Media.Brushes]::Firebrick;$ui.Status.Text='保存未完成：'+$_.Exception.Message+' 请重新读取核对实际设置。'}
    finally {$ui.Save.IsEnabled=$true}
  })
  $ui.Close.Add_Click({$window.Close()})
  Show-State;$null=$window.ShowDialog();exit 0
} catch {
  if(!$Inspect -and !$Remove){Add-Type -AssemblyName PresentationFramework;[Windows.MessageBox]::Show($_.Exception.Message,'自启动配置失败')|Out-Null}
  else {[Console]::Error.WriteLine($_.Exception.Message)}
  exit 1
}

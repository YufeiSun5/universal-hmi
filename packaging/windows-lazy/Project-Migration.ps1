param(
  [string]$ProjectRoot=(Join-Path $env:LOCALAPPDATA 'UniversalHMI\project'),
  [switch]$Worker,
  [string]$PreviewPath
)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)

function New-MigrationProcess([string]$File,[string]$Arguments) {
  # Windows PowerShell's Process stdin inherits Console.InputEncoding; the
  # default UTF-8 BOM otherwise becomes part of the worker's JSON request.
  [Console]::InputEncoding=$utf8
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$File; $start.Arguments=$Arguments
  $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $start.StandardOutputEncoding=$utf8; $start.StandardErrorEncoding=$utf8
  $process=New-Object Diagnostics.Process; $process.StartInfo=$start
  $null=$process.Start()
  return $process
}

if($Worker) {
  [Console]::InputEncoding=$utf8; [Console]::OutputEncoding=$utf8
  $locks=@(); $management=$null
  try {
    $request=[Console]::In.ReadToEnd()|ConvertFrom-Json
    if($request.action -notin @('export','import')){throw '无效迁移操作'}
    $ProjectRoot=[IO.Path]::GetFullPath([string]$request.project).TrimEnd('\')
    if($ProjectRoot.Length -lt 4 -or $ProjectRoot.Contains('"')){throw '请选择完整的工程目录'}
    # Desktop identity expands 8.3 directory aliases before hashing. Resolve the
    # existing portion first so a short path cannot miss an open client's lock.
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HmiMigrationPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetLongPathName(string path, StringBuilder output, uint size);
  public static string Expand(string path) {
    var output=new StringBuilder(32768);
    uint n=GetLongPathName(path,output,(uint)output.Capacity);
    if(n==0 || n>=output.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return output.ToString();
  }
}
'@
    $existing=$ProjectRoot; $suffix=@()
    while(!(Test-Path -LiteralPath $existing)) {
      $suffix+=,[IO.Path]::GetFileName($existing)
      $existing=[IO.Path]::GetDirectoryName($existing)
      if(!$existing){throw '工程目录路径无效'}
    }
    $ProjectRoot=[HmiMigrationPath]::Expand($existing)
    for($i=$suffix.Count-1;$i -ge 0;$i--){$ProjectRoot=Join-Path $ProjectRoot $suffix[$i]}
    $request.project=$ProjectRoot
    . (Join-Path $PSScriptRoot 'Backend-Management.ps1')
    # Same identity as desktop_lifecycle.cpp; holding both role locks prevents
    # clients from starting while the offline snapshot is being transferred.
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $identity=$sid+'|directory:'+(Join-Path $ProjectRoot 'data').ToLowerInvariant()
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$digest=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::Unicode.GetBytes($identity)))).Replace('-','').ToLowerInvariant()} finally {$hash.Dispose()}
    foreach($role in @('developer','runtime')) {
      $mutex=New-Object Threading.Mutex($false,('Local\UniversalHmi.'+$digest+'.'+$role))
      try {$acquired=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$acquired=$true}
      if(!$acquired){$mutex.Dispose();throw '请先保存内容，并从托盘菜单退出本工程的开发端和运行端，再执行迁移。'}
      $locks+=,$mutex
    }
    if((Test-Path -LiteralPath $ProjectRoot) -and @(Get-ChildItem -LiteralPath $ProjectRoot -Force).Count -gt 0) {
      if($request.action -eq 'import' -and !$request.replace_existing){throw '目标已有工程，请明确选择备份后替换'}
      $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      $stop=New-MigrationProcess $ps ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Start-HMI.ps1')+'" -ProjectRoot "'+$ProjectRoot+'" -NoUI -Stop')
      $stop.StandardInput.Close()
      $stopOutput=$stop.StandardOutput.ReadToEndAsync();$stopError=$stop.StandardError.ReadToEndAsync()
      $stop.WaitForExit();$exitCode=$stop.ExitCode;$stop.Dispose()
      if($exitCode -ne 0){throw ('后台未能停止，迁移尚未进行。'+$stopError.Result)}
    } else {
      if($request.action -ne 'import'){throw '源工程目录不存在'}
      $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ProjectRoot)
    }
    $management=Enter-HmiManagement $ProjectRoot 0
    $tool=Join-Path $PSScriptRoot 'universal-hmi-server.exe'
    $process=New-MigrationProcess $tool '--project-migration'
    # Write UTF-8 without exposing the password to command-line inspection.
    $payload=$utf8.GetBytes(($request|ConvertTo-Json -Compress -Depth 8))
    $process.StandardInput.BaseStream.Write($payload,0,$payload.Length);$process.StandardInput.Close()
    [Array]::Clear($payload,0,$payload.Length);$request.password=$null
    $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit();$exitCode=$process.ExitCode;$process.Dispose()
    if($exitCode -ne 0){throw $errors.Result}
    [Console]::Out.Write($output.Result)
  } catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
  } finally {
    if($management){$management.ReleaseMutex();$management.Dispose()}
    foreach($mutex in $locks){$mutex.ReleaseMutex();$mutex.Dispose()}
  }
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='完整工程迁移 · 智慧供热集中监控系统'
$form.ClientSize=New-Object Drawing.Size(760,630)
$form.MinimumSize=New-Object Drawing.Size(660,650)
$form.StartPosition='CenterScreen';$form.AutoScaleMode='Dpi'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(243,246,249)

$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(24)
$layout.ColumnCount=3;$layout.RowCount=12
$null=$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',112)))
$null=$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
$null=$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',94)))
foreach($height in @(46,68,42,42,42,42,42,38,58,44,70,30)){$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
$form.Controls.Add($layout)
function Add-Text([string]$Text,[int]$Row,[bool]$Wide=$false) {
  $label=New-Object Windows.Forms.Label;$label.Text=$Text;$label.Dock='Fill';$label.TextAlign='MiddleLeft'
  $layout.Controls.Add($label,0,$Row);if($Wide){$layout.SetColumnSpan($label,3)};return $label
}
function Add-Input([int]$Row) {
  $input=New-Object Windows.Forms.TextBox;$input.Dock='Fill';$input.Margin=New-Object Windows.Forms.Padding(3,7,8,3)
  $layout.Controls.Add($input,1,$Row);return $input
}
$heading=Add-Text '把原工程完整搬到新服务器' 0 $true
$heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold)
$null=Add-Text '包含工程数据库、账号权限、设备审批、证书和密钥、图片及全部配置。外部数据库不搬动。迁移包使用密码加密；导出后后台保持停止。' 1 $true
$null=Add-Text '操作' 2
$action=New-Object Windows.Forms.ComboBox;$action.DropDownStyle='DropDownList';$action.Dock='Fill'
$null=$action.Items.Add('导出完整工程（旧电脑）');$null=$action.Items.Add('导入迁移包（新服务器）');$action.SelectedIndex=0
$layout.Controls.Add($action,1,2);$layout.SetColumnSpan($action,2)
$null=Add-Text '工程目录' 3
$project=Add-Input 3;$project.Text=$ProjectRoot
$chooseProject=New-Object Windows.Forms.Button;$chooseProject.Text='选择目录';$chooseProject.Dock='Fill';$layout.Controls.Add($chooseProject,2,3)
$chooseProject.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.SelectedPath=$project.Text;if($dialog.ShowDialog() -eq 'OK'){$project.Text=$dialog.SelectedPath};$dialog.Dispose()})
$null=Add-Text '迁移包文件' 4
$archive=Add-Input 4
$chooseArchive=New-Object Windows.Forms.Button;$chooseArchive.Text='选择文件';$chooseArchive.Dock='Fill';$layout.Controls.Add($chooseArchive,2,4)
$chooseArchive.Add_Click({
  if($action.SelectedIndex -eq 0){$dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.FileName=('供热工程-'+(Get-Date -Format 'yyyyMMdd-HHmm')+'.hmimigrate')}
  else{$dialog=New-Object Windows.Forms.OpenFileDialog}
  $dialog.Filter='加密工程迁移包 (*.hmimigrate)|*.hmimigrate';if($dialog.ShowDialog() -eq 'OK'){$archive.Text=$dialog.FileName};$dialog.Dispose()
})
$null=Add-Text '迁移包密码' 5
$password=Add-Input 5;$password.UseSystemPasswordChar=$true;$layout.SetColumnSpan($password,2)
$confirmationLabel=Add-Text '再次输入密码' 6
$confirmation=Add-Input 6;$confirmation.UseSystemPasswordChar=$true;$layout.SetColumnSpan($confirmation,2)
$replace=New-Object Windows.Forms.CheckBox;$replace.Text='目标已有工程时，先完整备份，再替换';$replace.Dock='Fill';$replace.Enabled=$false
$layout.Controls.Add($replace,1,7);$layout.SetColumnSpan($replace,2)
$null=Add-Text '操作前请保存并退出开发端、运行端。工具会停止本工程后台；不会自动启动新服务器。请单独保存迁移密码，遗忘后无法解密。' 8 $true
$run=New-Object Windows.Forms.Button;$run.Text='导出完整工程';$run.Dock='Fill';$run.BackColor=[Drawing.Color]::FromArgb(42,95,155);$run.ForeColor=[Drawing.Color]::White;$run.FlatStyle='Flat'
$layout.Controls.Add($run,1,9);$layout.SetColumnSpan($run,2)
$status=Add-Text '就绪。新服务器请先安装同版本或更新的完整离线包。' 10 $true
$status.ForeColor=[Drawing.Color]::FromArgb(45,65,83)
$progress=New-Object Windows.Forms.ProgressBar;$progress.Dock='Fill';$progress.Style='Marquee';$progress.Visible=$false
$layout.Controls.Add($progress,0,11);$layout.SetColumnSpan($progress,3)
$script:active=$null;$timer=New-Object Windows.Forms.Timer;$timer.Interval=250
$action.Add_SelectedIndexChanged({$import=$action.SelectedIndex -eq 1;$confirmation.Enabled=!$import;$confirmationLabel.Enabled=!$import;$replace.Enabled=$import;$run.Text=if($import){'导入迁移包'}else{'导出完整工程'};$archive.Clear()})
$run.Add_Click({
  if(!$project.Text -or !$archive.Text -or $password.Text.Length -lt 10){$status.Text='请选择工程目录、迁移包文件，并输入至少10个字符的密码。';return}
  if($action.SelectedIndex -eq 0 -and $password.Text -cne $confirmation.Text){$status.Text='两次输入的迁移密码不一致。';return}
  $message=if($action.SelectedIndex -eq 0){'将停止本工程后台，并导出完整加密迁移包。导出后后台保持停止。'}else{'将恢复迁移包中的完整工程。目标已有工程时保留独立备份；导入后不会自动启动。'}
  if([Windows.Forms.MessageBox]::Show($message+"`r`n`r`n工程目录："+$project.Text,'确认迁移操作','OKCancel','Information') -ne 'OK'){return}
  try {
    $payload=@{action=$(if($action.SelectedIndex -eq 0){'export'}else{'import'});project=$project.Text;archive=$archive.Text;password=$password.Text;replace_existing=$replace.Checked}|ConvertTo-Json -Compress
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:active=New-MigrationProcess $ps ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Worker')
    $bytes=$utf8.GetBytes($payload);$script:active.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$script:active.StandardInput.Close();[Array]::Clear($bytes,0,$bytes.Length);$payload=$null
    $script:outTask=$script:active.StandardOutput.ReadToEndAsync();$script:errTask=$script:active.StandardError.ReadToEndAsync()
    foreach($control in @($action,$project,$chooseProject,$archive,$chooseArchive,$password,$confirmation,$replace,$run)){$control.Enabled=$false}
    $status.Text='正在停止后台并校验、传输工程。数据量较大时请耐心等待。';$progress.Visible=$true;$timer.Start()
  } catch {$status.Text='无法开始迁移：'+$_.Exception.Message}
})
$timer.Add_Tick({
  if(!$script:active -or !$script:active.HasExited){return}
  $timer.Stop();$progress.Visible=$false
  if($script:active.ExitCode -eq 0){
    try {$result=$script:outTask.Result|ConvertFrom-Json;$status.Text=$result.note+"`r`n文件："+$result.files+'；大小：'+[Math]::Round($result.bytes/1MB,1)+' MB';if($result.previous_project_backup){$status.Text+="`r`n原工程备份："+$result.previous_project_backup}}catch{$status.Text='操作已退出，但结果无法读取，请核对工程后重试。'}
  }else{$status.Text='迁移未完成：'+$script:errTask.Result}
  $script:active.Dispose();$script:active=$null;$password.Clear();$confirmation.Clear()
  foreach($control in @($action,$project,$chooseProject,$archive,$chooseArchive,$password,$run)){$control.Enabled=$true}
  $confirmation.Enabled=$action.SelectedIndex -eq 0;$replace.Enabled=$action.SelectedIndex -eq 1
})
$form.Add_FormClosing({if($script:active -and !$script:active.HasExited){$_.Cancel=$true;$status.Text='迁移正在进行，请等待完成后关闭。'}})
if($PreviewPath){
  $form.Add_Shown({$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath);$bitmap.Dispose();$form.Close()})
}
$null=$form.ShowDialog();$timer.Dispose();$form.Dispose()

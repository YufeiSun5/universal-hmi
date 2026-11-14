#ifndef BundleDir
  #error BundleDir required
#endif
#ifndef PgDir
  #error PgDir required
#endif
#ifndef OutputDir
  #error OutputDir required
#endif
#ifndef PayloadId
  #error PayloadId required
#endif
#ifndef DeployManifest
  #error DeployManifest required
#endif

[Setup]
AppId={{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}
AppName=智慧供热集中监控系统
AppVersion=0.1.0.88
AppVerName=智慧供热集中监控系统 2026.11.13 完整离线版
VersionInfoVersion=0.1.0.88
AppPublisher=智慧供热集中监控系统
DefaultDirName={localappdata}\Programs\Universal HMI MQTT GIS Trial
DefaultGroupName=智慧供热集中监控系统
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=Universal-HMI-20261114-Full-v88-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\versions\{#PayloadId}\universal_hmi.exe
CloseApplications=no
RestartApplications=no
SetupLogging=yes
InfoBeforeFile=INSTALL.txt

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PgDir}\*"; DestDir: "{app}\versions\{#PayloadId}\postgresql"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Remote-Access.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Reset-Project-v10.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Backend-Management.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Start-HMI.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Project-Migration.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Startup-Window.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Autostart-Core.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Autostart-Settings.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
Source: "Autostart-Launch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DeployManifest}"; DestDir: "{app}\versions\{#PayloadId}"; DestName: "deployment-manifest.json"; Flags: ignoreversion
Source: "INSTALL.txt"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{userdesktop}\Universal HMI - GIS 展示.lnk"
Type: files; Name: "{userdesktop}\Universal HMI - 工艺图展示.lnk"
Type: files; Name: "{userdesktop}\Universal HMI - MQTT 开发配置.lnk"
Type: files; Name: "{userprograms}\Universal HMI 测试版\Universal HMI - GIS 展示.lnk"
Type: files; Name: "{userprograms}\Universal HMI 测试版\Universal HMI - 工艺图展示.lnk"
Type: files; Name: "{userprograms}\Universal HMI 测试版\Universal HMI - MQTT 开发配置.lnk"
Type: files; Name: "{userprograms}\Universal HMI 测试版\卸载 Universal HMI 测试版.lnk"

Type: files; Name: "{userdesktop}\Universal HMI - 远程用户端.lnk"
Type: files; Name: "{userdesktop}\Universal HMI - 远程开发端.lnk"
Type: files; Name: "{userdesktop}\Universal HMI - 运行态.lnk"
Type: files; Name: "{userdesktop}\Universal HMI - 开发态.lnk"

[Icons]
Name: "{userdesktop}\智慧供热集中监控系统 - 远程用户端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\智慧供热集中监控系统 - 远程开发端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\智慧供热集中监控系统 - 远程用户端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\智慧供热集中监控系统 - 远程开发端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\智慧供热集中监控系统 - 运行态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\智慧供热集中监控系统 - 开发态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\智慧供热集中监控系统 - 运行态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\智慧供热集中监控系统 - 开发态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\停止后台"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -Stop"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\部署说明"; Filename: "{app}\INSTALL.txt"
Name: "{userprograms}\智慧供热集中监控系统\完整工程迁移"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Project-Migration.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"""; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\自启动配置"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Autostart-Settings.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"""; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\智慧供热集中监控系统\卸载 智慧供热集中监控系统"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -ProjectRoot ""{code:GetTargetProjectRoot}"" -View runtime"; Description: "启动 智慧供热集中监控系统（首次自动初始化数据库）"; Flags: nowait postinstall skipifsilent

[Code]
function GetTargetProjectRoot(Param: String): String;
var
  Saved: AnsiString;
  DefaultRoot: String;
begin
  DefaultRoot := ExpandConstant('{localappdata}\UniversalHMI\project');
  if LoadStringFromFile(ExpandConstant('{app}\installed-project-root.txt'), Saved) then
    DefaultRoot := Trim(String(Saved));
  Result := ExpandConstant('{param:PROJECTROOT|' + DefaultRoot + '}');
  if (Pos('"', Result) > 0) or (Pos(#13, Result) > 0) or (Pos(#10, Result) > 0) or (Length(Result) < 4) or (Result[2] <> ':') then
    RaiseException('Invalid absolute project path.');
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Result));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    if not SaveStringToFile(ExpandConstant('{app}\installed-project-root.txt'), GetTargetProjectRoot(''), False) then
      RaiseException('Could not preserve the installed project path.');
    if not SaveStringToFile(ExpandConstant('{app}\active-payload.txt'), '{#PayloadId}', False) then
      RaiseException('Could not save the installed startup payload.');
  end;
end;

// Preserve-only upgrade: no reset page, maintenance invocation or RESETV10 option.
function RunningFromInstallDirectory(): Boolean;
var
  Locator, Services, Processes, Process: Variant;
  I: Integer;
  RootPath, ExecutablePath: String;
begin
  Result := False;
  RootPath := Lowercase(AddBackslash(ExpandConstant('{app}')));
  Locator := CreateOleObject('WbemScripting.SWbemLocator');
  Services := Locator.ConnectServer('', 'root\CIMV2');
  Processes := Services.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE Name=''universal_hmi.exe''');
  for I := 0 to Processes.Count - 1 do begin
    Process := Processes.ItemIndex(I);
    if not VarIsNull(Process.ExecutablePath) then begin
      ExecutablePath := Process.ExecutablePath;
      ExecutablePath := Lowercase(ExecutablePath);
      if Pos(RootPath, ExecutablePath) = 1 then begin
        Result := True;
        Exit;
      end;
    end;
  end;
end;

function StopInstalledBackground(): String;
var
  ExitCode: Integer;
  Arguments: String;
begin
  Result := '';
  if not FileExists(AddBackslash(GetTargetProjectRoot('')) + 'ready.json') then Exit;
  ExtractTemporaryFile('Start-HMI.ps1');
  ExtractTemporaryFile('Backend-Management.ps1');
  ExtractTemporaryFile('Remote-Access.ps1');
  ExtractTemporaryFile('Startup-Window.ps1');
  Arguments := '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\Start-HMI.ps1') + '" -Stop -NoUI -InstalledMaintenance -ProjectRoot "' + GetTargetProjectRoot('') + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Arguments, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := '无法启动后台管理。安装尚未继续，工程数据保留。'
  else if ExitCode <> 0 then
    Result := '后台未确认停止，安装尚未继续。请在软件的网络访问入口查看后台状态并重试；工程数据保留。';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  try
    if RunningFromInstallDirectory() then
      Result := '请先在开发端保存内容，再从两个客户端的托盘菜单选择“退出此端”，然后重试。安装器会自动核对并停止本工程后台。关闭窗口仅收起到托盘。'
    else
      Result := StopInstalledBackground();
  except
    Result := '无法检查运行中的程序，未修改文件。请检查Windows进程查询权限。';
  end;
end;

function InitializeUninstall(): Boolean;
var
  ExitCode: Integer;
begin
  Result := False;
  try
    if RunningFromInstallDirectory() then
      MsgBox('请先从托盘菜单选择“退出”（开发端和用户端分别退出），然后重试卸载。工程数据会保留。', mbError, MB_OK)
    else begin
      if FileExists(ExpandConstant('{app}\versions\{#PayloadId}\Start-HMI.ps1')) then begin
        if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\versions\{#PayloadId}\Start-HMI.ps1') + '" -Stop -NoUI -ProjectRoot "' + GetTargetProjectRoot('') + '"', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) then Exit;
        if ExitCode <> 0 then begin MsgBox('后台未确认停止，未卸载。请在软件内查看后台状态后重试。', mbError, MB_OK); Exit; end;
      end;
      if FileExists(ExpandConstant('{app}\versions\{#PayloadId}\Autostart-Settings.ps1')) then begin
        if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\versions\{#PayloadId}\Autostart-Settings.ps1') + '" -Remove -ProjectRoot "' + GetTargetProjectRoot('') + '"', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) then Exit;
        if ExitCode <> 0 then begin MsgBox('自启动项未确认移除，未卸载。请从自启动配置关闭后重试。工程数据保留。', mbError, MB_OK); Exit; end;
      end;
      Result := True;
    end;
  except
    MsgBox('无法检查运行中的程序，未移除文件。', mbError, MB_OK);
  end;
end;

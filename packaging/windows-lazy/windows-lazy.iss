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
AppName=Universal HMI
AppVersion=0.1.0.19
AppVerName=Universal HMI 2026.10.29 PostgreSQL 完整离线版
VersionInfoVersion=0.1.0.19
AppPublisher=Universal HMI maintainers
DefaultDirName={localappdata}\Programs\Universal HMI MQTT GIS Trial
DefaultGroupName=Universal HMI
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=Universal-HMI-20261030-Full-v19-Setup
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
Source: "Start-HMI.ps1"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion
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

[Icons]
Name: "{userdesktop}\Universal HMI - 远程用户端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - 远程开发端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\Universal HMI - 远程用户端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\Universal HMI - 远程开发端"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-RemoteClient.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - 运行态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - 开发态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\Universal HMI - 运行态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -View runtime"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\Universal HMI - 开发态"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\停止后台"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -Stop"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI\部署说明"; Filename: "{app}\INSTALL.txt"
Name: "{userprograms}\Universal HMI\卸载 Universal HMI"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-HMI.ps1"" -View runtime"; Description: "启动 Universal HMI（首次自动初始化数据库）"; Flags: nowait postinstall skipifsilent

[Code]
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
  Processes := Services.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE Name=''universal_hmi.exe'' OR Name=''universal-hmi-server.exe'' OR Name=''postgres.exe''');
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

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  try
    if RunningFromInstallDirectory() then
      Result := '请先从托盘菜单选择“退出”（开发端和用户端分别退出），再从开始菜单运行“停止后台”，然后重试。旧版按原退出方式结束窗口和后台。';
  except
    Result := '无法检查运行中的程序，未修改文件。请检查Windows进程查询权限。';
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := False;
  try
    if RunningFromInstallDirectory() then
      MsgBox('请先从托盘菜单选择“退出”（开发端和用户端分别退出），再从开始菜单运行“停止后台”。工程数据会保留。', mbError, MB_OK)
    else
      Result := True;
  except
    MsgBox('无法检查运行中的程序，未移除文件。', mbError, MB_OK);
  end;
end;

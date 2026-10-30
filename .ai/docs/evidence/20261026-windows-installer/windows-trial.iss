; Built only with an already-installed official Inno Setup 6 compiler.
; No [Run], service, startup task, registry credential, firewall or network action.
#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef ProductVersion
  #error ProductVersion is required
#endif
#ifndef ProductFileVersion
  #error ProductFileVersion is required
#endif
#ifndef PayloadId
  #error PayloadId is required
#endif

[Setup]
AppId={{F946A7CD-F518-4D6E-B3A0-D57C4C5E1B02}
AppName=Universal HMI MQTT GIS Trial
AppVersion={#ProductVersion}
AppVerName=Universal HMI MQTT GIS Trial 2026.10.26 v2
VersionInfoVersion={#ProductFileVersion}
AppPublisher=Universal HMI maintainers
AppPublisherURL=https://github.com/YufeiSun5/universal-hmi
DefaultDirName={localappdata}\Programs\Universal HMI MQTT GIS Trial
DefaultGroupName=Universal HMI
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=Universal-HMI-MQTT-GIS-20261026-v2-Setup
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
Source: "INSTALL.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Universal HMI 测试版\Universal HMI - GIS 展示"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View gis"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - GIS 展示"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View gis"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI 测试版\Universal HMI - 工艺图展示"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View process"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - 工艺图展示"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View process"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI 测试版\Universal HMI - MQTT 开发配置"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userdesktop}\Universal HMI - MQTT 开发配置"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\versions\{#PayloadId}\Start-Trial.ps1"" -View developer"; WorkingDir: "{app}\versions\{#PayloadId}"; IconFilename: "{app}\versions\{#PayloadId}\universal_hmi.exe"
Name: "{userprograms}\Universal HMI 测试版\卸载 Universal HMI 测试版"; Filename: "{uninstallexe}"

[Code]
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
  Processes := Services.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE Name=''universal_hmi.exe'' OR Name=''universal-hmi-server.exe''');
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
      Result := 'Close Universal HMI and its backend before updating. No processes have been stopped.';
  except
    Result := 'Cannot verify whether Universal HMI is closed. Windows process inspection failed; no files were changed.';
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := False;
  try
    if RunningFromInstallDirectory() then
      MsgBox('Close Universal HMI and its backend before uninstalling. Your data will be kept.', mbError, MB_OK)
    else
      Result := True;
  except
    MsgBox('Cannot verify whether Universal HMI is closed. Windows process inspection failed; no files were removed.', mbError, MB_OK);
  end;
end;

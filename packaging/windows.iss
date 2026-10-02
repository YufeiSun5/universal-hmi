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
AppId={{7A47C722-492D-4D71-9093-A0F1F17C2842}
AppName=Universal HMI
AppVersion={#ProductVersion}
AppVerName=Universal HMI {#ProductVersion}
VersionInfoVersion={#ProductFileVersion}
AppPublisher=Universal HMI maintainers
AppPublisherURL=https://github.com/YufeiSun5/universal-hmi
DefaultDirName={localappdata}\Programs\Universal HMI
DefaultGroupName=Universal HMI
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=universal-hmi-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\versions\{#PayloadId}\universal_hmi.exe
CloseApplications=no
RestartApplications=no
SetupLogging=yes
InfoBeforeFile=README.txt

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}\versions\{#PayloadId}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Universal HMI\Universal HMI"; Filename: "{app}\versions\{#PayloadId}\universal_hmi.exe"; WorkingDir: "{app}\versions\{#PayloadId}"
Name: "{userprograms}\Universal HMI\Uninstall Universal HMI"; Filename: "{uninstallexe}"

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
      ExecutablePath := Lowercase(Process.ExecutablePath);
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

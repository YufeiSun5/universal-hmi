#ifndef PayloadDir
  #error PayloadDir required
#endif
#ifndef OutputDir
  #error OutputDir required
#endif
#ifndef SiteID
  #error SiteID required
#endif
#ifndef SetupAppId
  #error SetupAppId required
#endif

[Setup]
AppId={#SetupAppId}
AppName=Universal HMI 浏览器证书
AppVersion=0.1.0.47
AppPublisher=Universal HMI maintainers
DefaultDirName={localappdata}\Programs\Universal HMI Browser Certificate\{#SiteID}
DefaultGroupName=Universal HMI 浏览器证书
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=Universal-HMI-Browser-Certificate-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
InfoBeforeFile=README.txt

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\通过 Edge 打开 Universal HMI"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Browser-Certificate.ps1"" -Action Open -Browser Edge"; WorkingDir: "{app}"
Name: "{group}\通过 Chrome 打开 Universal HMI"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Browser-Certificate.ps1"" -Action Open -Browser Chrome"; WorkingDir: "{app}"
Name: "{group}\检查与修复浏览器证书"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\Browser-Certificate.ps1"" -Action Install"; WorkingDir: "{app}"
Name: "{group}\使用说明"; Filename: "{app}\README.txt"
Name: "{group}\卸载浏览器证书"; Filename: "{uninstallexe}"

[Code]
var CertificateFailed: Boolean;

function RunCertificateAction(Action: String): Boolean;
var Code: Integer;
begin
  Result := ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\Browser-Certificate.ps1') + '" -Action ' + Action + ' -Quiet',
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code, nil);
  Log(Format('Certificate action %s: launched=%d exit=%d', [Action, Ord(Result), Code]));
  if Result then Result := Code = 0;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    CertificateFailed := True;
    if RunCertificateAction('Install') then
      CertificateFailed := False
    else begin
      WizardForm.FinishedLabel.Caption := '证书配置未完成，请检查安装日志后重新安装。';
      RaiseException('证书配置未完成。请从开始菜单打开“检查与修复浏览器证书”查看具体原因，再重试安装。证书安装不代表自动选择规则已生效。');
    end;
  end;
end;

function GetCustomSetupExitCode(): Integer;
begin
  if CertificateFailed then Result := 42 else Result := 0;
end;

function InitializeUninstall(): Boolean;
begin
  Result := RunCertificateAction('Remove');
  if not Result then
    MsgBox('证书清理未完成。请关闭其他安装程序后重试。', mbError, MB_OK);
end;

procedure InitializeWizard();
begin
  WizardForm.InfoBeforeMemo.Text := '本安装器对应的正式地址（包含端口）：{#SiteOrigin}' + #13#10 + #13#10 + WizardForm.InfoBeforeMemo.Text;
  WizardForm.FinishedLabel.Caption := '已验证正式地址和端口，安装独立设备证书，并读回核对 Edge / Chrome 自动选择规则。浏览器实际加载状态还需重启后验证。' + #13#10 + #13#10 +
    '请保存浏览器中的工作，完全退出浏览器后重新打开。使用开始菜单的浏览器入口登录，首次登录提交设备申请，管理员批准后再次登录即可查看。';
end;

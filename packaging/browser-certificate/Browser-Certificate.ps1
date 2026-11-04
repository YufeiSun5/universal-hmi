param(
  [ValidateSet('Install','Remove','Inspect','Open')][string]$Action='Install',
  [string]$ConfigPath=(Join-Path $PSScriptRoot 'site.json'),
  [ValidateSet('Edge','Chrome')][string]$Browser='Edge',
  [switch]$Quiet
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Hash-Bytes([byte[]]$Bytes) {
  $hash=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose() }
}
function Save-State {
  $temp=Join-Path $stateDir ([Guid]::NewGuid().ToString('N')+'.tmp')
  [IO.File]::WriteAllText($temp,($script:state | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  if(Test-Path -LiteralPath $statePath){[IO.File]::Replace($temp,$statePath,[NullString]::Value)}
  else {[IO.File]::Move($temp,$statePath)}
}
function Read-PersonalCertificate {
  $matches=@(Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq $script:state.subject)
  if($matches.Count -gt 1){throw '发现同名的多份设备证书，请联系管理员核对，安装已停止。'}
  if($matches.Count -eq 1){return $matches[0]}
  return $null
}
function Check-PersonalCertificate($Certificate) {
  if(!$Certificate.HasPrivateKey -or $Certificate.NotAfter -le (Get-Date) -or $Certificate.NotBefore -gt (Get-Date)) {
    throw '设备证书已过期或私钥不可用。请先在管理端撤销旧设备，再卸载此证书工具并重新安装。'
  }
  $key=[Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
  if(!$key){throw '设备证书私钥格式不受支持。'}
  try {
    if($key.KeySize -ne 256 -or $key.Key.ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None) {
      throw '设备私钥必须是不可导出的 P-256 密钥。'
    }
    $proof=$key.SignData([Text.Encoding]::UTF8.GetBytes('Universal HMI local key check'),[Security.Cryptography.HashAlgorithmName]::SHA256)
    if(!$proof.Length){throw '设备私钥无法签名。'}
  } finally {$key.Dispose()}
}
function Add-BrowserPolicy([string]$Product,[string]$Value) {
  $path="HKCU:\Software\Policies\$Product\AutoSelectCertificateForUrls"
  if(Test-Path -LiteralPath $path) {
    $existing=Get-Item -LiteralPath $path
    $wanted=$Value|ConvertFrom-Json
    foreach($name in $existing.GetValueNames()) {
      try {
        $entry=$existing.GetValue($name)|ConvertFrom-Json
        if($entry.pattern -ceq $wanted.pattern -and $entry.filter.SUBJECT.CN -ceq $wanted.filter.SUBJECT.CN){return}
      } catch { }
    }
  }
  $null=New-Item -Path $path -Force
  $registry=Get-Item -LiteralPath $path
  foreach($name in $registry.GetValueNames()) {
    if($registry.GetValue($name) -eq $Value){return}
  }
  $number=1
  while($registry.GetValueNames() -contains [string]$number){$number++}
  $entry=[pscustomobject]@{path=$path;name=[string]$number;value=$Value}
  # Journal ownership before changing a store so an interrupted setup is repairable.
  $script:state.policies=@($script:state.policies)+@($entry)
  Save-State
  $null=New-ItemProperty -LiteralPath $path -Name $entry.name -Value $Value -PropertyType String -Force
}

function Set-ElevatedBrowserPolicy([string]$PolicyAction) {
  $helper=Join-Path $PSScriptRoot 'Browser-Policy.ps1'
  $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$helper+'" -Action '+$PolicyAction+' -TargetSid '+$sid+' -Origin "'+$origin+'" -CommonName "HMI Browser '+$state.installation+'"'
  $process=Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
  if($process.ExitCode -ne 0){throw '浏览器自动选择规则配置失败，请重新安装并允许一次管理员确认。'}
}

$mutex=$null
$locked=$false
try {
  $config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $uri=[Uri]$config.origin
  if($config.schema -ne 1 -or !$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
    throw '站点配置必须是版本 1 的 HTTPS 来源地址。'
  }
  $origin=$uri.GetLeftPart([UriPartial]::Authority)
  if($origin -ne $config.origin){throw '站点地址必须使用规范的 HTTPS 来源格式。'}
  $siteID=(Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($origin))).Substring(0,24)
  $stateDir=Join-Path $env:LOCALAPPDATA "UniversalHMI\BrowserCertificates\$siteID"
  $statePath=Join-Path $stateDir 'state.json'
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex=[Threading.Mutex]::new($false,"Local\UniversalHMI-Browser-$sid-$siteID")
  try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
  if(!$locked){throw '另一项证书安装或卸载正在进行，请稍后重试。'}
  $script:state=$null
  if(Test-Path -LiteralPath $statePath) {
    $script:state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($state.schema -ne 1 -or $state.origin -ne $origin -or $state.installation -notmatch '^[a-f0-9]{32}$' -or
       $state.subject -ne "CN=HMI Browser $($state.installation), O=Universal HMI, OU=Windows Browser") {
      throw '已有设备记录格式不符，已停止操作。'
    }
  }
  if($Action -eq 'Remove') {
    if($state) {
      if($state.PSObject.Properties.Name -contains 'elevatedPolicies' -and $state.elevatedPolicies) {
        Set-ElevatedBrowserPolicy 'Remove'
      }
      foreach($entry in $state.policies) {
        if($entry.path -notin @('HKCU:\Software\Policies\Microsoft\Edge\AutoSelectCertificateForUrls','HKCU:\Software\Policies\Google\Chrome\AutoSelectCertificateForUrls') -or $entry.name -notmatch '^\d+$') {
          throw '已记录的浏览器配置路径无效。'
        }
        if(Test-Path -LiteralPath $entry.path) {
          $registry=Get-Item -LiteralPath $entry.path
          if($registry.GetValue($entry.name) -eq $entry.value){Remove-ItemProperty -LiteralPath $entry.path -Name $entry.name}
        }
      }
      foreach($thumbprint in $state.trustAdded) {
        if($thumbprint -notmatch '^[A-F0-9]{40}$'){throw '已记录的证书指纹无效。'}
        $trustPath="Cert:\CurrentUser\Root\$thumbprint"
        if(Test-Path -LiteralPath $trustPath){Remove-Item -LiteralPath $trustPath}
      }
      $cert=Read-PersonalCertificate
      if($cert){Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey}
      Remove-Item -LiteralPath $statePath
      $info=Join-Path $stateDir '安装结果.txt'
      if(Test-Path -LiteralPath $info){Remove-Item -LiteralPath $info}
    }
    Write-Output '已移除此工具管理的浏览器证书和配置。'
  } elseif($Action -eq 'Inspect') {
    if(!$state){throw '此 Windows 用户尚未安装本站设备证书。'}
    $cert=Read-PersonalCertificate
    if(!$cert){throw '设备证书不存在，请重新运行安装器修复。'}
    Check-PersonalCertificate $cert
    [pscustomobject]@{origin=$origin;installation=$state.installation;thumbprint=$cert.Thumbprint;subject=$cert.Subject;expires=$cert.NotAfter.ToUniversalTime().ToString('o');privateKeyExportable=$false} | ConvertTo-Json
  } elseif($Action -eq 'Open') {
    if(!$state){throw '请先运行证书安装器。'}
    $exeName=if($Browser -eq 'Edge'){'msedge.exe'}else{'chrome.exe'}
    $exe=$null
    foreach($hive in @('HKCU','HKLM')) {
      $appPath="${hive}:\Software\Microsoft\Windows\CurrentVersion\App Paths\$exeName"
      if(Test-Path -LiteralPath $appPath) {
        $candidate=(Get-Item -LiteralPath $appPath).GetValue('')
        if($candidate -and (Test-Path -LiteralPath $candidate)){$exe=$candidate;break}
      }
    }
    if(!$exe){throw "未找到 $Browser，请安装浏览器后再打开此快捷方式。"}
    Start-Process -FilePath $exe -ArgumentList ($origin+'/?view=runtime')
  } else {
    if($config.server_sha256 -notmatch '^[a-f0-9]{64}$' -or $config.server_certificate -ne 'server-public.cer') {
      throw '服务器公开证书配置无效。'
    }
    $serverPath=Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $ConfigPath)) $config.server_certificate
    $server=[Security.Cryptography.X509Certificates.X509Certificate2]::new($serverPath)
    if((Hash-Bytes $server.RawData) -ne $config.server_sha256 -or $server.NotAfter -le (Get-Date) -or $server.NotBefore -gt (Get-Date)) {
      throw '服务器公开证书校验失败或已过期，请使用当前版本安装器。'
    }
    if(!$state) {
      $null=New-Item -ItemType Directory -Path $stateDir -Force
      $installation=[Guid]::NewGuid().ToString('N')
      $script:state=[pscustomobject]@{schema=1;origin=$origin;installation=$installation;subject="CN=HMI Browser $installation, O=Universal HMI, OU=Windows Browser";thumbprint='';policies=@();trustAdded=@()}
      Save-State
    }
    $cert=Read-PersonalCertificate
    if(!$cert) {
      if($state.thumbprint){throw '原设备证书已被移除。请先卸载此证书工具，再安装并重新提交审批。'}
      $cert=New-SelfSignedCertificate -Type Custom -Subject $state.subject -FriendlyName "Universal HMI 浏览器 $($state.installation.Substring(0,12))" -CertStoreLocation 'Cert:\CurrentUser\My' -Provider 'Microsoft Software Key Storage Provider' -KeyAlgorithm ECDSA_nistP256 -KeyExportPolicy NonExportable -KeyUsage DigitalSignature -HashAlgorithm SHA256 -NotBefore (Get-Date).AddMinutes(-5) -NotAfter (Get-Date).AddYears(10) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.2','2.5.29.19={text}ca=0')
    }
    Check-PersonalCertificate $cert
    $script:state.thumbprint=$cert.Thumbprint
    Save-State
    $trustPath="Cert:\CurrentUser\Root\$($server.Thumbprint)"
    if(!(Test-Path -LiteralPath $trustPath)) {
      $script:state.trustAdded=@($state.trustAdded)+@($server.Thumbprint)
      Save-State
      $trustStore=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
      try {
        $trustStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $trustStore.Add($server)
      } finally { $trustStore.Close() }
      if(!(Test-Path -LiteralPath $trustPath)){throw '服务器公开证书信任安装失败。'}
    }
    $policy=@{pattern=$origin;filter=@{SUBJECT=@{CN="HMI Browser $($state.installation)"}}} | ConvertTo-Json -Depth 4 -Compress
    $policyWarnings=@()
    foreach($product in @('Microsoft\Edge','Google\Chrome')) {
      try { Add-BrowserPolicy $product $policy }
      catch [System.UnauthorizedAccessException] { $policyWarnings+= "$product 自动选择策略由系统管理，请在浏览器提示时手动选择本站 HMI Browser 证书。" }
      catch [System.Security.SecurityException] { $policyWarnings+= "$product 自动选择策略由系统管理，请在浏览器提示时手动选择本站 HMI Browser 证书。" }
    }
    if($policyWarnings.Count -gt 0) {
      # Record ownership before elevation, so interrupted installation can be repaired.
      $script:state | Add-Member -NotePropertyName elevatedPolicies -NotePropertyValue $true -Force
      Save-State
      Set-ElevatedBrowserPolicy 'Install'
      $policyWarnings=@()
    }
    $info=@"
Windows 浏览器证书已配置

$($policyWarnings -join "`r`n")

网站 $origin
设备标识 $($state.installation.Substring(0,12))
证书指纹 $($cert.Thumbprint)
有效期 $($cert.NotAfter.ToString('yyyy-MM-dd'))

请保存浏览器中的工作，完全退出 Edge / Chrome 后重新打开。
使用开始菜单里的“Universal HMI 浏览器证书”入口访问网站。
首次输入账号、密码、验证码后会显示“设备正在审批”。
管理员在“登录与安全 → 设备审批”核对账号及以上设备标识后批准。
批准后再次登录即可查看。换网络后仍使用此设备审批。
同一 Windows 用户重复安装会复用证书，其他 Windows 用户需分别安装。
卸载会移除此工具添加的证书和配置，重新安装需要重新审批。
管理员可在服务端即时停用设备。
"@
    [IO.File]::WriteAllText((Join-Path $stateDir '安装结果.txt'),$info,[Text.UTF8Encoding]::new($true))
    Write-Output $info
    if(!$Quiet) {
      Add-Type -AssemblyName System.Windows.Forms
      $null=[Windows.Forms.MessageBox]::Show($info,'Universal HMI 浏览器证书')
    }
  }
} catch {
  if(!$Quiet) {
    Add-Type -AssemblyName System.Windows.Forms
    $null=[Windows.Forms.MessageBox]::Show($_.Exception.Message,'证书配置未完成',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
  }
  Write-Error $_ -ErrorAction Continue
  exit 1
} finally {
  if($locked){$mutex.ReleaseMutex()}
  if($mutex){$mutex.Dispose()}
}

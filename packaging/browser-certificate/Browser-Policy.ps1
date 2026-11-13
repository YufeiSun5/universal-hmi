param(
  [ValidateSet('Install','Remove')][string]$Action,
  [Parameter(Mandatory=$true)][string]$TargetSid,
  [Parameter(Mandatory=$true)][string]$Origin,
  [Parameter(Mandatory=$true)][string]$CommonName
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $principal=[Security.Principal.WindowsPrincipal]::new($identity)
  if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw '需要一次管理员确认来配置浏览器证书选择。'}
  if($TargetSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $CommonName -notmatch '^HMI Browser [a-f0-9]{32}$'){throw '设备标识无效。'}
  $uri=[Uri]$Origin
  if(!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or $Origin -ne $uri.GetLeftPart([UriPartial]::Authority) -or $Origin.Contains('*')){throw '站点来源格式无效。'}
  $hive="Registry::HKEY_USERS\$TargetSid"
  if(!(Test-Path -LiteralPath $hive)){throw '目标 Windows 用户配置未加载。'}
  $value=@{pattern=$Origin;filter=@{SUBJECT=@{CN=$CommonName}}}|ConvertTo-Json -Depth 4 -Compress
  foreach($product in @('Microsoft\Edge','Google\Chrome')) {
    $path="$hive\Software\Policies\$product\AutoSelectCertificateForUrls"
    if($Action -eq 'Install'){$null=New-Item -Path $path -Force}
    if(!(Test-Path -LiteralPath $path)){continue}
    $registry=Get-Item -LiteralPath $path
    $matching=@($registry.GetValueNames() | Where-Object {
      try {
        $entry=$registry.GetValue($_)|ConvertFrom-Json
        $entry.pattern -ceq $Origin -and $entry.filter.SUBJECT.CN -ceq $CommonName
      } catch {$false}
    })
    if($Action -eq 'Remove') {
      foreach($name in $matching){Remove-ItemProperty -LiteralPath $path -Name $name}
    } elseif($matching.Count -eq 0) {
      $number=1
      while($registry.GetValueNames() -contains [string]$number){$number++}
      $null=New-ItemProperty -LiteralPath $path -Name ([string]$number) -Value $value -PropertyType String
    }
    if($Action -eq 'Install') {
      $readback=Get-Item -LiteralPath $path
      $found=@($readback.GetValueNames()|Where-Object {
        try {$entry=$readback.GetValue($_)|ConvertFrom-Json; $entry.pattern -ceq $Origin -and $entry.filter.SUBJECT.CN -ceq $CommonName} catch {$false}
      })
      if(!$found.Count){throw '自动选择规则写入后读回不一致，配置未完成。'}
    }
  }
  Write-Output '本站浏览器证书选择规则已处理。'
} catch {Write-Error $_ -ErrorAction Continue; exit 1}

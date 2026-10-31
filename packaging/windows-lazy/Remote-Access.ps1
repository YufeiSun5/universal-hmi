# Project-owned configuration and live digest must match before adopting a backend.
function Resolve-RemoteConfig($Project, [string]$ConfigDirectory) {
  if ($Project.PSObject.Properties.Name -notcontains 'remoteConfig' -or [string]::IsNullOrWhiteSpace($Project.remoteConfig)) { return '' }
  $path=[string]$Project.remoteConfig
  if (![IO.Path]::IsPathRooted($path)) { $path=Join-Path $ConfigDirectory $path }
  $path=[IO.Path]::GetFullPath($path)
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Remote configuration file does not exist.' }
  return $path
}
# Disabled public configuration can be repaired locally without parsing its contents.
function Get-RemoteFileDigest([string]$RemoteConfig) {
  if (!$RemoteConfig) { return '' }
  $hash=[Security.Cryptography.SHA256]::Create()
  try {
    $raw=[IO.File]::ReadAllBytes($RemoteConfig)
    return ([BitConverter]::ToString($hash.ComputeHash($raw))).Replace('-','').ToLowerInvariant()
  } finally {$hash.Dispose()}
}
function Get-RemoteDigest([string]$RemoteConfig) {
  if (!$RemoteConfig) { return '' }
  $raw=[IO.File]::ReadAllBytes($RemoteConfig)
  $config=[Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
  $hash=[Security.Cryptography.SHA256]::Create()
  try {
    $null=$hash.TransformBlock($raw,0,$raw.Length,$raw,0)
    if($config.enabled) {
      foreach($name in @('certificate','private_key')) {
        $path=[string]$config.$name
        if(![IO.Path]::IsPathRooted($path)){$path=Join-Path (Split-Path -Parent $RemoteConfig) $path}
        $bytes=[IO.File]::ReadAllBytes($path)
        $null=$hash.TransformBlock($bytes,0,$bytes.Length,$bytes,0)
      }
    }
    $null=$hash.TransformFinalBlock((New-Object byte[] 0),0,0)
    return ([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
  } finally {$hash.Dispose()}
}
function Assert-RemoteDeployment([string]$Base,[string]$RemoteConfig) {
  try { $actual=Invoke-RestMethod "$Base/api/v1/local/deployment" -TimeoutSec 2 } catch {
    throw 'Cannot verify running backend configuration. Explicitly stop and restart the project background using its own entry; existing service was retained.'
  }
  $repairOnly=($actual.remote_enabled -is [bool]) -and ($actual.remote_enabled -eq $false) -and ![string]::IsNullOrEmpty([string]$actual.remote_config_error)
  if ($repairOnly) { $expected=Get-RemoteFileDigest $RemoteConfig }
  else { $expected=Get-RemoteDigest $RemoteConfig }
  if ($null -eq $actual.remote_config_sha256 -or $actual.remote_config_sha256 -cne $expected) {
    throw 'Remote configuration differs from the running backend. Explicitly stop and restart the project background; existing service was retained.'
  }
}

param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskOutput=(Resolve-Path -LiteralPath $OutputDirectory).Path
$taskGoRoot=Join-Path $taskRoot '.local/toolchains/go-1.24.7/go'
$taskStage=Join-Path $taskRoot 'backend/.local/process-transfer-finalize'
New-Item -ItemType Directory -Force -Path $taskStage | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'process_transfer_finalize.go') -Destination (Join-Path $taskStage 'main.go')
$taskPriorGoRoot=$env:GOROOT
try {
  $env:GOROOT=$taskGoRoot
  Push-Location (Join-Path $taskRoot 'backend')
  try {
    & (Join-Path $taskGoRoot 'bin/go.exe') run './.local/process-transfer-finalize' $taskOutput
    if($LASTEXITCODE -ne 0){throw 'Transfer finalization/actual-codec verification failed'}
  } finally { Pop-Location }
} finally { $env:GOROOT=$taskPriorGoRoot }
$taskContract=Join-Path $taskRoot '.local/process-transfer-contract.md'
if(Test-Path -LiteralPath $taskContract){Copy-Item -LiteralPath $taskContract -Destination (Join-Path $taskOutput 'process-transfer-contract.md')}
elseif(!(Test-Path -LiteralPath (Join-Path $taskOutput 'process-transfer-contract.md'))){throw 'Transfer contract missing from workspace and delivery'}

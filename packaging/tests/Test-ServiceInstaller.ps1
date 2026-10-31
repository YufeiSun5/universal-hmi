# Read-only policy tests: no service, process, directory or ACL is changed.
$ErrorActionPreference='Stop'
$scriptPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-ProjectService.ps1'
$parseErrors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$null,[ref]$parseErrors)
if($parseErrors){throw ($parseErrors|Out-String)}
$tree.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {Invoke-Expression $_.Extent.Text}
function Assert-Rejected([scriptblock]$Check){$rejected=$false;try{& $Check}catch{$rejected=$true};if(!$rejected){throw 'Unsafe policy input was accepted.'}}
if(!(Test-Within 'C:\HMI' 'C:\HMI\project\project.json')){throw 'Descendant path rejected.'}
if(Test-Within 'C:\HMI' 'C:\HMI-other\project.json'){throw 'Sibling path accepted.'}
$operatorSid='S-1-5-21-1-2-3-1001'
$script:aclOwner=$operatorSid
$script:aclRules=@()
function Get-Acl {
 param($LiteralPath)
 $result=New-Object PSObject
 $result|Add-Member ScriptMethod GetAccessRules {param($explicit,$inherited,$type) return $script:aclRules}
 $result|Add-Member ScriptMethod GetOwner {param($type) return [Security.Principal.SecurityIdentifier]::new($script:aclOwner)}
 return $result
}
function Set-TestRule([string]$Sid,[string]$Rights){$script:aclRules=@([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($Sid),[Security.AccessControl.FileSystemRights]$Rights,[Security.AccessControl.AccessControlType]::Allow))}
Set-TestRule 'S-1-5-32-545' 'ReadAndExecute'
Assert-SafeAcl 'fake.exe' $false
Set-TestRule 'S-1-5-32-545' 'Write'
Assert-Rejected {Assert-SafeAcl 'fake.exe' $false}
Set-TestRule 'S-1-5-19' 'Write'
Assert-Rejected {Assert-SafeAcl 'fake.exe' $false}
Assert-SafeAcl 'project.json' $true
Set-TestRule 'S-1-1-0' 'DeleteSubdirectoriesAndFiles'
Assert-Rejected {Assert-SafeAcl 'C:\parent' $false $true}
Set-TestRule 'S-1-1-0' 'CreateDirectories'
Assert-SafeAcl 'C:\parent' $false $true
$script:aclRules=@()
$script:aclOwner='S-1-1-0'
Assert-Rejected {Assert-SafeAcl 'fake.exe' $false}
$script:reparse='C:\bundle'
function Get-Item {param($LiteralPath,[switch]$Force) return [PSCustomObject]@{Attributes=$(if($LiteralPath -eq $script:reparse){[IO.FileAttributes]::ReparsePoint}else{[IO.FileAttributes]::Directory})}}
Assert-Rejected {Assert-NoReparseAncestor 'C:\bundle\project\project.json'}
$script:reparse=''
Assert-NoReparseAncestor 'C:\bundle\project\project.json'
Write-Output 'Service installer policy tests passed (mock ACLs and mock path metadata; no installation).'

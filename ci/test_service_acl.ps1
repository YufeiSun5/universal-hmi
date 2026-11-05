# Exercise the installer ACL predicate with in-memory descriptors, without
# changing any file permission or creating a Windows service.
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../packaging/Install-ProjectService.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installer script parse failed'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-SafeAcl'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$operatorSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:descriptor=$null
function Get-Acl {param($LiteralPath) $script:descriptor}
function Descriptor([Security.AccessControl.PropagationFlags]$Propagation) {
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-11')),'Modify','ContainerInherit,ObjectInherit',$Propagation,'Allow')))
  return $acl
}
$script:descriptor=Descriptor 'InheritOnly'
Assert-SafeAcl 'synthetic-ancestor' $false $true
try {Assert-SafeAcl 'synthetic-deployment' $false;throw 'unsafe deployment accepted'} catch {if($_.Exception.Message -notmatch '^Untrusted write permission'){throw}}
$script:descriptor=Descriptor 'None'
try {Assert-SafeAcl 'synthetic-ancestor' $false $true;throw 'unsafe ancestor accepted'} catch {if($_.Exception.Message -notmatch '^Untrusted write permission'){throw}}
Write-Output 'PASS: ancestor inheritance-only exemption; deployment and direct ancestor write grants still rejected'

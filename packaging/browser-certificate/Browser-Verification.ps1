# Readback is independent of certificate installation. Machine policy has
# precedence over this per-user setting; never overwrite organization policy.
function Get-BrowserPolicyVerification([string]$Origin,[string]$CommonName) {
  $results=@()
  foreach($product in @('Microsoft\Edge','Google\Chrome')) {
    $source='HKCU'
    $path="HKCU:\Software\Policies\$product\AutoSelectCertificateForUrls"
    $machine="HKLM:\Software\Policies\$product\AutoSelectCertificateForUrls"
    if((Test-Path -LiteralPath $machine) -and (Get-Item -LiteralPath $machine).GetValueNames().Count -gt 0){$path=$machine;$source='HKLM'}
    $found=$false
    if(Test-Path -LiteralPath $path) {
      $registry=Get-Item -LiteralPath $path
      foreach($name in $registry.GetValueNames()) {
        try {
          $entry=$registry.GetValue($name)|ConvertFrom-Json
          if($entry.pattern -ceq $Origin -and $entry.filter.SUBJECT.CN -ceq $CommonName){$found=$true}
        } catch {}
      }
    }
    $results+= [pscustomobject]@{browser=$product;source=$source;origin=$Origin;exactRuleReadBack=$found;browserReloadVerified=$false}
  }
  return $results
}
if(-not ('HmiBrowserEndpointVerification' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class HmiBrowserEndpointVerification {
  public static void Verify(string host, int port, string expected) {
    using(var client = new TcpClient()) {
      if(!client.ConnectAsync(host,port).Wait(8000)) throw new TimeoutException("正式地址和端口连接超时");
      using(var stream = new SslStream(client.GetStream(),false,(sender,certificate,chain,errors)=> {
        if(certificate==null || (errors & SslPolicyErrors.RemoteCertificateNameMismatch)!=0) return false;
        using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(certificate.GetRawCertData())).Replace("-","").Equals(expected,StringComparison.OrdinalIgnoreCase);
      })) {
        if(!stream.AuthenticateAsClientAsync(host,new X509CertificateCollection(),SslProtocols.Tls12,false).Wait(8000)) throw new TimeoutException("正式入口 TLS 验证超时");
        if(!stream.IsAuthenticated) throw new AuthenticationException("正式入口证书未验证");
      }
    }
  }
}
'@
}

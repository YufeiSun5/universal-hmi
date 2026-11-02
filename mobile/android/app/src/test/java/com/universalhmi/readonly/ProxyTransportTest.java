package com.universalhmi.readonly;

import static org.junit.Assert.*;
import org.junit.Test;
import java.io.*;
import java.math.BigInteger;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.*;

public class ProxyTransportTest {
    static KeyPair pair() throws Exception {
        KeyPairGenerator generator=KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1")); return generator.generateKeyPair();
    }
    static X509ExtendedKeyManager manager(KeyPair pair,X509Certificate cert) throws Exception {
        KeyStore store=KeyStore.getInstance("PKCS12"); store.load(null);
        store.setKeyEntry("key",pair.getPrivate(),"test".toCharArray(),new java.security.cert.Certificate[]{cert});
        KeyManagerFactory factory=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()); factory.init(store,"test".toCharArray());
        return (X509ExtendedKeyManager)factory.getKeyManagers()[0];
    }
    static X509Certificate serverLeaf(KeyPair pair) throws Exception {
        long now=System.currentTimeMillis();
        byte[] ext=Certificates.der(0xa3,Certificates.seq(
            Certificates.seq(Certificates.oid(2,5,29,19),Certificates.der(4,Certificates.seq())),
            Certificates.seq(Certificates.oid(2,5,29,37),Certificates.der(4,Certificates.seq(Certificates.oid(1,3,6,1,5,5,7,3,1)))),
            Certificates.seq(Certificates.oid(2,5,29,17),Certificates.der(4,Certificates.seq(Certificates.der(0x87,new byte[]{127,0,0,1}))))));
        byte[] info=Certificates.seq(Certificates.der(0xa0,Certificates.integer(BigInteger.valueOf(2))),Certificates.integer(BigInteger.ONE),Certificates.algorithm(),Certificates.name(),
            Certificates.seq(Certificates.time(now-60000),Certificates.time(now+3600000)),Certificates.name(),pair.getPublic().getEncoded(),ext);
        return Certificates.parse(Certificates.seq(info,Certificates.algorithm(),Certificates.signature(info,pair)));
    }
    static final class Site implements AutoCloseable {
        final SSLServerSocket listener;
        final X509Certificate certificate;
        final List<String> requests=Collections.synchronizedList(new ArrayList<>());
        final List<String> errors=Collections.synchronizedList(new ArrayList<>());
        final CountDownLatch streamRelease=new CountDownLatch(1);
        volatile boolean stopped;
        Site(X509Certificate client) throws Exception {
            KeyPair server=pair(); certificate=serverLeaf(server);
            X509TrustManager trust=new X509TrustManager() {
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                public void checkServerTrusted(X509Certificate[] c,String a) { throw new UnsupportedOperationException(); }
                public void checkClientTrusted(X509Certificate[] c,String a) throws java.security.cert.CertificateException {
                    try { if(c.length!=1 || !Arrays.equals(c[0].getEncoded(),client.getEncoded())) throw new Exception(); }
                    catch(Exception e) { throw new java.security.cert.CertificateException(); }
                }
            };
            SSLContext context=SSLContext.getInstance("TLS"); context.init(new KeyManager[]{manager(server,certificate)},new TrustManager[]{trust},null);
            listener=(SSLServerSocket)context.getServerSocketFactory().createServerSocket(0,8,InetAddress.getByName("127.0.0.1")); listener.setNeedClientAuth(true);
            Thread thread=new Thread(() -> {
                while(!stopped) try {
                    SSLSocket socket=(SSLSocket)listener.accept(); socket.setSoTimeout(5000);
                    try(socket) {
                        socket.startHandshake(); assertArrayEquals(client.getEncoded(),socket.getSession().getPeerCertificates()[0].getEncoded());
                        BufferedReader input=new BufferedReader(new InputStreamReader(socket.getInputStream(),StandardCharsets.UTF_8));
                        String first=input.readLine(),line; Map<String,String> headers=new HashMap<>();
                        while((line=input.readLine())!=null&&!line.isEmpty()) { int colon=line.indexOf(':'); headers.put(line.substring(0,colon).toLowerCase(Locale.US),line.substring(colon+1).trim()); }
                        int length=Integer.parseInt(headers.getOrDefault("content-length","0")); char[] body=new char[length]; int offset=0;
                        while(offset<length) { int n=input.read(body,offset,length-offset); if(n<0) throw new EOFException(); offset+=n; }
                        requests.add(first+"|cookie="+headers.get("cookie")+"|body="+new String(body));
                        OutputStream out=socket.getOutputStream();
                        if(first.contains("/runtime/events")) {
                            out.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ready\n\n".getBytes(StandardCharsets.UTF_8)); out.flush(); streamRelease.await(5,TimeUnit.SECONDS);
                        } else {
                            out.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: __Host-hmi_identity=remote-secret; Path=/; Secure; HttpOnly; SameSite=Strict\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".getBytes(StandardCharsets.UTF_8)); out.flush();
                        }
                    }
                } catch(Exception e) { if(!stopped) errors.add(e.getClass().getSimpleName()); }
            }); thread.setDaemon(true); thread.start();
        }
        URI origin() throws Exception { return Certificates.origin("https://127.0.0.1:"+listener.getLocalPort()); }
        public void close() throws Exception { stopped=true; streamRelease.countDown(); listener.close(); }
    }
    static HttpURLConnection request(String url,String cookie) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(url).openConnection(Proxy.NO_PROXY);
        c.setInstanceFollowRedirects(false); c.setConnectTimeout(3000); c.setReadTimeout(3000);
        if(cookie!=null)c.setRequestProperty("Cookie",cookie); return c;
    }
    @Test public void realMutualTLSKeepsRemoteCookieNativeAndBlocksLocalBypasses() throws Exception {
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        try(Site site=new Site(client); ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client))) {
            HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode());
            String cookie=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
            HttpURLConnection denied=request(proxy.origin+"/api/v1/points",null); assertEquals(403,denied.getResponseCode()); denied.disconnect();
            HttpURLConnection write=request(proxy.origin+"/api/v1/points",cookie); write.setRequestMethod("PUT"); assertEquals(403,write.getResponseCode()); write.disconnect();
            HttpURLConnection login=request(proxy.origin+"/api/v1/auth/login",cookie); login.setDoOutput(true); login.setRequestProperty("Content-Type","application/json");
            String body="{\"username\":\"owner\",\"password\":\"opaque\"}";
            try(OutputStream out=login.getOutputStream()){out.write(body.getBytes(StandardCharsets.UTF_8));}
            assertEquals(200,login.getResponseCode()); assertNull(login.getHeaderField("Set-Cookie")); login.getInputStream().readAllBytes(); login.disconnect();
            HttpURLConnection read=request(proxy.origin+"/api/v1/points",cookie); assertEquals(200,read.getResponseCode()); read.getInputStream().readAllBytes(); read.disconnect();
            assertEquals(2,site.requests.size()); assertTrue(site.requests.get(0).endsWith("body="+body));
            assertTrue(site.requests.get(1).contains("cookie=__Host-hmi_identity=remote-secret"));
            assertFalse(site.requests.toString().contains("hmi_loopback")); assertTrue(site.errors.toString(),site.errors.isEmpty());
            HttpURLConnection stream=request(proxy.origin+"/api/v1/runtime/events",cookie);
            assertEquals(200,stream.getResponseCode()); byte[] event=new byte[13]; assertEquals(13,stream.getInputStream().readNBytes(event,0,event.length));
            assertEquals("data: ready\n\n",new String(event,StandardCharsets.UTF_8)); stream.disconnect();
        }
    }
    @Test public void wrongServerPinFailsBeforeAnyHTTPIsSent() throws Exception {
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        try(Site site=new Site(client); ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),serverLeaf(pair()),manager(key,client))) {
            HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode()); String cookie=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
            HttpURLConnection read=request(proxy.origin+"/api/v1/points",cookie); assertEquals(502,read.getResponseCode()); read.disconnect(); assertTrue(site.requests.isEmpty());
        }
    }
}

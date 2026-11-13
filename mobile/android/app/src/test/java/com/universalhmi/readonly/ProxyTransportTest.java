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
        volatile byte[] lastBody;
        volatile Map<String,String> lastHeaders;
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
                        InputStream input=new BufferedInputStream(socket.getInputStream());
                        String first=line(input),line; Map<String,String> headers=new HashMap<>();
                        while((line=line(input))!=null&&!line.isEmpty()) { int colon=line.indexOf(':'); headers.put(line.substring(0,colon).toLowerCase(Locale.US),line.substring(colon+1).trim()); }
                        int length=Integer.parseInt(headers.getOrDefault("content-length","0")); byte[] body=new byte[length]; int offset=0;
                        while(offset<length) { int n=input.read(body,offset,length-offset); if(n<0) throw new EOFException(); offset+=n; }
                        lastBody=body;lastHeaders=headers;
                        requests.add(first+"|cookie="+headers.get("cookie")+"|body="+new String(body,StandardCharsets.UTF_8));
                        OutputStream out=socket.getOutputStream();
                        if(first.contains("/hmi.runtime.v1.RuntimeService/Subscribe")) {
                            out.write("HTTP/1.1 200 OK\r\nContent-Type: application/grpc-web+proto\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.UTF_8));
                            out.write(new byte[]{0,0,0,0,3,10,(byte)255,0});out.flush();streamRelease.await(5,TimeUnit.SECONDS);
                            byte[] trailer="grpc-status: 0\r\n".getBytes(StandardCharsets.US_ASCII);
                            out.write(new byte[]{(byte)128,0,0,0,(byte)trailer.length});out.write(trailer);out.flush();
                        } else if(first.contains("/runtime/events")) {
                            out.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ready\n\n".getBytes(StandardCharsets.UTF_8)); out.flush(); streamRelease.await(5,TimeUnit.SECONDS);
                        } else {
                            String session=first.startsWith("POST /api/v1/auth/logout ") ? "" : "remote-secret";
                            String age=session.isEmpty() ? "0" : "3600";
                            out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: __Host-hmi_identity="+session+"; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age="+age+"\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").getBytes(StandardCharsets.UTF_8)); out.flush();
                        }
                    }
                } catch(Exception e) { if(!stopped) errors.add(e.getClass().getSimpleName()); }
            }); thread.setDaemon(true); thread.start();
        }
        URI origin() throws Exception { return Certificates.origin("https://127.0.0.1:"+listener.getLocalPort()); }
        public void close() throws Exception { stopped=true; streamRelease.countDown(); listener.close(); }
    }
    static String line(InputStream in) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();int c;
        while((c=in.read())!=-1){if(c==10)return out.toString(StandardCharsets.US_ASCII.name()).replace("\r","");out.write(c);}
        throw new EOFException();
    }
    @Test public void grpcWebStreamsBinaryImmediatelyThroughPinnedMutualTLS() throws Exception {
        KeyPair key=pair();X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        try(Site site=new Site(client);ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client))) {
            HttpURLConnection launch=request(proxy.startURL(),null);assertEquals(303,launch.getResponseCode());
            assertEquals("/?view=overview&client=android",launch.getHeaderField("Location"));
            String cookie=launch.getHeaderField("Set-Cookie").split(";",2)[0];launch.disconnect();
            HttpURLConnection login=request(proxy.origin+"/api/v1/auth/session",cookie);assertEquals(200,login.getResponseCode());login.getInputStream().readAllBytes();login.disconnect();
            HttpURLConnection stream=request(proxy.origin+"/api/v1/hmi.runtime.v1.RuntimeService/Subscribe",cookie);
            stream.setRequestMethod("POST");stream.setDoOutput(true);stream.setRequestProperty("Content-Type","application/grpc-web+proto");
            stream.setRequestProperty("X-Grpc-Web","1");stream.setRequestProperty("X-CSRF-Token","fixture-csrf");
            byte[] body={0,0,0,0,3,10,(byte)255,0};try(OutputStream out=stream.getOutputStream()){out.write(body);}
            assertEquals(200,stream.getResponseCode());assertEquals("application/grpc-web+proto",stream.getContentType());
            InputStream in=stream.getInputStream();assertArrayEquals(body,in.readNBytes(8));
            assertArrayEquals(body,site.lastBody);assertEquals("fixture-csrf",site.lastHeaders.get("x-csrf-token"));
            assertEquals("1",site.lastHeaders.get("x-grpc-web"));assertEquals("__Host-hmi_identity=remote-secret",site.lastHeaders.get("cookie"));
            site.streamRelease.countDown();byte[] rest=in.readAllBytes();assertEquals((byte)128,rest[0]);
            assertEquals("grpc-status: 0\r\n",new String(rest,5,rest.length-5,StandardCharsets.US_ASCII));stream.disconnect();
        }
    }
    static HttpURLConnection request(String url,String cookie) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(url).openConnection(Proxy.NO_PROXY);
        c.setInstanceFollowRedirects(false); c.setConnectTimeout(3000); c.setReadTimeout(3000);
        if(cookie!=null)c.setRequestProperty("Cookie",cookie); return c;
    }
    @Test public void passwordStorageIsNativeOnlyAndRejectsForeignOrUnauthenticatedRequests() throws Exception {
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        LoginCredentials credentials=new LoginCredentials(new IdentitySessionTest.Memory());
        credentials.update(LoginCredentialsTest.save("first","synthetic-only"));
        try(Site site=new Site(client); ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client),new SupplierCookies(null),null,new IdentitySession(null),credentials)) {
            HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode());
            String cookie=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
            for(int mode=0;mode<4;mode++) {
                URI local=URI.create(proxy.origin);
                try(Socket socket=new Socket(local.getHost(),local.getPort())) {
                    socket.setSoTimeout(3000);
                    String headers="Host: "+local.getRawAuthority()+"\r\n";
                    if(mode!=0) headers+="Cookie: "+cookie+"\r\n";
                    if(mode!=1) headers+="X-HMI-Native: credentials\r\n";
                    if(mode==2) headers+="Sec-Fetch-Site: cross-site\r\n";
                    socket.getOutputStream().write(("GET /mobile/login-credentials HTTP/1.1\r\n"+headers+"\r\n").getBytes(StandardCharsets.UTF_8));
                    String result=new String(socket.getInputStream().readAllBytes(),StandardCharsets.UTF_8);
                    assertTrue("mode "+mode+": "+result.split("\r\n",2)[0],result.startsWith("HTTP/1.1 "+(mode==3?200:403)+" "));
                    if(mode==3) {
                        assertTrue(result.contains("Cache-Control: no-store"));
                        assertEquals("synthetic-only",LoginCredentials.form(result.split("\r\n\r\n",2)[1]).get("password"));
                    }
                }
            }
            assertTrue("Passwords must never be forwarded upstream",site.requests.isEmpty());
        }
    }
    @Test public void rememberedSessionSurvivesProxyRecreationButNotLogout() throws Exception {
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        IdentitySessionTest.Memory storage=new IdentitySessionTest.Memory();
        try(Site site=new Site(client)) {
            for(int step=0;step<3;step++) {
                try(ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client),new SupplierCookies(null),null,new IdentitySession(storage))) {
                    HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode());
                    String local=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
                    String path=step==0 ? "/api/v1/auth/login" : step==1 ? "/api/v1/auth/logout" : "/api/v1/auth/session";
                    HttpURLConnection call=request(proxy.origin+path,local);
                    if(step<2) { call.setRequestMethod("POST"); call.setDoOutput(true); call.getOutputStream().close(); }
                    assertEquals(200,call.getResponseCode()); assertNull(call.getHeaderField("Set-Cookie"));
                    call.getInputStream().readAllBytes(); call.disconnect();
                    assertTrue(site.requests.get(step).contains("cookie="+(step==1 ? "__Host-hmi_identity=remote-secret" : "null")));
                }
            }
            assertTrue(site.errors.toString(),site.errors.isEmpty());
        }
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
    @Test public void bundledPresentationNeedsLocalCapabilityAndNeverCachesBusinessResponses() throws Exception {
        byte[] index="index.html\ttext/html\t5\ncanvaskit/skwasm.wasm\tapplication/wasm\t4\n".getBytes(StandardCharsets.UTF_8);
        BundledWeb web=new BundledWeb(new ByteArrayInputStream(index),name -> new ByteArrayInputStream(
            name.equals("index.html")?"local".getBytes(StandardCharsets.UTF_8):new byte[]{0,97,115,109}));
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        try(Site site=new Site(client); ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client),new SupplierCookies(null),web)) {
            HttpURLConnection denied=request(proxy.origin+"/",null); assertEquals(403,denied.getResponseCode()); denied.disconnect();
            HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode());
            String cookie=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
            HttpURLConnection page=request(proxy.origin+"/?view=runtime",cookie); assertEquals(200,page.getResponseCode());
            assertEquals("local",new String(page.getInputStream().readAllBytes(),StandardCharsets.UTF_8)); page.disconnect();
            HttpURLConnection wasm=request(proxy.origin+"/canvaskit/skwasm.wasm?v=123",cookie); wasm.setRequestMethod("HEAD");
            assertEquals(200,wasm.getResponseCode()); assertEquals("application/wasm",wasm.getContentType());
            assertEquals(4,wasm.getContentLength()); assertEquals(0,wasm.getInputStream().readAllBytes().length); wasm.disconnect();
            for(String path:new String[]{"/assets/missing.ttf","/flutter_service_worker.js"}) {
                HttpURLConnection missing=request(proxy.origin+path,cookie); assertEquals(404,missing.getResponseCode()); missing.disconnect();
            }
            for(String path:new String[]{"/assets/../index.html","/assets/%2e%2e/index.html","/assets/%2findex.html"}) {
                HttpURLConnection traversal=request(proxy.origin+path,cookie); assertEquals(403,traversal.getResponseCode()); traversal.disconnect();
            }
            HttpURLConnection write=request(proxy.origin+"/index.html",cookie); write.setRequestMethod("POST"); assertEquals(403,write.getResponseCode()); write.disconnect();
            assertTrue("Static bytes must never use the network",site.requests.isEmpty());
            for(int i=0;i<2;i++) {
                HttpURLConnection api=request(proxy.origin+"/api/v1/points",cookie); assertEquals(200,api.getResponseCode());
                api.getInputStream().readAllBytes(); api.disconnect();
            }
            assertEquals("Every business request must still authenticate upstream",2,site.requests.size());
        }
    }
    @Test public void maintenanceWritesForwardBodiesThroughMutualTLS() throws Exception {
        KeyPair key=pair(); X509Certificate client=Certificates.parse(Certificates.leaf(key,System.currentTimeMillis()));
        try(Site site=new Site(client); ReadonlyProxy proxy=new ReadonlyProxy(site.origin(),site.certificate,manager(key,client))) {
            HttpURLConnection start=request(proxy.startURL(),null); assertEquals(303,start.getResponseCode());
            String cookie=start.getHeaderField("Set-Cookie").split(";",2)[0]; start.disconnect();
            String[] methods={"PUT","DELETE","POST"};
            String[] paths={"/api/v1/security/users/u1","/api/v1/equipment/e1/photos/p1","/api/v1/equipment/e1/photos"};
            for(int i=0;i<methods.length;i++) {
                String payload=i==2 ? "{\"data\":\""+"A".repeat(70000)+"\"}" : "{\"revision\":7}";
                HttpURLConnection call=request(proxy.origin+paths[i],cookie);call.setRequestMethod(methods[i]);call.setDoOutput(true);
                call.setRequestProperty("Content-Type","application/json");call.setRequestProperty("X-CSRF-Token","synthetic-csrf");
                call.getOutputStream().write(payload.getBytes(StandardCharsets.UTF_8));call.getOutputStream().close();
                assertEquals(200,call.getResponseCode());call.getInputStream().readAllBytes();call.disconnect();
                assertTrue(site.requests.get(i).startsWith(methods[i]+" "+paths[i]+" "));
                assertTrue(site.requests.get(i).endsWith("|body="+payload));
            }
            assertTrue(site.errors.toString(),site.errors.isEmpty());
        }
    }
}

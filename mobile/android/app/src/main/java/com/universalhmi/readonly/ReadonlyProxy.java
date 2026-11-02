package com.universalhmi.readonly;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.*;

/** Ephemeral WebView transport adapter; owns no business data or control API. */
final class ReadonlyProxy implements AutoCloseable {
    private final URI remote;
    private final SSLSocketFactory tls;
    private final ServerSocket listener;
    private final Set<Socket> sockets=ConcurrentHashMap.newKeySet();
    private final Set<HttpsURLConnection> connections=ConcurrentHashMap.newKeySet();
    private final ThreadPoolExecutor workers=new ThreadPoolExecutor(8,8,30,TimeUnit.SECONDS,new ArrayBlockingQueue<>(32));
    private final String capability, cookie;
    private volatile String identityCookie="";
    private volatile boolean closed;
    final String origin;

    ReadonlyProxy(URI remote,X509Certificate pin,X509ExtendedKeyManager device) throws Exception {
        this.remote=remote; Certificates.verifyServer(pin,remote);
        byte[] expected=pin.getEncoded();
        X509TrustManager trust=new X509TrustManager() {
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            public void checkClientTrusted(X509Certificate[] chain,String auth) throws CertificateException { throw new CertificateException("not a server"); }
            public void checkServerTrusted(X509Certificate[] chain,String auth) throws CertificateException {
                try {
                    if (chain.length==0 || !MessageDigest.isEqual(expected,chain[0].getEncoded())) throw new CertificateException("server pin mismatch");
                    Certificates.verifyServer(chain[0],remote);
                } catch (Exception e) { throw new CertificateException("server identity rejected"); }
            }
        };
        SSLContext context=SSLContext.getInstance("TLS"); context.init(new KeyManager[]{device},new TrustManager[]{trust},new SecureRandom()); tls=context.getSocketFactory();
        listener=new ServerSocket(); listener.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"),0),16);
        origin="http://127.0.0.1:"+listener.getLocalPort(); capability=random(); cookie=random();
        Thread accept=new Thread(() -> {
            while (!closed) {
                try {
                    Socket socket=listener.accept(); socket.setSoTimeout(15000); sockets.add(socket);
                    try { workers.execute(() -> serve(socket)); } catch (RejectedExecutionException e) { sockets.remove(socket); socket.close(); }
                } catch (IOException e) { if (!closed) close(); }
            }
        },"hmi-loopback-accept"); accept.setDaemon(true); accept.start();
    }
    String startURL() { return origin+"/launch/"+capability; }
    private static String random() { byte[] bytes=new byte[32]; new SecureRandom().nextBytes(bytes); return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes); }
    private static String line(InputStream input,int maximum) throws IOException {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        while (bytes.size()<=maximum) {
            int value=input.read(); if (value<0) throw new EOFException();
            if (value==13) { if (input.read()!=10) throw new IOException("invalid line"); return bytes.toString(StandardCharsets.ISO_8859_1.name()); }
            if (value==10 || value==0) throw new IOException("invalid line"); bytes.write(value);
        }
        throw new IOException("line too long");
    }
    static boolean readonly(String method,String rawPath) {
        String lower=rawPath.toLowerCase(Locale.US);
        if (!rawPath.startsWith("/") || rawPath.startsWith("//") || lower.contains("%2f") || lower.contains("%5c") || lower.contains("%2e") || rawPath.contains("\\") || rawPath.contains("//")) return false;
        String path=rawPath.split("\\?",2)[0];
        if (Arrays.asList(path.split("/",-1)).contains("..") || Arrays.asList(path.split("/",-1)).contains(".")) return false;
        boolean get="GET".equals(method)||"HEAD".equals(method);
        if (path.equals("/health")) return get;
        if ((path.equals("/api/v1/auth/session")||path.equals("/api/v1/auth/captcha"))) return get;
        if (path.equals("/api/v1/auth/login")||path.equals("/api/v1/auth/logout")||path.equals("/api/v1/security/mfa/begin")||path.equals("/api/v1/security/mfa/confirm")) return "POST".equals(method);
        if ("POST".equals(method) && path.matches("/api/v1/external/screens/[^/]+/query")) return true;
        if (get && (path.matches("/api/v1/(stations|points|runtime|runtime/events|screens|navigation|equipment|equipment/status|equipment-navigation|external/screens)") ||
            path.matches("/api/v1/(screens|equipment)/[^/]+") || path.matches("/api/v1/equipment/[^/]+/photos/[^/]+") || path.matches("/api/v1/external/screens/[^/]+/stations"))) return true;
        if (path.equals("/api") || path.startsWith("/api/") || path.equals("/mcp") || path.startsWith("/mcp/") || path.equals("/mobile") || path.startsWith("/mobile/")) return false;
        return get;
    }
    private boolean authorized(Map<String,String> headers) {
        String supplied=headers.getOrDefault("cookie",""); int count=0;
        for (String part:supplied.split(";")) {
            String[] pieces=part.trim().split("=",2);
            if (pieces.length==2 && pieces[0].equals("hmi_loopback") && MessageDigest.isEqual(pieces[1].getBytes(StandardCharsets.UTF_8),cookie.getBytes(StandardCharsets.UTF_8))) count++;
        }
        String source=headers.get("origin"), site=headers.get("sec-fetch-site");
        return count==1 && (source==null||origin.equals(source)) && !"cross-site".equals(site) && !"same-site".equals(site);
    }
    private static void response(OutputStream output,int status,String extra,byte[] body) throws IOException {
        output.write(("HTTP/1.1 "+status+" Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: "+body.length+"\r\n"+extra+"\r\n").getBytes(StandardCharsets.ISO_8859_1)); output.write(body); output.flush();
    }
    private synchronized void cookies(HttpsURLConnection connection) {
        for (Map.Entry<String,List<String>> entry:connection.getHeaderFields().entrySet()) {
            if (entry.getKey()==null||!entry.getKey().equalsIgnoreCase("Set-Cookie")) continue;
            for (String value:entry.getValue()) for (HttpCookie item:HttpCookie.parse(value)) if ("__Host-hmi_identity".equals(item.getName())) {
                if (!item.getSecure() || !item.isHttpOnly() || item.getDomain()!=null || !"/".equals(item.getPath())) continue;
                identityCookie=item.hasExpired() ? "" : item.getName()+"="+item.getValue();
            }
        }
    }
    private void serve(Socket socket) {
        HttpsURLConnection connection=null;
        try {
            InputStream input=new BufferedInputStream(socket.getInputStream()); OutputStream output=socket.getOutputStream();
            String[] request=line(input,8192).split(" ",-1);
            if (request.length!=3 || !"HTTP/1.1".equals(request[2])) { response(output,400,"",new byte[0]); return; }
            Map<String,String> headers=new HashMap<>(); int size=0;
            while (true) {
                String text=line(input,8192); size+=text.length()+2;
                if (size>32768 || headers.size()>64) throw new IOException("headers too large");
                if (text.isEmpty()) break;
                int colon=text.indexOf(':');
                if (colon<1 || !text.substring(0,colon).matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+")) throw new IOException("invalid header");
                String name=text.substring(0,colon).toLowerCase(Locale.US),value=text.substring(colon+1).trim();
                if (headers.put(name,value)!=null) throw new IOException("duplicate header");
            }
            if (!origin.substring(7).equals(headers.get("host")) || headers.containsKey("transfer-encoding") || headers.containsKey("expect")) { response(output,400,"",new byte[0]); return; }
            if ("GET".equals(request[0]) && request[1].equals("/launch/"+capability)) {
                response(output,303,"Location: /?view=runtime\r\nSet-Cookie: hmi_loopback="+cookie+"; Path=/; HttpOnly; SameSite=Strict\r\n",new byte[0]); return;
            }
            if (!authorized(headers) || !readonly(request[0],request[1])) { response(output,403,"",new byte[0]); return; }
            int length=Integer.parseInt(headers.getOrDefault("content-length","0"));
            if (length<0||length>65536 || (!"POST".equals(request[0]) && length!=0)) { response(output,413,"",new byte[0]); return; }
            byte[] body=new byte[length]; int offset=0;
            while (offset<length) { int read=input.read(body,offset,length-offset); if (read<0) throw new EOFException(); offset+=read; }
            URI target=remote.resolve(new URI(request[1]));
            if (!remote.getScheme().equals(target.getScheme()) || !remote.getRawAuthority().equals(target.getRawAuthority())) { response(output,403,"",new byte[0]); return; }
            connection=(HttpsURLConnection)target.toURL().openConnection(Proxy.NO_PROXY); connections.add(connection);
            connection.setSSLSocketFactory(tls); connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(10000); connection.setReadTimeout(35000);
            connection.setRequestMethod(request[0]);
            for (String name:new String[]{"accept","accept-language","content-type","user-agent","x-csrf-token","last-event-id","range","if-none-match","if-modified-since"}) {
                if (headers.containsKey(name)) connection.setRequestProperty(name,headers.get(name));
            }
            connection.setRequestProperty("Accept-Encoding","identity");
            connection.setRequestProperty("Origin",remote.toString());
            if (!identityCookie.isEmpty()) connection.setRequestProperty("Cookie",identityCookie);
            if ("POST".equals(request[0])) { connection.setDoOutput(true); connection.setFixedLengthStreamingMode(length); try(OutputStream upstream=connection.getOutputStream()) { upstream.write(body); } }
            int status=connection.getResponseCode(); cookies(connection);
            if (status>=300&&status<400 && status!=304) { response(output,502,"",new byte[0]); return; }
            StringBuilder head=new StringBuilder("HTTP/1.1 "+status+" Response\r\nConnection: close\r\nCache-Control: no-store\r\n");
            for (String name:new String[]{"Content-Type","Content-Range","Accept-Ranges","ETag","X-Content-Type-Options"}) {
                String value=connection.getHeaderField(name);
                if (value!=null && !value.contains("\r") && !value.contains("\n")) head.append(name).append(": ").append(value).append("\r\n");
            }
            head.append("\r\n"); output.write(head.toString().getBytes(StandardCharsets.ISO_8859_1)); output.flush();
            if (!"HEAD".equals(request[0])) {
                InputStream upstream=status>=400 ? connection.getErrorStream() : connection.getInputStream();
                if (upstream!=null) try(InputStream data=upstream) { byte[] buffer=new byte[32768]; int read; while (!closed&&(read=data.read(buffer))>=0) { output.write(buffer,0,read); output.flush(); } }
            }
        } catch (Exception ignored) {
            // Fixed generic failure only; never log request bodies, cookies or TLS keys.
            try { if (!socket.isClosed()) response(socket.getOutputStream(),502,"",new byte[0]); } catch(IOException ignoredAgain) { }
        } finally {
            if (connection!=null) { connections.remove(connection); connection.disconnect(); }
            sockets.remove(socket);
            try { socket.close(); } catch(IOException ignored) { }
        }
    }
    @Override public void close() {
        closed=true; identityCookie="";
        try { listener.close(); } catch(IOException ignored) { }
        for (Socket socket:sockets) try { socket.close(); } catch(IOException ignored) { }
        for (HttpsURLConnection connection:connections) connection.disconnect();
        workers.shutdownNow();
    }
}

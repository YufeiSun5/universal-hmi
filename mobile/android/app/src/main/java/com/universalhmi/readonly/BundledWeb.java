package com.universalhmi.readonly;

import java.io.*;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Immutable, release-indexed presentation files. Never stores API responses. */
final class BundledWeb {
    interface Open { InputStream open(String name) throws IOException; }
    private final Open files;
    private final Map<String,Entry> index=new HashMap<>();
    private static final class Entry {
        final String name, type; final long size;
        Entry(String name,String type,long size) { this.name=name; this.type=type; this.size=size; }
    }
    BundledWeb(InputStream manifest,Open files) throws IOException {
        this.files=files;
        try(BufferedReader input=new BufferedReader(new InputStreamReader(manifest,StandardCharsets.UTF_8))) {
            String line;
            while((line=input.readLine())!=null) {
                String[] fields=line.split("\t",-1);
                if(fields.length!=3 || !staticPath("/"+fields[0]) || fields[0].contains("..") ||
                        !fields[1].matches("[a-zA-Z0-9.+/-]+")) throw new IOException("invalid bundled index");
                long size;
                try { size=Long.parseLong(fields[2]); } catch(NumberFormatException e) { throw new IOException("invalid bundled size",e); }
                if(size<0 || index.put("/"+fields[0],new Entry(fields[0],fields[1],size))!=null) throw new IOException("invalid bundled entry");
            }
        }
        if(!index.containsKey("/index.html")) throw new IOException("missing bundled entry");
    }
    static boolean staticPath(String path) {
        return path.equals("/") || path.matches("/(index.html|hmi_start.js|flutter_bootstrap.js|flutter.js|flutter_service_worker.js|main.dart.js|main.dart.mjs|main.dart.wasm|favicon.png|manifest.json|version.json)") ||
            path.startsWith("/assets/") || path.startsWith("/canvaskit/") || path.startsWith("/icons/") || path.startsWith("/gis/");
    }
    boolean serve(String method,String target,OutputStream output) throws Exception {
        String path=new URI(target).getPath();
        if(!staticPath(path)) return false;
        if(path.equals("/")) path="/index.html";
        Entry entry=index.get(path);
        if(entry==null) {
            output.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: 0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            return true;
        }
        try(InputStream input=files.open(entry.name)) {
            output.write(("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Type: "+entry.type+"\r\nContent-Length: "+entry.size+"\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            if(!method.equals("HEAD")) {
                byte[] buffer=new byte[32768]; long remaining=entry.size;
                while(remaining>0) {
                    int count=input.read(buffer,0,(int)Math.min(buffer.length,remaining));
                    if(count<0) throw new EOFException("truncated bundled asset");
                    output.write(buffer,0,count); remaining-=count;
                }
            }
        }
        return true;
    }
}

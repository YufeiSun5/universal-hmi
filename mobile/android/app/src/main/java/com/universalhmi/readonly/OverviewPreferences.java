package com.universalhmi.readonly;

import java.io.*;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** UI position only, persisted by Android and scoped to this installation/server.
 * Random loopback ports and WebView cache clearing must not erase this choice.
 * Remembered row IDs never grant access: Flutter resolves them against the
 * server's current authorized overview before rendering/subscribing.
 */
final class OverviewPreferences {
    private final SupplierCookies.Persistence storage;
    private final LinkedHashMap<String,String> entries=new LinkedHashMap<>();
    OverviewPreferences(SupplierCookies.Persistence storage) throws Exception {
        this.storage=storage;
        String raw=storage==null?null:storage.load();
        if(raw==null||raw.isEmpty())return;
        try(DataInputStream in=new DataInputStream(new ByteArrayInputStream(Base64.getDecoder().decode(raw)))) {
            if(raw.length()>65536||in.readInt()!=1)throw new IOException();
            int count=in.readInt();if(count<0||count>32)throw new IOException();
            for(int i=0;i<count;i++) {String user=in.readUTF(),value=in.readUTF();if(user.length()>128||value.length()>4096||entries.put(user,value)!=null)throw new IOException();}
            if(in.available()!=0)throw new IOException();
        }catch(Exception e){entries.clear();if(storage!=null)storage.save("");}
    }
    synchronized String request(String encoded) throws Exception {
        Map<String,String> form=LoginCredentials.form(encoded);
        String user=form.getOrDefault("username","");
        if(user.length()>128||user.indexOf('\n')>=0||user.indexOf('\r')>=0)throw new IllegalArgumentException();
        String action=form.get("action");
        if("load".equals(action))return entries.getOrDefault(user,"");
        if(!"save".equals(action)||!new HashSet<>(Arrays.asList("action","username","row","group","table")).containsAll(form.keySet()))throw new IllegalArgumentException();
        String row=form.getOrDefault("row",""),group=form.getOrDefault("group",""),table=form.getOrDefault("table","false");
        if(row.length()>128||group.length()>128||!(table.equals("true")||table.equals("false")))throw new IllegalArgumentException();
        String value="row="+URLEncoder.encode(row,StandardCharsets.UTF_8.name())+"&group="+URLEncoder.encode(group,StandardCharsets.UTF_8.name())+"&table="+table;
        LinkedHashMap<String,String> next=new LinkedHashMap<>(entries);
        next.remove(user);next.put(user,value);while(next.size()>32)next.remove(next.keySet().iterator().next());
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(DataOutputStream out=new DataOutputStream(bytes)){out.writeInt(1);out.writeInt(next.size());for(Map.Entry<String,String> e:next.entrySet()){out.writeUTF(e.getKey());out.writeUTF(e.getValue());}}
        if(storage==null)throw new IOException("native preferences unavailable");
        String saved=Base64.getEncoder().encodeToString(bytes.toByteArray());
        if(saved.length()>65536)throw new IOException("native preferences full");
        storage.save(saved);
        entries.clear();entries.putAll(next);return value;
    }
}

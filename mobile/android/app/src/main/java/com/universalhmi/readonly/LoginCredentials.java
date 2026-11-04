package com.universalhmi.readonly;

import java.io.*;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Opt-in account passwords. The supplied persistence is Android Keystore encrypted. */
final class LoginCredentials {
    private final SupplierCookies.Persistence storage;
    private final LinkedHashMap<String,String> accounts=new LinkedHashMap<>();
    private String selected="";
    LoginCredentials(SupplierCookies.Persistence storage) throws Exception {
        this.storage=storage;
        String raw=storage==null ? null : storage.load();
        if(raw==null || raw.isEmpty()) return;
        try(DataInputStream input=new DataInputStream(new ByteArrayInputStream(Base64.getDecoder().decode(raw)))) {
            if(input.readInt()!=1) throw new IOException("unsupported credentials");
            selected=input.readUTF(); int count=input.readInt();
            if(count<0 || count>4096 || raw.length()>262144) throw new IOException("invalid credentials");
            for(int i=0;i<count;i++) {
                String name=input.readUTF(),password=input.readUTF(); validate(name,password);
                if(accounts.put(name,password)!=null) throw new IOException("duplicate account");
            }
            if(input.available()!=0 || (!selected.isEmpty() && !accounts.containsKey(selected))) throw new IOException("invalid selection");
        } catch(Exception e) {
            accounts.clear(); selected="";
            if(storage!=null) storage.save("");
        }
    }
    private static void validate(String username,String password) {
        if(username.isBlank() || username.length()>128 || username.indexOf('\n')>=0 || username.indexOf('\r')>=0 || password.isEmpty() || password.length()>1024)
            throw new IllegalArgumentException("invalid credentials");
    }
    static Map<String,String> form(String encoded) {
        Map<String,String> result=new HashMap<>();
        for(String field:encoded.split("&")) {
            String[] pair=field.split("=",2);
            if(pair.length!=2 || result.put(decode(pair[0]),decode(pair[1]))!=null)
                throw new IllegalArgumentException("invalid form");
        }
        return result;
    }
    private static String decode(String value) {
        try { return URLDecoder.decode(value,"UTF-8"); }
        catch(UnsupportedEncodingException e) { throw new AssertionError(e); }
    }
    private static String encode(String value) {
        try { return URLEncoder.encode(value,"UTF-8"); }
        catch(UnsupportedEncodingException e) { throw new AssertionError(e); }
    }
    synchronized String read() {
        return "accounts="+encode(String.join("\n",accounts.keySet()))+"&username="+encode(selected)+"&password="+encode(accounts.getOrDefault(selected,""));
    }
    synchronized String update(String body) throws Exception {
        Map<String,String> form=form(body);
        String action=form.getOrDefault("action",""), name=form.getOrDefault("username","");
        LinkedHashMap<String,String> previous=new LinkedHashMap<>(accounts); String oldSelected=selected;
        try {
            switch(action) {
                case "select":
                    if(!accounts.containsKey(name)) throw new IllegalArgumentException("missing account");
                    selected=name; break;
                case "save":
                    String password=form.getOrDefault("password",""); validate(name,password);
                    accounts.put(name,password); selected=name; break;
                case "remove": accounts.remove(name); if(selected.equals(name)) selected=""; break;
                case "clear": accounts.clear(); selected=""; break;
                default: throw new IllegalArgumentException("invalid action");
            }
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            try(DataOutputStream output=new DataOutputStream(bytes)) {
                output.writeInt(1); output.writeUTF(selected); output.writeInt(accounts.size());
                for(Map.Entry<String,String> entry:accounts.entrySet()) { output.writeUTF(entry.getKey()); output.writeUTF(entry.getValue()); }
            }
            String raw=accounts.isEmpty()?"":Base64.getEncoder().encodeToString(bytes.toByteArray());
            if(raw.length()>262144) throw new IOException("credential storage full");
            if(storage==null) throw new IOException("secure credential storage unavailable");
            storage.save(raw);
        } catch(Exception e) { accounts.clear(); accounts.putAll(previous); selected=oldSelected; throw e; }
        return read();
    }
}

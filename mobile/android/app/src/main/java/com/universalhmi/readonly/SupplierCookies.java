package com.universalhmi.readonly;

import java.net.HttpCookie;
import java.util.*;
import java.io.*;

/** Supplier sessions only. HMI credentials never enter supplier storage. */
final class SupplierCookies {
    interface Persistence { String load() throws Exception; void save(String value) throws Exception; }
    private final Persistence persistence;
    private final Properties values=new Properties();
    SupplierCookies(Persistence persistence) throws Exception {
        this.persistence=persistence;
        if(persistence!=null) {
            String saved=persistence.load();
            if(saved!=null && saved.length()<=65536) values.load(new StringReader(saved));
        }
    }
    synchronized void accept(String site,List<String> headers) throws Exception {
        String prefix="hmi_ext_"+site+"_";
        for(String header:headers) for(HttpCookie c:HttpCookie.parse(header)) {
            if(!c.getName().startsWith(prefix) || c.getDomain()!=null || !c.getSecure()) continue;
            if(c.hasExpired()) { values.remove(c.getName()); continue; }
            // Restore browser sessions between app launches; supplier expiry/revocation still wins.
            long seconds=c.getMaxAge()<0?2592000:Math.min(c.getMaxAge(),31536000);
            values.setProperty(c.getName(),(System.currentTimeMillis()+seconds*1000)+"|"+c.getValue());
        }
        if(values.size()>256) throw new IOException("supplier cookie limit");
        if(persistence!=null) {
            StringWriter out=new StringWriter(); values.store(out,null); persistence.save(out.toString());
        }
    }
    synchronized String header(String site) {
        List<String> out=new ArrayList<>(); String prefix="hmi_ext_"+site+"_";
        for(String name:new ArrayList<>(values.stringPropertyNames())) {
            String[] parts=values.getProperty(name).split("\\|",2);
            try {
                if(parts.length!=2 || Long.parseLong(parts[0])<=System.currentTimeMillis()) { values.remove(name); continue; }
                if(name.startsWith(prefix) && !parts[1].contains("\r") && !parts[1].contains("\n")) out.add(name+"="+parts[1]);
            } catch(NumberFormatException e) { values.remove(name); }
        }
        return String.join("; ",out);
    }
}

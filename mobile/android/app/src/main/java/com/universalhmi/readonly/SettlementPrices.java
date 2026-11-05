package com.universalhmi.readonly;

import java.io.*;
import java.util.*;

/** Per-server, per-account local preferences; never sent to the remote server. */
final class SettlementPrices {
    private final SupplierCookies.Persistence storage;
    private final Properties values=new Properties();
    SettlementPrices(SupplierCookies.Persistence storage) throws Exception {
        this.storage=storage;
        String raw=storage.load();
        if(raw!=null && !raw.isEmpty()) {
            if(raw.length()>262144) throw new IOException("price storage too large");
            values.load(new StringReader(raw));
        }
    }
    synchronized String request(String body) throws Exception {
        Map<String,String> form=LoginCredentials.form(body);
        String user=form.getOrDefault("username",""), action=form.getOrDefault("action","");
        if(user.length()>128 || user.contains("\n") || user.contains("\r")) throw new IllegalArgumentException("invalid account");
        if(action.equals("load")) return values.getProperty(user,"");
        if(!action.equals("save")) throw new IllegalArgumentException("invalid action");
        String price=form.getOrDefault("price","");
        if(!price.isEmpty() && !price.matches("^(0|[1-9][0-9]{0,7})(\\.[0-9]{1,6})?$")) throw new IllegalArgumentException("invalid price");
        Properties next=new Properties(); next.putAll(values);
        if(price.isEmpty()) next.remove(user); else next.setProperty(user,price);
        if(next.size()>4096) throw new IllegalArgumentException("too many accounts");
        StringWriter out=new StringWriter(); next.store(out,null); storage.save(out.toString());
        values.clear(); values.putAll(next);
        return price;
    }
}

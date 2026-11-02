package com.universalhmi.readonly;

import java.net.HttpCookie;
import java.util.function.LongSupplier;

/** Native-only session. Persistence never extends the server's cookie lifetime. */
final class IdentitySession {
    private final SupplierCookies.Persistence storage;
    private final LongSupplier clock;
    private String value="";
    private long expires;
    IdentitySession(SupplierCookies.Persistence storage) throws Exception { this(storage,System::currentTimeMillis); }
    IdentitySession(SupplierCookies.Persistence storage,LongSupplier clock) throws Exception {
        this.storage=storage; this.clock=clock;
        String saved=storage==null ? null : storage.load();
        if(saved!=null && !saved.isEmpty()) {
            try {
                String[] parts=saved.split("\n",2);
                expires=Long.parseLong(parts[0]); value=parts[1];
                if(!valid(value) || expires<=clock.getAsLong()) clear();
            } catch(RuntimeException e) { clear(); }
        }
    }
    private static boolean valid(String value) { return value.matches("[A-Za-z0-9_-]{1,4096}"); }
    synchronized void accept(HttpCookie cookie) throws Exception {
        if(!"__Host-hmi_identity".equals(cookie.getName()) || !cookie.getSecure() || !cookie.isHttpOnly() ||
            cookie.getDomain()!=null || !"/".equals(cookie.getPath())) return;
        if(cookie.hasExpired() || cookie.getValue().isEmpty()) { clear(); return; }
        if(!valid(cookie.getValue())) return;
        long seconds=cookie.getMaxAge();
        // Session-only cookies remain memory-only; no invented persistent expiry.
        long next=seconds<0 ? Long.MAX_VALUE : Math.addExact(clock.getAsLong(),Math.multiplyExact(seconds,1000));
        if(storage!=null) storage.save(seconds<0 ? "" : next+"\n"+cookie.getValue());
        value=cookie.getValue(); expires=next;
    }
    synchronized String header() throws Exception {
        if(!value.isEmpty() && expires<=clock.getAsLong()) clear();
        return value.isEmpty() ? "" : "__Host-hmi_identity="+value;
    }
    synchronized void clear() throws Exception {
        value=""; expires=0;
        if(storage!=null) storage.save("");
    }
}

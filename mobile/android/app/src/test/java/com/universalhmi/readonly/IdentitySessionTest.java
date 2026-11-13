package com.universalhmi.readonly;

import org.junit.Test;
import static org.junit.Assert.*;
import java.net.HttpCookie;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicLong;

public class IdentitySessionTest {
    static final class Memory implements SupplierCookies.Persistence {
        String saved;
        boolean fail;
        public String load() { return saved; }
        public void save(String value) throws Exception { if(fail) throw new IOException(); saved=value; }
    }
    static HttpCookie cookie(String extra) {
        return HttpCookie.parse("__Host-hmi_identity=opaque-token; Path=/; Secure; HttpOnly"+extra).get(0);
    }
    @Test public void restartRetainsOnlyUnexpiredServerSessionAndLogoutClearsIt() throws Exception {
        Memory storage=new Memory(); AtomicLong time=new AtomicLong(100000);
        IdentitySession first=new IdentitySession(storage,time::get);
        first.accept(cookie("; Max-Age=60"));
        time.addAndGet(59000);
        IdentitySession reopened=new IdentitySession(storage,time::get);
        assertEquals("__Host-hmi_identity=opaque-token",reopened.header());
        time.addAndGet(1001);
        assertEquals("",reopened.header()); assertEquals("",storage.saved);
        reopened.accept(cookie("; Max-Age=60")); reopened.accept(cookie("; Max-Age=0"));
        assertEquals("",new IdentitySession(storage,time::get).header());
    }
    @Test public void insecureForeignAndSessionOnlyCookiesAreNotRestored() throws Exception {
        Memory storage=new Memory(); IdentitySession session=new IdentitySession(storage);
        for(String raw:new String[]{
            "__Host-hmi_identity=bad; Path=/; HttpOnly; Max-Age=60",
            "__Host-hmi_identity=bad; Path=/; Secure; Max-Age=60",
            "__Host-hmi_identity=bad; Domain=example.com; Path=/; Secure; HttpOnly; Max-Age=60",
            "__Host-hmi_identity=bad; Path=/other; Secure; HttpOnly; Max-Age=60",
            "hmi_ext_boer_session=bad; Path=/; Secure; HttpOnly; Max-Age=60"}) {
            session.accept(HttpCookie.parse(raw).get(0)); assertEquals("",session.header());
        }
        session.accept(cookie("")); assertFalse(session.header().isEmpty());
        assertEquals("",new IdentitySession(storage).header());
        storage.saved="9999999999999\nbad\r\ninjected-header";
        assertEquals("",new IdentitySession(storage).header());
    }
    @Test public void storageFailureCannotReportSuccessfulRememberedLogin() throws Exception {
        Memory storage=new Memory(); IdentitySession session=new IdentitySession(storage);
        storage.fail=true;
        assertThrows(IOException.class,() -> session.accept(cookie("; Max-Age=60")));
        assertEquals("",session.header());
    }
}

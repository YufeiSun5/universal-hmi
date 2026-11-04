package com.universalhmi.readonly;

import org.junit.Test;
import static org.junit.Assert.*;
import java.util.*;

public class SupplierCookiesTest {
    @Test public void sessionsRestoreWithoutHmiCookieOrOtherSupplier() throws Exception {
        final String[] saved={null};
        SupplierCookies.Persistence storage=new SupplierCookies.Persistence() {
            public String load() { return saved[0]; }
            public void save(String value) { saved[0]=value; }
        };
        SupplierCookies first=new SupplierCookies(storage);
        first.accept("qiwei",Arrays.asList("hmi_ext_qiwei_sid=one; Path=/external-sites/qiwei/; Secure; HttpOnly; Max-Age=3600", "__Host-hmi_identity=secret; Path=/; Secure; HttpOnly", "hmi_ext_boer_sid=other; Secure"));
        assertEquals("hmi_ext_qiwei_sid=one",first.header("qiwei"));
        assertEquals("",first.header("boer")); assertFalse(saved[0].contains("secret"));
        SupplierCookies restored=new SupplierCookies(storage);
        assertEquals(first.header("qiwei"),restored.header("qiwei"));
        restored.accept("qiwei",Collections.singletonList("hmi_ext_qiwei_sid=; Secure; Max-Age=0"));
        assertEquals("",new SupplierCookies(storage).header("qiwei"));
    }
    @Test public void supplierCapabilityNeverAdmitsBusinessWrites() {
        String path="/external-sites/qiwei/"+String.join("",Collections.nCopies(43,"x"))+"/login";
        assertTrue(ReadonlyProxy.readonly("POST",path));
        assertTrue(ReadonlyProxy.readonly("GET",path+"?a=b"));
        assertFalse(ReadonlyProxy.readonly("POST","/api/v1/points"));
        assertFalse(ReadonlyProxy.readonly("POST",path+"/../../api/v1/points"));
        assertFalse(ReadonlyProxy.readonly("POST",path+"/%2e%2e/x"));
        assertNull(ReadonlyProxy.externalSite("/external-sites/qiwei/guess/login"));
    }
}

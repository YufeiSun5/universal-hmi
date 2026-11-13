package com.universalhmi.readonly;

import static org.junit.Assert.*;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.junit.Test;

public class LoginCredentialsTest {
    static String save(String name,String password) {
        return "action=save&username="+URLEncoder.encode(name,StandardCharsets.UTF_8)+"&password="+URLEncoder.encode(password,StandardCharsets.UTF_8);
    }
    @Test public void explicitSaveSwitchReopenForgetAndClear() throws Exception {
        IdentitySessionTest.Memory storage=new IdentitySessionTest.Memory();
        LoginCredentials credentials=new LoginCredentials(storage);
        assertEquals("",LoginCredentials.form(credentials.read()).get("password"));
        credentials.update(save("甲账号","synthetic & + 密码"));
        credentials.update(save("second","synthetic-second"));
        credentials=new LoginCredentials(storage);
        Map<String,String> result=LoginCredentials.form(credentials.read());
        assertEquals("甲账号\nsecond",result.get("accounts"));
        assertEquals("second",result.get("username"));
        result=LoginCredentials.form(credentials.update("action=select&username="+URLEncoder.encode("甲账号",StandardCharsets.UTF_8)));
        assertEquals("synthetic & + 密码",result.get("password"));
        credentials.update("action=remove&username="+URLEncoder.encode("甲账号",StandardCharsets.UTF_8));
        assertEquals("",LoginCredentials.form(credentials.read()).get("password"));
        assertEquals("second",LoginCredentials.form(new LoginCredentials(storage).read()).get("accounts"));
        credentials.update("action=clear");
        assertEquals("",storage.load());
        assertEquals("",LoginCredentials.form(new LoginCredentials(storage).read()).get("accounts"));
    }
    @Test public void failedPersistenceDoesNotPretendToSaveOrClear() throws Exception {
        final String[] value={""}; final boolean[] fail={false};
        SupplierCookies.Persistence storage=new SupplierCookies.Persistence() {
            public String load() { return value[0]; }
            public void save(String next) throws Exception { if(fail[0]) throw new java.io.IOException(); value[0]=next; }
        };
        LoginCredentials credentials=new LoginCredentials(storage);
        credentials.update(save("first","synthetic-first")); fail[0]=true;
        for(String body:new String[]{save("second","synthetic-second"),"action=clear"}) {
            try { credentials.update(body); fail("persistence error hidden"); } catch(java.io.IOException expected) { }
            assertEquals("first",LoginCredentials.form(credentials.read()).get("username"));
        }
        try { credentials.update("action=save&username=x&password=one&password=two"); fail("duplicate form accepted"); }
        catch(IllegalArgumentException expected) { }
    }
}

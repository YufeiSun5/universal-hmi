package com.universalhmi.readonly;

import org.junit.Test;
import static org.junit.Assert.*;

public class OverviewPreferencesTest {
    @Test public void survivesRestartAndSeparatesAccountsWithoutServerState() throws Exception {
        IdentitySessionTest.Memory disk=new IdentitySessionTest.Memory();
        OverviewPreferences first=new OverviewPreferences(disk);
        assertEquals("",first.request("action=load&username=alice"));
        first.request("action=save&username=alice&row=row-b&group=primary&table=true");
        OverviewPreferences restarted=new OverviewPreferences(disk);
        assertTrue(restarted.request("action=load&username=alice").contains("row=row-b"));
        assertEquals("",restarted.request("action=load&username=bob"));
        restarted.request("action=save&username=bob&row=row-a&table=false");
        assertTrue(new OverviewPreferences(disk).request("action=load&username=alice").contains("table=true"));
        for(String invalid:new String[]{"action=save&username=a&table=invalid","action=save&username=a&row="+"x".repeat(129),"action=save&username=a&host=other","action=delete&username=a"}) {
            try{restarted.request(invalid);fail("invalid preference accepted");}catch(IllegalArgumentException expected){}
        }
        assertTrue(restarted.request("action=load&username=alice").contains("row=row-b"));
    }
}

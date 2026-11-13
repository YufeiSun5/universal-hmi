package com.universalhmi.readonly;

import static org.junit.Assert.*;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.security.cert.X509Certificate;
import org.junit.Test;

public class SecurityContractTest {
    @Test public void materialsOnlyOpensNamedBusinessRoutes() {
        for(String path:new String[]{"categories","items","applications","inbound","outbound","return","transfer","assets","outbound-preview"})
            assertTrue(path,ReadonlyProxy.readonly("POST","/api/v1/materials/"+path));
        for(String path:new String[]{"capabilities","stock","movements","documents/d1","documents/d1/export","assets/a1","applications/a1"})
            assertTrue(path,ReadonlyProxy.readonly("GET","/api/v1/materials/"+path));
        assertTrue(ReadonlyProxy.readonly("POST","/api/v1/materials/applications/a1/decision"));
        assertTrue(ReadonlyProxy.readonly("POST","/api/v1/account/signature"));
        for(String path:new String[]{"/api/v1/materials/stock","/api/v1/materials/documents/d1","/api/v1/materials/assets/a1","/api/v1/materials/outbound/extra","/api/v1/materials/../write","/api/v1/materials/applications/a%2fb/decision","/api/v1/account/other/signature","/api/v1/write"})
            assertFalse(path,ReadonlyProxy.readonly("POST",path));
        for(String method:new String[]{"PUT","DELETE","PATCH"})
            assertFalse(method,ReadonlyProxy.readonly(method,"/api/v1/materials/items"));
        assertEquals(14*1024*1024,ReadonlyProxy.bodyLimit("POST","/api/v1/materials/assets"));
        assertEquals(65536,ReadonlyProxy.bodyLimit("POST","/api/v1/points"));
    }
    @Test public void grpcWebOnlyAddsOneReadSubscription() {
        String route="/api/v1/hmi.runtime.v1.RuntimeService/Subscribe";
        assertTrue(ReadonlyProxy.readonly("POST",route));
        for(String method:new String[]{"GET","PUT","DELETE"})assertFalse(ReadonlyProxy.readonly(method,route));
        assertFalse(ReadonlyProxy.readonly("POST",route+"/extra"));
        assertFalse(ReadonlyProxy.readonly("POST",route.replace("Subscribe","Write")));
        assertEquals(1024*1024,ReadonlyProxy.bodyLimit("POST",route));
        assertFalse(ReadonlyProxy.readonly("POST","/mobile/overview-preferences"));
    }
    @Test public void publicLeafUsesSameP256KeyAndExplicitClientUsage() throws Exception {
        KeyPairGenerator generator=KeyPairGenerator.getInstance("EC"); generator.initialize(new ECGenParameterSpec("secp256r1")); KeyPair pair=generator.generateKeyPair();
        byte[] raw=Certificates.leaf(pair,System.currentTimeMillis()); X509Certificate leaf=Certificates.parse(raw);
        leaf.verify(pair.getPublic()); leaf.checkValidity();
        assertArrayEquals(pair.getPublic().getEncoded(),leaf.getPublicKey().getEncoded());
        assertEquals(-1,leaf.getBasicConstraints()); assertTrue(leaf.getKeyUsage()[0]); assertFalse(leaf.getKeyUsage()[5]);
        assertEquals(java.util.List.of("1.3.6.1.5.5.7.3.2"),leaf.getExtendedKeyUsage());
        assertTrue(Certificates.csr(pair).length>100);
        assertArrayEquals(raw,Certificates.parse(Certificates.pem("CERTIFICATE",raw).getBytes(java.nio.charset.StandardCharsets.UTF_8)).getEncoded());
        long remaining=leaf.getNotAfter().getTime()-System.currentTimeMillis();
        assertTrue(remaining>3649L*24*60*60*1000);
        assertTrue(remaining<=3650L*24*60*60*1000);
        X509Certificate longLeaf=Certificates.parse(Certificates.leaf(pair,System.currentTimeMillis(),36500));
        longLeaf.verify(pair.getPublic());
        assertTrue(longLeaf.getNotAfter().getTime()>System.currentTimeMillis()+36499L*24*60*60*1000);
        X509Certificate renewed=Certificates.parse(Certificates.leaf(pair,System.currentTimeMillis(),1));
        assertArrayEquals(leaf.getPublicKey().getEncoded(),renewed.getPublicKey().getEncoded());
        assertFalse(java.util.Arrays.equals(leaf.getEncoded(),renewed.getEncoded()));
        for (int days:new int[]{0,-1,36501,Integer.MAX_VALUE}) {
            try { Certificates.leaf(pair,System.currentTimeMillis(),days); fail("invalid days"); } catch(IllegalArgumentException expected) { }
        }
    }
    @Test public void readonlyBoundaryRejectsControlAndEncodedBypasses() {
        for (String path:new String[]{"/api/v1/write","/api/v1/apply","/api/v1/security/public-bans","/mcp","/api/v1/screens/a%2fb","//host/path","/api/v1/../write","/api/v1/screens/%2e%2e"}) assertFalse(path,ReadonlyProxy.readonly("POST",path));
        assertTrue(ReadonlyProxy.readonly("GET","/api/v1/points")); assertFalse(ReadonlyProxy.readonly("PUT","/api/v1/points"));
        assertTrue(ReadonlyProxy.readonly("GET","/api/v1/live-overview"));
        for (String method:new String[]{"PUT","POST","DELETE","PATCH"}) assertFalse(ReadonlyProxy.readonly(method,"/api/v1/live-overview"));
        assertTrue(ReadonlyProxy.readonly("GET","/api/v1/external/screens/a/heat-prices")); assertFalse(ReadonlyProxy.readonly("POST","/api/v1/external/screens/a/heat-prices"));
        assertTrue(ReadonlyProxy.readonly("POST","/api/v1/external/screens/a/query")); assertFalse(ReadonlyProxy.readonly("POST","/api/v1/external/screens/a/query/extra"));
        assertTrue(ReadonlyProxy.readonly("GET","/gis-flight/map.html")); assertFalse(ReadonlyProxy.readonly("POST","/index.html"));
    }
    @Test public void configuredOriginRequiresExactHttpsLiteralIP() throws Exception {
        assertEquals("https://192.0.2.5:9090",Certificates.origin("https://192.0.2.5:9090").toString());
        for (String origin:new String[]{"http://192.0.2.5","https://example.com","https://user@192.0.2.5","https://192.0.2.5/","https://192.0.2.5?x=1","https://192.0.2.5#x","https://192.0.2.5:0"}) {
            try { Certificates.origin(origin); fail(origin); } catch(Exception expected) { }
        }
    }
    @Test public void maintenanceRoutesAreExplicitAndKeepControlClosed() {
        for(String pair:new String[]{"GET users","GET roles","GET device-owners","POST users","PUT users/u1","POST devices/u1/approve-login","POST device-certificates/c1/revoke","DELETE roles/r1"}) {
            String[] parts=pair.split(" "); assertTrue(pair,ReadonlyProxy.readonly(parts[0],"/api/v1/security/"+parts[1]));
        }
        for(String path:new String[]{"/api/v1/security/users/u1/extra","/api/v1/security/users/%75ser","/api/v1/security/kp-settings","/api/v1/security/public-bans","/api/v1/points"})
            assertFalse(path,ReadonlyProxy.readonly("PUT",path));
        assertTrue(ReadonlyProxy.readonly("POST","/api/v1/equipment/e1/photos"));
        assertTrue(ReadonlyProxy.readonly("DELETE","/api/v1/equipment/e1/photos/p1"));
        assertFalse(ReadonlyProxy.readonly("DELETE","/api/v1/equipment/e1"));
    }
}

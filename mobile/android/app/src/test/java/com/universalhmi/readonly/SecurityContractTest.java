package com.universalhmi.readonly;

import static org.junit.Assert.*;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.security.cert.X509Certificate;
import org.junit.Test;

public class SecurityContractTest {
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
        for (String path:new String[]{"/api/v1/write","/api/v1/apply","/api/v1/security/users","/api/v1/security/public-bans","/mcp","/api/v1/screens/a%2fb","//host/path","/api/v1/../write","/api/v1/screens/%2e%2e"}) assertFalse(path,ReadonlyProxy.readonly("POST",path));
        assertTrue(ReadonlyProxy.readonly("GET","/api/v1/points")); assertFalse(ReadonlyProxy.readonly("PUT","/api/v1/points"));
        assertTrue(ReadonlyProxy.readonly("POST","/api/v1/external/screens/a/query")); assertFalse(ReadonlyProxy.readonly("POST","/api/v1/external/screens/a/query/extra"));
        assertTrue(ReadonlyProxy.readonly("GET","/gis-flight/map.html")); assertFalse(ReadonlyProxy.readonly("POST","/index.html"));
    }
    @Test public void configuredOriginRequiresExactHttpsLiteralIP() throws Exception {
        assertEquals("https://192.0.2.5:9090",Certificates.origin("https://192.0.2.5:9090").toString());
        for (String origin:new String[]{"http://192.0.2.5","https://example.com","https://user@192.0.2.5","https://192.0.2.5/","https://192.0.2.5?x=1","https://192.0.2.5#x","https://192.0.2.5:0"}) {
            try { Certificates.origin(origin); fail(origin); } catch(Exception expected) { }
        }
    }
}

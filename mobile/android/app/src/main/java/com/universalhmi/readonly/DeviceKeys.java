package com.universalhmi.readonly;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import javax.net.ssl.X509ExtendedKeyManager;
import javax.net.ssl.SSLEngine;
import java.net.Socket;
import java.security.Principal;

final class DeviceKeys extends X509ExtendedKeyManager {
    // v1 was used only by the unreleased USB prototype and did not allow TLS prehash signing.
    // Keep that entry intact; the first released transport uses this separate identity.
    private static final String ALIAS="universal-hmi-installation-tls-v2";
    private final KeyPair keys;
    private final X509Certificate certificate;
    final byte[] csr;
    DeviceKeys(Context context) throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        boolean created=!store.containsAlias(ALIAS);
        if (created) {
            KeyPairGenerator generator=KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_NONE,KeyProperties.DIGEST_SHA256).build());
            generator.generateKeyPair();
        }
        keys=new KeyPair(store.getCertificate(ALIAS).getPublicKey(),(PrivateKey)store.getKey(ALIAS,null));
        if (keys.getPrivate().getEncoded()!=null) throw new IllegalStateException("exportable device key");
        android.content.SharedPreferences preferences=context.getSharedPreferences("device",Context.MODE_PRIVATE);
        String encoded=created ? null : preferences.getString("leaf",null);
        if (encoded==null) {
            encoded=Base64.getEncoder().encodeToString(Certificates.leaf(keys,System.currentTimeMillis()));
            if (!preferences.edit().putString("leaf",encoded).commit()) throw new IllegalStateException("device certificate persistence");
        }
        certificate=Certificates.parse(Base64.getDecoder().decode(encoded));
        if (!java.security.MessageDigest.isEqual(certificate.getPublicKey().getEncoded(),keys.getPublic().getEncoded())) throw new IllegalStateException("key/certificate mismatch");
        certificate.verify(keys.getPublic());
        csr=Certificates.csr(keys);
        // Android TLS signs its own digest using NONEwithECDSA. Check the real
        // Keystore operation before presenting a usable device identity.
        byte[] digest=java.security.MessageDigest.getInstance("SHA-256").digest(csr);
        java.security.Signature tlsSigner=java.security.Signature.getInstance("NONEwithECDSA");
        tlsSigner.initSign(keys.getPrivate()); tlsSigner.update(digest); byte[] proof=tlsSigner.sign();
        tlsSigner.initVerify(keys.getPublic()); tlsSigner.update(digest);
        if (!tlsSigner.verify(proof)) throw new IllegalStateException("TLS signing unavailable");
    }
    String publicExport() throws Exception {
        return "Universal HMI installation public material\nSPKI SHA-256: "+Certificates.fingerprint(keys.getPublic().getEncoded())+"\n\n"+
            Certificates.pem("CERTIFICATE REQUEST",csr)+"\n"+Certificates.pem("CERTIFICATE",certificate.getEncoded());
    }
    String fingerprint() throws Exception { return Certificates.fingerprint(keys.getPublic().getEncoded()); }
    String expires() { return certificate.getNotAfter().toString(); }
    DeviceKeys renew(Context context,int days) throws Exception {
        byte[] raw=Certificates.leaf(keys,System.currentTimeMillis(),days);
        Certificates.parse(raw).verify(keys.getPublic());
        if (!context.getSharedPreferences("device",Context.MODE_PRIVATE).edit().putString("leaf",Base64.getEncoder().encodeToString(raw)).commit()) throw new IllegalStateException("certificate persistence");
        return new DeviceKeys(context);
    }
    @Override public String[] getClientAliases(String type,Principal[] issuers) { return "EC".equals(type) ? new String[]{ALIAS} : null; }
    @Override public String chooseClientAlias(String[] types,Principal[] issuers,Socket socket) { for (String type:types) if ("EC".equals(type)) return ALIAS; return null; }
    @Override public String chooseEngineClientAlias(String[] types,Principal[] issuers,SSLEngine engine) { return chooseClientAlias(types,issuers,null); }
    @Override public X509Certificate[] getCertificateChain(String alias) { return ALIAS.equals(alias) ? new X509Certificate[]{certificate} : null; }
    @Override public PrivateKey getPrivateKey(String alias) { return ALIAS.equals(alias) ? keys.getPrivate() : null; }
    @Override public String[] getServerAliases(String type,Principal[] issuers) { return null; }
    @Override public String chooseServerAlias(String type,Principal[] issuers,Socket socket) { return null; }
}

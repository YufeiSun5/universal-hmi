package com.universalhmi.readonly;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.net.InetAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.text.SimpleDateFormat;
import java.util.Base64;
import java.util.Collection;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/** Public CSR/leaf encoding, not a CA or an Android hardware attestation. */
final class Certificates {
    static byte[] der(int tag, byte[]... fields) {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        for (byte[] field : fields) body.write(field, 0, field.length);
        byte[] data = body.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream(); out.write(tag);
        if (data.length < 128) out.write(data.length);
        else {
            int count = (32 - Integer.numberOfLeadingZeros(data.length) + 7) / 8;
            out.write(128 | count);
            for (int i = count - 1; i >= 0; i--) out.write((data.length >>> (i * 8)) & 255);
        }
        out.write(data, 0, data.length); return out.toByteArray();
    }
    static byte[] seq(byte[]... fields) { return der(0x30, fields); }
    static byte[] integer(BigInteger value) { return der(2, value.toByteArray()); }
    static byte[] oid(int... parts) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); bytes.write(parts[0]*40+parts[1]);
        for (int i=2; i<parts.length; i++) {
            int value=parts[i], shift=0;
            while ((value >>> (shift+7)) != 0) shift+=7;
            for (; shift>0; shift-=7) bytes.write(((value >>> shift)&127)|128);
            bytes.write(value&127);
        }
        return der(6, bytes.toByteArray());
    }
    static byte[] algorithm() { return seq(oid(1,2,840,10045,4,3,2)); }
    static byte[] name() { return seq(der(0x31, seq(oid(2,5,4,3), der(12, "HMI mobile installation".getBytes(StandardCharsets.UTF_8))))); }
    static byte[] signature(byte[] data, KeyPair keys) throws Exception {
        Signature signer=Signature.getInstance("SHA256withECDSA"); signer.initSign(keys.getPrivate()); signer.update(data);
        return der(3, new byte[]{0}, signer.sign());
    }
    static byte[] csr(KeyPair keys) throws Exception {
        byte[] info=seq(integer(BigInteger.ZERO), name(), keys.getPublic().getEncoded(), der(0xa0));
        return seq(info, algorithm(), signature(info, keys));
    }
    static byte[] time(long timestamp) {
        SimpleDateFormat format=new SimpleDateFormat("yyyyMMddHHmmss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return der(24, format.format(new Date(timestamp)).getBytes(StandardCharsets.US_ASCII));
    }
    static byte[] leaf(KeyPair keys, long now) throws Exception {
        return leaf(keys,now,30);
    }
    static byte[] leaf(KeyPair keys, long now,int days) throws Exception {
        if (days<1 || days>365) throw new IllegalArgumentException("client certificate days");
        byte[] serial=new byte[16]; new SecureRandom().nextBytes(serial); serial[0]&=127; serial[15]|=1;
        byte[] extensions=der(0xa3, seq(
            seq(oid(2,5,29,19), der(1, new byte[]{(byte)255}), der(4, seq())),
            seq(oid(2,5,29,15), der(1, new byte[]{(byte)255}), der(4, der(3, new byte[]{7,(byte)128}))),
            seq(oid(2,5,29,37), der(4, seq(oid(1,3,6,1,5,5,7,3,2))))));
        byte[] info=seq(der(0xa0, integer(BigInteger.valueOf(2))), integer(new BigInteger(1,serial)), algorithm(), name(),
            seq(time(now-300_000), time(now+days*24L*60*60*1000)), name(), keys.getPublic().getEncoded(), extensions);
        return seq(info, algorithm(), signature(info,keys));
    }
    static X509Certificate parse(byte[] bytes) throws Exception {
        if (bytes.length == 0 || bytes.length > 16384) throw new IllegalArgumentException("certificate size");
        Collection<? extends java.security.cert.Certificate> items=CertificateFactory.getInstance("X.509").generateCertificates(new ByteArrayInputStream(bytes));
        if (items.size()!=1) throw new IllegalArgumentException("one certificate required");
        return (X509Certificate)items.iterator().next();
    }
    static String pem(String type, byte[] bytes) {
        return "-----BEGIN "+type+"-----\n"+Base64.getMimeEncoder(64,new byte[]{10}).encodeToString(bytes)+"\n-----END "+type+"-----\n";
    }
    static String fingerprint(byte[] bytes) throws Exception {
        StringBuilder out=new StringBuilder();
        for (byte b:MessageDigest.getInstance("SHA-256").digest(bytes)) out.append(String.format(Locale.US,"%02x",b&255));
        return out.toString();
    }
    static URI origin(String input) throws Exception {
        URI origin=new URI(input.trim()); String host=origin.getHost();
        if (!"https".equals(origin.getScheme()) || host==null || origin.getRawUserInfo()!=null ||
            (origin.getRawPath()!=null && !origin.getRawPath().isEmpty()) || origin.getRawQuery()!=null || origin.getRawFragment()!=null ||
            origin.getPort()==0 || origin.getPort()>65535 || origin.getPort() < -1) throw new IllegalArgumentException("HTTPS IP origin required");
        String literal=host.replace("[","").replace("]","");
        if (literal.contains("%") || !(literal.matches("[0-9.]+") || literal.matches("[0-9a-fA-F:]+") && literal.contains(":"))) throw new IllegalArgumentException("literal IP required");
        InetAddress.getByName(literal);
        return origin;
    }
    static void verifyServer(X509Certificate certificate, URI origin) throws Exception {
        certificate.checkValidity();
        List<String> usage=certificate.getExtendedKeyUsage();
        if (certificate.getBasicConstraints()>=0 || usage==null || !usage.contains("1.3.6.1.5.5.7.3.1")) throw new IllegalArgumentException("server leaf usage");
        byte[] address=InetAddress.getByName(origin.getHost()).getAddress();
        Collection<List<?>> sans=certificate.getSubjectAlternativeNames();
        if (sans!=null) for (List<?> san:sans) if (Integer.valueOf(7).equals(san.get(0)) && MessageDigest.isEqual(address,InetAddress.getByName((String)san.get(1)).getAddress())) return;
        throw new IllegalArgumentException("server IP SAN mismatch");
    }
}

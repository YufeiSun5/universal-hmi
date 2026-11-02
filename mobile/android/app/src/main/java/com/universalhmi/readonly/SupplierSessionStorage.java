package com.universalhmi.readonly;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Base64;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Private app storage encrypted with a non-exportable Android Keystore key. */
final class SupplierSessionStorage implements SupplierCookies.Persistence {
    private final SharedPreferences settings;
    private final String server;
    private final javax.crypto.SecretKey key;
    SupplierSessionStorage(Context context,String server) throws Exception {
        this.server=server; settings=context.getSharedPreferences("supplier_sessions",Context.MODE_PRIVATE);
        String alias="hmi-supplier-sessions-v1";
        KeyStore store=KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if(!store.containsAlias(alias)) {
            KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        key=(javax.crypto.SecretKey)store.getKey(alias,null);
    }
    public String load() throws Exception {
        String raw=settings.getString(server,null); if(raw==null) return null;
        try {
            String[] parts=raw.split(":",2);
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,key,new GCMParameterSpec(128,Base64.getDecoder().decode(parts[0])));
            cipher.updateAAD(server.getBytes(StandardCharsets.UTF_8));
            return new String(cipher.doFinal(Base64.getDecoder().decode(parts[1])),StandardCharsets.UTF_8);
        } catch(Exception e) {
            // A restored backup cannot reuse another installation's Keystore session key.
            if(!settings.edit().remove(server).commit()) throw new java.io.IOException("session recovery failed");
            return null;
        }
    }
    public void save(String value) throws Exception {
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key);
        cipher.updateAAD(server.getBytes(StandardCharsets.UTF_8));
        String encoded=Base64.getEncoder().encodeToString(cipher.getIV())+":"+Base64.getEncoder().encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)));
        if(!settings.edit().putString(server,encoded).commit()) throw new java.io.IOException("session save failed");
    }
}

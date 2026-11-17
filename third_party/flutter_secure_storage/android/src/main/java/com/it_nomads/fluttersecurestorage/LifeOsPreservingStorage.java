package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import com.it_nomads.fluttersecurestorage.crypto.EncryptedSharedPreferences;
import io.flutter.plugin.common.MethodCall;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.spec.MGF1ParameterSpec;
import java.util.HashMap;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import javax.crypto.spec.SecretKeySpec;

/**
 * Life OS compatibility boundary, deliberately independent of per-call migration
 * and reset flags. Existing data selects its persisted format. Reads cannot
 * create keys, migrate formats, remove entries, or fall back to ciphertext.
 * All engines in this process share the same admission lock. Cross-process
 * writers and biometric key formats require a separate gate and fail closed.
 */
final class LifeOsPreservingStorage {
    private static final Object LOCK = new Object();
    private static final String KEYSET = "__androidx_security_crypto_encrypted_prefs_key_keyset__";
    private static final String VALUESET = "__androidx_security_crypto_encrypted_prefs_value_keyset__";
    private static final String WRAPPED_CBC = "VGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK";
    private static final String WRAPPED_GCM = "AES" + WRAPPED_CBC;
    private static final String RSA_OLD = "RSA_ECB_PKCS1Padding";
    private static final String RSA_NEW = "RSA_ECB_OAEPwithSHA_256andMGF1Padding";
    private static final String CBC = "AES_CBC_PKCS7Padding";
    private static final String GCM = "AES_GCM_NoPadding";

    static boolean handles(String method) {
        return method.equals("read") || method.equals("readAll") || method.equals("containsKey")
                || method.equals("write") || method.equals("delete") || method.equals("deleteAll");
    }

    @SuppressWarnings("unchecked")
    static Object execute(Context context, MethodCall call) throws Exception {
        synchronized (LOCK) {
            if (!(call.arguments instanceof Map)) throw blocked();
            Map<String, Object> args = (Map<String, Object>) call.arguments;
            Map<String, Object> options = args.get("options") instanceof Map
                    ? (Map<String, Object>) args.get("options") : new HashMap<>();
            FlutterSecureStorageConfig config = new FlutterSecureStorageConfig(options);
            // Never silently downgrade a caller asking for biometric/AES
            // wrapping. This boundary only qualifies the app's RSA stores.
            if (config.getEnforceBiometrics()
                    || !(RSA_OLD.equals(config.getPrefOptionKeyCipherAlgorithm())
                    || RSA_NEW.equals(config.getPrefOptionKeyCipherAlgorithm()))
                    || !(CBC.equals(config.getPrefOptionStorageCipherAlgorithm())
                    || GCM.equals(config.getPrefOptionStorageCipherAlgorithm()))) throw blocked();
            String name = config.getEffectiveDataPrefsName();
            if (!name.matches("[A-Za-z0-9_.:-]{1,128}")) throw blocked();
            if (call.method.equals("deleteAll")) {
                // Account cleanup must enumerate its captured logical keys.
                // A public API bulk delete must never remove another DB's key.
                throw new PreservationException("LIFEOS_SECURE_STORAGE_BULK_DELETE_DISABLED");
            }
            Store store = openExisting(context, config);
            String key = args.get("key") instanceof String ? (String) args.get("key") : null;
            if (!call.method.equals("readAll") && key == null) throw blocked();
            if (call.method.equals("write")) {
                if (!(args.get("value") instanceof String)) throw blocked();
                if (store == null) store = createFresh(context, config);
                store.write(key, (String) args.get("value"));
                return null;
            }
            if (store == null) {
                if (call.method.equals("readAll")) return new HashMap<String, String>();
                if (call.method.equals("containsKey")) return false;
                return null;
            }
            switch (call.method) {
                case "read": return store.read(key);
                case "containsKey": return store.read(key) != null;
                case "readAll": return store.readAll();
                case "delete": store.delete(key); return null;
                default: throw blocked();
            }
        }
    }

    private static Store openExisting(Context context, FlutterSecureStorageConfig config) throws Exception {
        String name = config.getEffectiveDataPrefsName();
        String prefix = config.getSharedPreferencesKeyPrefix() + "_";
        SharedPreferences data = context.getSharedPreferences(name, Context.MODE_PRIVATE);
        Map<String, ?> entries = data.getAll();
        SharedPreferences wrapped = context.getSharedPreferences(config.getEffectiveKeyStoragePrefsName(), Context.MODE_PRIVATE);
        NamespacedConfigSource saved = new NamespacedConfigSource(context, name);
        boolean custom = false, espValues = false;
        for (String key : entries.keySet()) {
            if (key.equals(KEYSET) || key.equals(VALUESET)) continue;
            if (key.startsWith(prefix)) custom = true; else espValues = true;
        }
        // Never guess how to finish a partial or mixed migration.
        if (custom && espValues) throw blocked();
        if (espValues || !custom && (entries.containsKey(KEYSET) || entries.containsKey(VALUESET))
                && !wrapped.contains(WRAPPED_CBC) && !wrapped.contains(WRAPPED_GCM)) {
            if (!entries.containsKey(KEYSET) || !entries.containsKey(VALUESET)) throw blocked();
            return new Store(EncryptedSharedPreferences.openExisting(context, name), prefix, null, null);
        }
        boolean wrappedCbc = wrapped.contains(WRAPPED_CBC);
        boolean wrappedGcm = wrapped.contains(WRAPPED_GCM);
        if (!custom && !wrappedCbc && !wrappedGcm && entries.isEmpty()) {
            // Orphan cryptographic metadata must not be silently replaced.
            if (!saved.getAll().isEmpty() || hasLegacyMarkers(context)
                    || hasAlias(context, config, false) || hasAlias(context, config, true)
                    || !wrapped.getAll().isEmpty()) throw blocked();
            return null;
        }
        if (!wrappedCbc && !wrappedGcm) throw blocked();
        String storageAlgorithm = saved.getString("FlutterSecureSAlgorithmStorage", null);
        String keyAlgorithm = saved.getString("FlutterSecureSAlgorithmKey", null);
        if (storageAlgorithm == null && keyAlgorithm == null) {
            // The historical no-marker custom format is RSA PKCS1 + AES CBC.
            if (!wrappedCbc || wrappedGcm) throw blocked();
            storageAlgorithm = CBC;
            keyAlgorithm = RSA_OLD;
        }
        if (!(CBC.equals(storageAlgorithm) || GCM.equals(storageAlgorithm))
                || !(RSA_OLD.equals(keyAlgorithm) || RSA_NEW.equals(keyAlgorithm))) throw blocked();
        String material = wrapped.getString(GCM.equals(storageAlgorithm) ? WRAPPED_GCM : WRAPPED_CBC, null);
        if (material == null) throw blocked();
        String alias = alias(context, config, RSA_NEW.equals(keyAlgorithm));
        KeyStore ks = keyStore();
        Key privateKey = ks.getKey(alias, null);
        if (!(privateKey instanceof PrivateKey) || ks.getCertificate(alias) == null) throw blocked();
        Cipher rsa = rsaCipher(RSA_NEW.equals(keyAlgorithm));
        if (RSA_NEW.equals(keyAlgorithm)) rsa.init(Cipher.UNWRAP_MODE, privateKey, oaep());
        else rsa.init(Cipher.UNWRAP_MODE, privateKey);
        Key aes = rsa.unwrap(Base64.decode(material, Base64.DEFAULT), "AES", Cipher.SECRET_KEY);
        if (!(aes instanceof SecretKey)) throw blocked();
        return new Store(data, prefix, (SecretKey) aes, storageAlgorithm);
    }

    private static Store createFresh(Context context, FlutterSecureStorageConfig config) throws Exception {
        // Only an explicit write can provision cryptographic material. Recheck
        // under the same lock; a read can never take this path.
        if (openExisting(context, config) != null) throw blocked();
        String alias = alias(context, config, true);
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA", "AndroidKeyStore");
        generator.initialize(new KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP).build());
        generator.generateKeyPair();
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        SecretKey aes = new SecretKeySpec(bytes, "AES");
        Cipher rsa = rsaCipher(true);
        rsa.init(Cipher.WRAP_MODE, keyStore().getCertificate(alias).getPublicKey(), oaep());
        String wrappedValue = Base64.encodeToString(rsa.wrap(aes), Base64.DEFAULT);
        SharedPreferences wrapped = context.getSharedPreferences(config.getEffectiveKeyStoragePrefsName(), Context.MODE_PRIVATE);
        if (!wrapped.edit().putString(WRAPPED_GCM, wrappedValue).commit()) throw blocked();
        if (!new NamespacedConfigSource(context, config.getEffectiveDataPrefsName()).edit()
                .putString("FlutterSecureSAlgorithmKey", RSA_NEW)
                .putString("FlutterSecureSAlgorithmStorage", GCM).commit()) throw blocked();
        // No cleanup on a failed provisioning attempt. Orphans block retries
        // for explicit recovery; a second key is never generated over them.
        return new Store(context.getSharedPreferences(config.getEffectiveDataPrefsName(), Context.MODE_PRIVATE),
                config.getSharedPreferencesKeyPrefix() + "_", aes, GCM);
    }

    private static boolean hasLegacyMarkers(Context context) {
        SharedPreferences p = context.getSharedPreferences("FlutterSecureStorageConfiguration", Context.MODE_PRIVATE);
        return p.contains("FlutterSecureSAlgorithmKey") || p.contains("FlutterSecureSAlgorithmStorage");
    }
    private static KeyStore keyStore() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore"); ks.load(null); return ks;
    }
    private static String alias(Context c, FlutterSecureStorageConfig config, boolean modern) {
        return c.getPackageName() + ".FlutterSecureStoragePluginKey" + (modern ? "OAEP" : "") + config.getKeyAliasSuffix();
    }
    private static boolean hasAlias(Context c, FlutterSecureStorageConfig cfg, boolean modern) throws Exception {
        return keyStore().containsAlias(alias(c, cfg, modern));
    }
    private static Cipher rsaCipher(boolean modern) throws Exception {
        return Cipher.getInstance(modern ? "RSA/ECB/OAEPPadding" : "RSA/ECB/PKCS1Padding", "AndroidKeyStoreBCWorkaround");
    }
    private static OAEPParameterSpec oaep() {
        return new OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT);
    }
    private static PreservationException blocked() {
        return new PreservationException("LIFEOS_SECURE_STORAGE_PRESERVATION_REQUIRED");
    }
    static final class PreservationException extends Exception {
        PreservationException(String code) { super(code); }
    }

    private static final class Store {
        final SharedPreferences data;
        final String prefix;
        final SecretKey aes;
        final String algorithm;
        Store(SharedPreferences data, String prefix, SecretKey aes, String algorithm) {
            this.data=data; this.prefix=prefix; this.aes=aes; this.algorithm=algorithm;
        }
        String read(String key) throws Exception {
            String raw = data.getString(prefix + key, null);
            if (raw == null) return null;
            if (aes == null) return raw; // Already decrypted by the ESP adapter.
            byte[] encrypted = Base64.decode(raw, Base64.DEFAULT);
            int ivSize = GCM.equals(algorithm) ? 12 : 16;
            if (encrypted.length <= ivSize) throw blocked();
            Cipher cipher = dataCipher();
            if (GCM.equals(algorithm)) cipher.init(Cipher.DECRYPT_MODE, aes, new GCMParameterSpec(128, encrypted, 0, ivSize));
            else cipher.init(Cipher.DECRYPT_MODE, aes, new IvParameterSpec(encrypted, 0, ivSize));
            return new String(cipher.doFinal(encrypted, ivSize, encrypted.length - ivSize), StandardCharsets.UTF_8);
        }
        Map<String,String> readAll() throws Exception {
            Map<String,String> result = new HashMap<>();
            for (String key : data.getAll().keySet()) {
                if (key.startsWith(prefix)) result.put(key.substring(prefix.length()), read(key.substring(prefix.length())));
            }
            return result; // Nothing returned if any entry failed to decrypt.
        }
        void write(String key, String value) throws Exception {
            String encoded = value;
            if (aes != null) {
                byte[] iv = new byte[GCM.equals(algorithm) ? 12 : 16]; new SecureRandom().nextBytes(iv);
                Cipher cipher = dataCipher();
                if (GCM.equals(algorithm)) cipher.init(Cipher.ENCRYPT_MODE, aes, new GCMParameterSpec(128, iv));
                else cipher.init(Cipher.ENCRYPT_MODE, aes, new IvParameterSpec(iv));
                byte[] payload = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
                byte[] combined = new byte[iv.length + payload.length];
                System.arraycopy(iv, 0, combined, 0, iv.length);
                System.arraycopy(payload, 0, combined, iv.length, payload.length);
                encoded = Base64.encodeToString(combined, Base64.DEFAULT);
            }
            if (!data.edit().putString(prefix + key, encoded).commit()) throw blocked();
        }
        void delete(String key) throws Exception {
            if (!data.edit().remove(prefix + key).commit()) throw blocked();
        }
        Cipher dataCipher() throws Exception {
            return Cipher.getInstance(GCM.equals(algorithm) ? "AES/GCM/NoPadding" : "AES/CBC/PKCS7Padding");
        }
    }
}

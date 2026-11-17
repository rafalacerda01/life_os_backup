package dev.lifeos.recovery.life_os

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest

// Test package only. No external paths, credentials or remote services.
class MainActivity : FlutterActivity() {
    private var savedCustom: Pair<String, String>? = null
    private var savedWrapped: Pair<String, String>? = null
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "lifeos.gate02/control")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "scenario" -> result.success(intent.getStringExtra("gate_scenario") ?: "fresh-read")
                        "snapshot" -> {
                            val root = File(applicationInfo.dataDir)
                            val hashes = sortedMapOf<String, String>()
                            for (name in listOf("shared_prefs", "app_flutter", "files/datastore")) {
                                val dir = File(root, name)
                                if (dir.exists()) dir.walkTopDown().filter { it.isFile }.forEach {
                                    hashes[it.relativeTo(root).path.replace('\\', '/')] = digest(it.readBytes())
                                }
                            }
                            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                            val aliases = sortedMapOf<String, String>()
                            ks.aliases().toList().forEach {
                                aliases[it] = "${ks.getCreationDate(it)?.time}:${ks.getCertificate(it)?.encoded?.let(::digest)}"
                            }
                            result.success(mapOf("files" to hashes, "aliases" to aliases))
                        }
                        "seedLegacyCustom" -> {
                            val config = FlutterSecureStorageConfig(mapOf(
                                "encryptedSharedPreferences" to "false", "resetOnError" to "false",
                                "migrateOnAlgorithmChange" to "false",
                                "keyCipherAlgorithm" to "RSA_ECB_PKCS1Padding",
                                "storageCipherAlgorithm" to "AES_CBC_PKCS7Padding"))
                            val store = FlutterSecureStorage(applicationContext)
                            val values = call.arguments as Map<*, *>
                            store.initialize(config, object : SecurePreferencesCallback<Void> {
                                override fun onSuccess(unused: Void?) {
                                    try {
                                        values.forEach { (key, value) -> store.write(store.addPrefixToKey(key as String), value as String) }
                                        result.success(true)
                                    } catch (error: Exception) { result.error("FIXTURE", error.toString(), null) }
                                }
                                override fun onError(error: Exception) { result.error("FIXTURE", error.toString(), null) }
                            })
                        }
                        "removeAlgorithmMarkers" -> {
                            check(getSharedPreferences("FlutterSecureStorageConfiguration:FlutterSecureStorage", MODE_PRIVATE).edit().clear().commit())
                            result.success(true)
                        }
                        "removeWrapped" -> {
                            val prefs = getSharedPreferences("FlutterSecureKeyStorage", MODE_PRIVATE)
                            val key = prefs.all.keys.first { it.startsWith("AES") }
                            savedWrapped = key to prefs.getString(key, null)!!
                            check(prefs.edit().remove(key).commit())
                            result.success(true)
                        }
                        "restoreWrapped" -> {
                            val saved = savedWrapped!!
                            check(getSharedPreferences("FlutterSecureKeyStorage", MODE_PRIVATE).edit().putString(saved.first, saved.second).commit())
                            result.success(true)
                        }
                        "removeMaster" -> {
                            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("_androidx_security_master_key_") }
                            result.success(true)
                        }
                        "seedEsp" -> {
                            val config = FlutterSecureStorageConfig(mapOf("encryptedSharedPreferences" to "true", "migrateOnAlgorithmChange" to "false", "resetOnError" to "false"))
                            val store = FlutterSecureStorage(applicationContext)
                            val field = store.javaClass.getDeclaredField("config").apply { isAccessible = true }
                            field.set(store, config)
                            val method = store.javaClass.getDeclaredMethod("initializeEncryptedSharedPreferencesManager", android.content.Context::class.java).apply { isAccessible = true }
                            val prefs = method.invoke(store, applicationContext) as android.content.SharedPreferences
                            val values = call.arguments as Map<*, *>
                            val editor = prefs.edit()
                            values.forEach { (key, value) -> editor.putString(config.sharedPreferencesKeyPrefix + "_" + key, value as String) }
                            check(editor.commit())
                            result.success(true)
                        }
                        "effective" -> {
                            val info = mapOf("boundary" to "lifeos-preserving-v1")
                            result.success(info)
                        }
                        "corruptCustom" -> {
                            val prefs = getSharedPreferences("FlutterSecureStorage", MODE_PRIVATE)
                            val key = prefs.all.keys.first { it.endsWith("_db_encryption_key") }
                            savedCustom = key to prefs.getString(key, null)!!
                            check(prefs.edit().putString(key, "SYNTHETIC_INVALID_CIPHERTEXT").commit())
                            result.success(key)
                        }
                        "restoreCustom" -> {
                            val saved = savedCustom ?: error("No synthetic failure injected")
                            check(getSharedPreferences("FlutterSecureStorage", MODE_PRIVATE).edit()
                                .putString(saved.first, saved.second).commit())
                            result.success(true)
                        }
                        "save" -> {
                            File(filesDir, "gate-result.json").writeText(call.arguments as String)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    result.error("GATE_HELPER", error.toString(), null)
                }
            }
    }
}

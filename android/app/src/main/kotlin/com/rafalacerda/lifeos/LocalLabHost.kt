package com.rafalacerda.lifeos

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import com.google.firebase.FirebaseApp
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONObject

/** Only reachable in the OS-isolated, explicitly selected development package. */
object LocalLabHost {
    const val PACKAGE = "com.rafalacerda.lifeos.localdev"

    fun configure(context: Context, engine: FlutterEngine, scenario: () -> String) {
        check(context.packageName == PACKAGE)
        engine.plugins.add(io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin())
        engine.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
        engine.plugins.add(com.github.dart_lang.jni.JniPlugin())
        engine.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
        engine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        // Dev dependency may be absent from a non-test bundle. Never needed by production.
        try {
            val type = Class.forName("dev.flutter.plugins.integration_test.IntegrationTestPlugin")
            engine.plugins.add(type.getDeclaredConstructor().newInstance() as FlutterPlugin)
        } catch (_: ClassNotFoundException) { }

        var inputSequence = 0
        MethodChannel(engine.dartExecutor.binaryMessenger, "lifeos.local_lab").setMethodCallHandler { call, result ->
            when (call.method) {
                "audit" -> {
                    val forbidden = listOf(
                        "io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin",
                        "io.flutter.plugins.firebase.auth.FlutterFirebaseAuthPlugin",
                        "io.flutter.plugins.firebase.firestore.FlutterFirebaseFirestorePlugin",
                        "io.flutter.plugins.firebase.appcheck.FlutterFirebaseAppCheckPlugin",
                        "io.flutter.plugins.firebase.analytics.FlutterFirebaseAnalyticsPlugin",
                        "io.flutter.plugins.firebase.crashlytics.FlutterFirebaseCrashlyticsPlugin",
                        "io.flutter.plugins.googlesignin.GoogleSignInPlugin",
                        "io.flutter.plugins.inapppurchase.InAppPurchasePlugin",
                    ).filter { name ->
                        val type = Class.forName(name, false, context.classLoader).asSubclass(FlutterPlugin::class.java)
                        engine.plugins.has(type)
                    }
                    result.success(mapOf(
                        "package" to context.packageName,
                        "firebaseApps" to FirebaseApp.getApps(context).size,
                        "forbiddenPluginsRegistered" to forbidden,
                        "internetPermission" to (context.checkSelfPermission(Manifest.permission.INTERNET) == PackageManager.PERMISSION_GRANTED),
                        "processId" to android.os.Process.myPid(),
                    ))
                }
                "scenario" -> result.success(scenario())
                "requestSyntheticInput" -> {
                    val text = call.arguments as? String
                    if (text == null || !text.matches(Regex("(?:SYNTHETIC-[A-Z0-9-]{1,80}|[0-9]{1,8}(?:[.,][0-9]{1,2})?)"))) {
                        result.error("INVALID_SYNTHETIC_INPUT", "Synthetic test text required", null)
                    } else {
                        inputSequence++
                        val request = JSONObject().put("sequence", inputSequence).put("text", text)
                        File(context.filesDir, "local-lab-input.json").writeText(request.toString(), Charsets.UTF_8)
                        result.success(inputSequence)
                    }
                }
                "saveReport" -> {
                    val value = call.arguments as? String
                    if (value == null) result.error("INVALID_REPORT", "Expected JSON text", null)
                    else {
                        File(context.filesDir, "local-lab-result.json").writeText(value, Charsets.UTF_8)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

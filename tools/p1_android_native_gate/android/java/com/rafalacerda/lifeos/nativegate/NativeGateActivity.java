package com.rafalacerda.lifeos.nativegate;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;

public final class NativeGateActivity extends FlutterFragmentActivity {
  @Override public FlutterEngine provideFlutterEngine(@NonNull Context context) {
    if (!NativeGateApplication.ready) throw new IllegalStateException("NATIVE_NOT_READY");
    // Public engine constructor: automatic plugin registration disabled.
    return new FlutterEngine(context, null, false);
  }

  @Override public void configureFlutterEngine(@NonNull FlutterEngine engine) {
    // No super call: GeneratedPluginRegistrant includes production telemetry.
    engine.getPlugins().add(new io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin());
    engine.getPlugins().add(new io.flutter.plugins.firebase.auth.FlutterFirebaseAuthPlugin());
    engine.getPlugins().add(new io.flutter.plugins.firebase.firestore.FlutterFirebaseFirestorePlugin());
    engine.getPlugins().add(new io.flutter.plugins.firebase.appcheck.FlutterFirebaseAppCheckPlugin());
    engine.getPlugins().add(new com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin());
    engine.getPlugins().add(new io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin());
    engine.getPlugins().add(new io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin());
    engine.getPlugins().add(new com.github.dart_lang.jni.JniPlugin());
    engine.getPlugins().add(new com.github.dart_lang.jni_flutter.JniFlutterPlugin());
    new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "life_os/native_gate")
        .setMethodCallHandler((call, result) -> {
          if ("diagnoseAppCheck".equals(call.method)) { AppCheckDiagnostic.run(result); return; }
          if ("sanitizeDiagnostic".equals(call.method)) { result.success(AppCheckDiagnostic.redact(call.argument("text"))); return; }
          if (!"configuration".equals(call.method)) { result.notImplemented(); return; }
          result.success(Map.of("ready", NativeGateApplication.ready,
              "project", NativeGateApplication.PROJECT, "authPort", 45099,
              "firestorePort", 45089, "host", NativeGateApplication.HOST,
              "package", getPackageName(), "phase", getIntent().getStringExtra("phase") == null ? "initial" : getIntent().getStringExtra("phase")));
        });
  }
}

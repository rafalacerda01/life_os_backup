package com.rafalacerda.lifeos.homologation;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;

public final class HomologationActivity extends FlutterFragmentActivity {
  @Override public FlutterEngine provideFlutterEngine(@NonNull Context context) {
    if (!HomologationApplication.ready) throw new IllegalStateException("NATIVE_NOT_READY");
    // Public engine constructor: automatic plugin registration disabled.
    return new FlutterEngine(context, null, false);
  }

  @Override public void configureFlutterEngine(@NonNull FlutterEngine engine) {
    // No super call: GeneratedPluginRegistrant includes production telemetry.
    engine.getPlugins().add(new io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin());
    engine.getPlugins().add(new io.flutter.plugins.firebase.auth.FlutterFirebaseAuthPlugin());
    engine.getPlugins().add(new io.flutter.plugins.firebase.firestore.FlutterFirebaseFirestorePlugin());
    engine.getPlugins().add(new com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin());
    engine.getPlugins().add(new io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin());
    engine.getPlugins().add(new io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin());
    engine.getPlugins().add(new com.github.dart_lang.jni.JniPlugin());
    engine.getPlugins().add(new com.github.dart_lang.jni_flutter.JniFlutterPlugin());
    engine.getPlugins().add(new com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin());
    engine.getPlugins().add(new net.wolverinebeach.flutter_timezone.FlutterTimezonePlugin());
    engine.getPlugins().add(new io.flutter.plugins.localauth.LocalAuthPlugin());
    engine.getPlugins().add(new com.baseflow.permissionhandler.PermissionHandlerPlugin());
    new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "life_os/isolated_water")
        .setMethodCallHandler((call, result) -> {
          if (!"configuration".equals(call.method)) { result.notImplemented(); return; }
          result.success(Map.of("ready", HomologationApplication.ready,
              "project", HomologationApplication.PROJECT, "authPort", 9099,
              "firestorePort", 8089, "host", HomologationApplication.HOST,
              "package", getPackageName(), "telemetry", "excluded"));
        });
  }
}

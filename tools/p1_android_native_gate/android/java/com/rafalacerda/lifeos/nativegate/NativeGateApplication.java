package com.rafalacerda.lifeos.nativegate;

import android.app.Application;
import android.content.pm.ApplicationInfo;
import android.util.Log;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;

public final class NativeGateApplication extends Application {
  public static final String PROJECT = "demo-life-os";
  public static final String HOST = "127.0.0.1";
  public static boolean ready = false;

  @Override public void onCreate() {
    super.onCreate();
    if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0 ||
        !getPackageName().equals("com.rafalacerda.lifeos.p1nativegate") ||
        !FirebaseApp.getApps(this).isEmpty()) {
      throw new IllegalStateException("ISOLATION_BLOCKED_BEFORE_FIREBASE");
    }
    FirebaseOptions options = new FirebaseOptions.Builder()
        .setProjectId(PROJECT)
        .setApplicationId("1:123456789012:android:00000000000000000000000000000000")
        .setApiKey("AIzaSyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        .setGcmSenderId("123456789012").build();
    FirebaseApp app = FirebaseApp.initializeApp(this, options);
    if (app == null || !PROJECT.equals(app.getOptions().getProjectId())) {
      throw new IllegalStateException("SYNTHETIC_PROJECT_REQUIRED");
    }
    app.setDataCollectionDefaultEnabled(false);
    FirebaseAuth.getInstance(app).useEmulator(HOST, 45099);
    FirebaseFirestore.getInstance(app).useEmulator(HOST, 45089);
    ready = true;
    Log.i("NativeGate", "NATIVE_READY project=demo-life-os auth=45099 firestore=45089 telemetry=excluded appcheck=official-debug-only");
  }
}

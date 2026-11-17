package com.rafalacerda.lifeos.nativegate;

import android.app.Application;
import android.content.pm.ApplicationInfo;
import android.util.Log;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;

public final class NativeGateApplication extends Application {
  public static String PROJECT;
  public static String PROFILE;
  public static String APP_ID;
  public static final String HOST = "127.0.0.1";
  public static boolean ready = false;

  @Override public void onCreate() {
    super.onCreate();
    if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0 ||
        !getPackageName().equals("com.rafalacerda.lifeos.p1nativegate") ||
        !FirebaseApp.getApps(this).isEmpty()) {
      throw new IllegalStateException("ISOLATION_BLOCKED_BEFORE_FIREBASE");
    }
    int profileResource = getResources().getIdentifier("p1_native_environment", "string", getPackageName());
    if (profileResource == 0) {
      throw new IllegalStateException("LOCAL_ENVIRONMENT_PENDING_AUTHORIZATION");
    }
    PROFILE = getString(profileResource);
    PROJECT = option("p1_native_project");
    APP_ID = option("p1_native_app_id");
    boolean demo = PROFILE.equals("demo-loopback") && PROJECT.equals("demo-life-os") && APP_ID.equals("1:123456789012:android:00000000000000000000000000000000");
    boolean nominal = PROFILE.equals("p1-life-os-27b92-android-local") && PROJECT.equals("life-os-27b92") &&
        APP_ID.matches("1:278760083864:android:[a-f0-9]{16,40}") && !APP_ID.equals("1:278760083864:android:3e698113400113022d1bed");
    if (!demo && !nominal) throw new IllegalStateException("LOCAL_ENVIRONMENT_MISMATCH");
    FirebaseOptions options = new FirebaseOptions.Builder()
        .setProjectId(PROJECT)
        .setApplicationId(APP_ID)
        .setApiKey(option("p1_native_api_key"))
        .setGcmSenderId(option("p1_native_project_number")).build();
    FirebaseApp app = FirebaseApp.initializeApp(this, options);
    if (app == null || !PROJECT.equals(app.getOptions().getProjectId())) {
      throw new IllegalStateException("SYNTHETIC_PROJECT_REQUIRED");
    }
    app.setDataCollectionDefaultEnabled(false);
    FirebaseAuth.getInstance(app).useEmulator(HOST, 45099);
    FirebaseFirestore.getInstance(app).useEmulator(HOST, 45089);
    ready = true;
    Log.i("NativeGate", "NATIVE_READY auth=45099 firestore=45089 telemetry=excluded appcheck=official-debug-only");
  }
  private String option(String name) {
    int id = getResources().getIdentifier(name, "string", getPackageName());
    if (id == 0) throw new IllegalStateException("LOCAL_NATIVE_OPTIONS_REQUIRED");
    return getString(id);
  }
}

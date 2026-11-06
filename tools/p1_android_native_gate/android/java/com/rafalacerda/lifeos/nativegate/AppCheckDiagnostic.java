package com.rafalacerda.lifeos.nativegate;

import com.google.firebase.FirebaseApp;
import com.google.firebase.appcheck.FirebaseAppCheck;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Debug-only diagnostics. Never returns tokens, debug secrets or credentials. */
public final class AppCheckDiagnostic {
  public static String redact(String value) {
    if (value == null) return "";
    return value
      .replaceAll("AIza[0-9A-Za-z_-]+", "<redacted-api-key>")
      .replaceAll("(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<redacted-uuid>")
      .replaceAll("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*", "<redacted-jwt>")
      .replaceAll("(?i)(Bearer\\s+)[^\\s]+", "$1<redacted>")
      .replaceAll("(?i)([?&](?:key|token|secret)=)[^&\\s]+", "$1<redacted>")
      .replaceAll("(?i)((?:debug.?secret|debug.?token|refresh.?token|access.?token|authorization)\\s*[:=]\\s*)[^\\s,;]+", "$1<redacted>");
  }

  static List<Map<String,Object>> chain(Throwable error) {
    List<Map<String,Object>> list = new ArrayList<>();
    IdentityHashMap<Throwable,Boolean> seen = new IdentityHashMap<>();
    for (Throwable current=error; current!=null && !seen.containsKey(current); current=current.getCause()) {
      seen.put(current, true);
      Map<String,Object> row = new LinkedHashMap<>();
      row.put("class",current.getClass().getName()); row.put("message",redact(current.getMessage()));
      List<String> frames=new ArrayList<>(); for(StackTraceElement frame:current.getStackTrace()) frames.add(frame.toString());
      row.put("frames",frames);
      List<Map<String,Object>> suppressed=new ArrayList<>();for(Throwable other:current.getSuppressed()) {
        Map<String,Object> entry=new LinkedHashMap<>();entry.put("class",other.getClass().getName());entry.put("message",redact(other.getMessage()));suppressed.add(entry);
      }
      row.put("suppressed",suppressed);list.add(row);
    }
    return list;
  }

  public static void run(MethodChannel.Result result) {
    if(!NativeGateApplication.ready) {result.error("DIAGNOSTIC_CLOSED","Native configuration required",null);return;}
    FirebaseApp app=FirebaseApp.getInstance();
    FirebaseAppCheck check=FirebaseAppCheck.getInstance(app);
    check.getAppCheckToken(true).addOnCompleteListener(task->{
      Map<String,Object> value=new LinkedHashMap<>();
      value.put("sdkClass",check.getClass().getName());value.put("projectId",app.getOptions().getProjectId());value.put("appId",app.getOptions().getApplicationId());
      value.put("tokenReturned",task.isSuccessful());
      // Do not call getResult().getToken() or serialize a successful result.
      value.put("causes",chain(task.getException())); result.success(value);
    });
  }
}

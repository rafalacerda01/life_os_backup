package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Life OS Android boundary. No upstream auto-initialize/migrate/reset path. */
public class FlutterSecureStoragePlugin implements MethodChannel.MethodCallHandler, FlutterPlugin {
    private Context applicationContext;
    private MethodChannel channel;
    private HandlerThread worker;
    private Handler handler;
    private final Handler main = new Handler(Looper.getMainLooper());

    public void initInstance(BinaryMessenger messenger, Context context) {
        applicationContext = context.getApplicationContext();
        worker = new HandlerThread("lifeos.secure-storage");
        worker.start();
        handler = new Handler(worker.getLooper());
        channel = new MethodChannel(messenger, "plugins.it_nomads.com/flutter_secure_storage");
        channel.setMethodCallHandler(this);
    }
    @Override public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        initInstance(binding.getBinaryMessenger(), binding.getApplicationContext());
    }
    @Override public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        if (worker != null) worker.quitSafely();
        channel = null;
    }
    @Override public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        handler.post(() -> {
            try {
                final Object value;
                if (LifeOsPreservingStorage.handles(call.method)) {
                    value = LifeOsPreservingStorage.execute(applicationContext, call);
                } else if (call.method.equals("isDeviceSecure") || call.method.equals("isBiometricAvailable")) {
                    FlutterSecureStorage capability = new FlutterSecureStorage(applicationContext);
                    value = call.method.equals("isDeviceSecure") ? capability.isDeviceSecure() : capability.isBiometricAvailable();
                } else {
                    main.post(result::notImplemented);
                    return;
                }
                main.post(() -> result.success(value));
            } catch (Exception error) {
                String code = error instanceof LifeOsPreservingStorage.PreservationException
                        ? error.getMessage() : "LIFEOS_SECURE_STORAGE_PRESERVATION_REQUIRED";
                main.post(() -> result.error(code, "Secure storage requires preservation-aware recovery.", null));
            }
        });
    }
}

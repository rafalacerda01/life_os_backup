package com.rafalacerda.lifeos.candidate

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal object CandidateWork {
    private val worker = ThreadPoolExecutor(1, 1, 15, TimeUnit.SECONDS, ArrayBlockingQueue(1))
    fun submit(work: () -> Unit): Boolean = try {
        worker.execute(work)
        true
    } catch (_: RejectedExecutionException) { false }
}

private const val ENGINE_ID = "lifeos.official_local_candidate"

class OfficialStartupActivity : FragmentActivity() {
    private var flutter: FlutterFragment? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // An Android-restored task must pass admission again before attaching an engine.
        super.onCreate(null)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val message = TextView(this).apply { text = "Verificando armazenamento local…"; textSize = 18f }
        val content = FrameLayout(this).apply { id = View.generateViewId(); addView(message) }
        setContentView(content)
        if (!CandidateWork.submit {
            val denial = try {
                CandidateSession.prepare(applicationContext)
                null
            } catch (error: Exception) { (error as? StartupDenied)?.code ?: "STORAGE_UNAVAILABLE" }
            Log.i(STARTUP_LOG, if (denial == null) "NATIVE_ADMITTED" else "NATIVE_DENIED $denial")
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                if (denial == null) {
                    CandidateSession.engine(applicationContext)
                    val fragment = FlutterFragment.withCachedEngine(ENGINE_ID)
                        .shouldAutomaticallyHandleOnBackPressed(true)
                        .build<FlutterFragment>()
                    flutter = fragment
                    content.removeView(message)
                    supportFragmentManager.beginTransaction()
                        .add(content.id, fragment)
                        .commitNowAllowingStateLoss()
                } else {
                    message.text = "Armazenamento preservado. Abertura local bloqueada.\n$denial"
                }
            }
        }) message.text = "O armazenamento local está ocupado. Tente novamente."
    }

    override fun onPostResume() {
        super.onPostResume()
        flutter?.onPostResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        flutter?.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        flutter?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        flutter?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        flutter?.onUserLeaveHint()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        flutter?.onTrimMemory(level)
    }
}

/** The one admitted engine lives as long as this process, including Activity recreation. */
private object CandidateSession {
    private var lease: OfficialStartupFence.Session? = null
    @Volatile private var admission: OfficialStartupFence.Admission? = null
    @Volatile private var attested = false
    private var engine: FlutterEngine? = null
    private val main = Handler(Looper.getMainLooper())

    fun prepare(context: Context) {
        if (admission != null) return
        if (Build.VERSION.SDK_INT < 28 || Application.getProcessName() != OFFICIAL_PACKAGE) {
            throw StartupDenied("PROCESS_UNQUALIFIED")
        }
        if (context.checkSelfPermission(Manifest.permission.INTERNET) == PackageManager.PERMISSION_GRANTED) {
            throw StartupDenied("NETWORK_PERMISSION_PRESENT")
        }
        val pair = OfficialStartupFence(context).claimSession()
        lease = pair.first
        admission = pair.second
    }

    fun engine(context: Context): FlutterEngine {
        checkNotNull(lease)
        checkNotNull(admission)
        return engine ?: FlutterEngine(context, null, false).also { flutter ->
            flutter.plugins.add(io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin())
            flutter.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
            flutter.plugins.add(com.github.dart_lang.jni.JniPlugin())
            flutter.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
            flutter.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
            flutter.plugins.add(io.flutter.plugins.localauth.LocalAuthPlugin())
            flutter.plugins.add(com.baseflow.permissionhandler.PermissionHandlerPlugin())
            MethodChannel(flutter.dartExecutor.binaryMessenger, "lifeos.official_local_candidate").setMethodCallHandler { call, result ->
                if (call.method == "admission") {
                    val state = checkNotNull(admission)
                    result.success(mapOf("epoch" to state.epoch, "uid" to state.uid, "namespace" to state.namespace))
                } else if (!CandidateWork.submit {
                    try {
                        val fence = OfficialStartupFence(context)
                        val answer = when (call.method) {
                            "opened" -> {
                                val previous = checkNotNull(admission)
                                admission = fence.attest(previous, call.argument<String>("uid") ?: throw StartupDenied("IDENTITY_MISSING"),
                                    call.argument<String>("namespace") ?: throw StartupDenied("IDENTITY_MISSING"))
                                attested = true
                                Log.i(STARTUP_LOG, "DART_SESSION_READY epoch=${admission!!.epoch}")
                                true
                            }
                            "reminderStatus", "createReminder", "cancelReminder" -> {
                                if (!attested) throw StartupDenied("DART_IDENTITY_UNATTESTED")
                                fence.readyWork { state ->
                                    if (state != admission) throw StartupDenied("STALE_SESSION")
                                    val reminder = OfficialTaskAlarm(context, fence, state)
                                    when (call.method) {
                                        "reminderStatus" -> reminder.status()
                                        "createReminder" -> reminder.create(call.arguments as? Int ?: throw StartupDenied("INVALID_MINUTE"))
                                        else -> {
                                            reminder.cancel()
                                            null
                                        }
                                    }
                                }
                            }
                            else -> throw StartupDenied("METHOD_UNQUALIFIED")
                        }
                        main.post { result.success(answer) }
                    } catch (error: Exception) {
                        main.post { result.error((error as? StartupDenied)?.code ?: "STORAGE_UNAVAILABLE", "Native operation refused", null) }
                    }
                }) result.error("WRITER_BUSY", "Native operation busy", null)
            }
            engine = flutter
            FlutterEngineCache.getInstance().put(ENGINE_ID, flutter)
            Log.i(STARTUP_LOG, "STARTING_DART")
            flutter.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
}

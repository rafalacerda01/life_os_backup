package com.rafalacerda.lifeos.fence

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

class FenceLabActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val command = intent.getStringExtra("fence21") ?: "start"
        val status = try {
            val fence = NativeWriterFence(this)
            when (command) {
                "seed" -> {
                    fence.enrollSynthetic()
                    openEngine(true)
                }
                "start" -> {
                    fence.admit().close()
                    openEngine(false)
                }
                "freeze" -> { fence.freezeSynthetic(); "FROZEN" }
                "interrupt" -> { fence.interruptSynthetic(); "INTERRUPTED" }
                "alarm", "stale" -> {
                    val cached = JSONArray(readSchedule(this)).getJSONObject(0)
                    if (command == "stale") cached.put("payload", fence.payload(0))
                    val pending = PendingIntent.getBroadcast(this, if (command == "alarm") 21002 else 21003,
                        Intent().setClassName(this, DELIVERY).putExtra(DETAILS, cached.toString()),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + 1000, pending)
                    "ALARM_ARMED"
                }
                "action" -> {
                    sendBroadcast(Intent("$ACTION.ACTION_TAPPED").setClassName(this, ACTION))
                    "ACTION_SENT"
                }
                else -> throw FenceRejected("UNKNOWN_COMMAND")
            }
        } catch (error: Exception) {
            "DENIED ${(error as? FenceRejected)?.reason ?: "IO_OR_FORMAT"}"
        }
        Log.i(LOG, "$packageName NATIVE_$command $status")
        setContentView(TextView(this).apply { text = "Native fence: $status"; textSize = 20f })
    }

    private fun openEngine(seed: Boolean): String {
        startActivity(Intent(this, FenceLabEngineActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("syntheticSeed", seed))
        return "ADMISSION_REQUESTED"
    }
}

/** The non-exported secondary process holds the lease before creating a Flutter engine. */
class FenceLabEngineActivity : FlutterActivity() {
    private var lease: NativeWriterFence.Lease? = null
    private lateinit var fence: NativeWriterFence
    private var seeded = false
    private var isSeed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            fence = NativeWriterFence(this)
            isSeed = intent.getBooleanExtra("syntheticSeed", false)
            lease = fence.admit(syntheticSeed = isSeed)
        } catch (error: Exception) {
            Log.i(LOG, "$packageName ENGINE_DENIED ${(error as? FenceRejected)?.reason ?: "IO_OR_FORMAT"}")
            // The native launcher prechecks the lease. A race at this boundary
            // finishes the lab process instead of invoking FlutterActivity.onCreate.
            android.os.Process.killProcess(android.os.Process.myPid())
            return
        }
        Log.i(LOG, "$packageName ENGINE_ADMITTED seed=$isSeed epoch=${lease!!.state.epoch}")
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        check(lease?.valid == true)
        engine.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
        engine.plugins.add(com.github.dart_lang.jni.JniPlugin())
        engine.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
        engine.plugins.add(com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin())
        MethodChannel(engine.dartExecutor.binaryMessenger, "lifeos.fence21").setMethodCallHandler { call, result ->
            try {
                val held = checkNotNull(lease)
                check(held.valid)
                when (call.method) {
                    "admission" -> result.success(mapOf("kind" to fence.binding.kind, "uid" to fence.binding.uid,
                        "namespace" to fence.binding.namespace, "stamp" to fence.payload(held.state.epoch),
                        "seed" to isSeed, "pid" to android.os.Process.myPid()))
                    "report" -> {
                        val report = JSONObject(call.arguments as String)
                        val phase = if (isSeed) "seed" else "verify"
                        if (isSeed && report.optBoolean("ok")) {
                            check(!seeded)
                            check(getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().commit())
                            fence.finishSyntheticSeed(held)
                            seeded = true
                        }
                        val file = File(filesDir, "fence21-$phase.json")
                        val tmp = File(filesDir, "fence21-$phase.tmp")
                        FileOutputStream(tmp).use { stream -> stream.write(report.toString().toByteArray()); stream.fd.sync() }
                        if (!tmp.renameTo(file)) throw IllegalStateException("REPORT_UNAVAILABLE")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("NATIVE_FENCE_REJECTED", "Native proof failed", null)
            }
        }
    }

    override fun onDestroy() {
        try { super.onDestroy() } finally { lease?.close(); lease = null }
    }
}

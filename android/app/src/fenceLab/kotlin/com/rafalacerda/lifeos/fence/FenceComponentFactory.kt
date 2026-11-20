package com.rafalacerda.lifeos.fence

import android.app.AppComponentFactory
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.util.Xml
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.File

internal const val DELIVERY = "com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
internal const val RESTORE = "com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"
internal const val ACTION = "com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"
internal const val DETAILS = "notificationDetails"
internal const val PREFS = "scheduled_notifications"
internal const val FIXTURE_ID = 21001
internal const val LOG = "LifeOsFence21"

/** Preserves the explicit component names kept by already scheduled PendingIntents. */
class FenceComponentFactory : AppComponentFactory() {
    override fun instantiateReceiver(loader: ClassLoader, name: String, intent: Intent?): BroadcastReceiver {
        if (name !in setOf(DELIVERY, RESTORE, ACTION)) return super.instantiateReceiver(loader, name, intent)
        return object : BroadcastReceiver() {
            override fun onReceive(context: Context, message: Intent) {
                val event = if (name == DELIVERY) "DELIVERY" else if (name == ACTION) "ACTION" else message.action ?: "RESTORE"
                try {
                    val fence = NativeWriterFence(context)
                    fence.admit().use { lease ->
                        if (name == ACTION) throw FenceRejected("ASYNC_ENGINE_NOT_ADMITTED")
                        if (fence.binding.kind != "local") throw FenceRejected("LEGACY_CALLBACK_NOT_ADMITTED")
                        val stamp = fence.payload(lease.state.epoch)
                        val disk = readSchedule(context)
                        val current = JSONArray(disk)
                        if ((0 until current.length()).any { !owned(current.getJSONObject(it), stamp) }) {
                            throw FenceRejected("CACHE_OWNERSHIP_MISMATCH")
                        }
                        if (name == DELIVERY) {
                            val details = JSONObject(message.getStringExtra(DETAILS) ?: throw FenceRejected("UNSTAMPED_DELIVERY"))
                            if (!owned(details, stamp)) throw FenceRejected("STAMP_MISMATCH")
                            if ((0 until current.length()).none { current.getJSONObject(it).similarFixture(details) }) {
                                throw FenceRejected("DELIVERY_NOT_REGISTERED")
                            }
                        }
                        val cached = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        if (cached.getString(PREFS, "[]") != disk) throw FenceRejected("CACHE_DIVERGED")
                        // Use the original synchronous receiver under admission. An empty
                        // commit waits for SharedPreferences writes enqueued by apply().
                        super@FenceComponentFactory.instantiateReceiver(loader, name, message).onReceive(context, message)
                        if (!cached.edit().commit()) throw FenceRejected("CACHE_FLUSH_INCOMPLETE")
                        Log.i(LOG, "${context.packageName} $event DELEGATED epoch=${lease.state.epoch}")
                    }
                } catch (error: Exception) {
                    Log.i(LOG, "${context.packageName} $event DENIED ${(error as? FenceRejected)?.reason ?: "IO_OR_FORMAT"}")
                }
            }
        }
    }

    private fun owned(value: JSONObject, stamp: String): Boolean =
        value.opt("id") == FIXTURE_ID && value.opt("payload") == stamp

    private fun JSONObject.similarFixture(other: JSONObject): Boolean =
        length() == other.length() && keys().asSequence().all { opt(it).toString() == other.opt(it).toString() }
}

internal fun readSchedule(context: Context): String {
    val dir = File(context.applicationInfo.dataDir, "shared_prefs")
    val file = File(dir, "$PREFS.xml")
    if (File(dir, "$PREFS.xml.bak").exists()) throw FenceRejected("CACHE_BACKUP_PRESENT")
    if (!file.exists()) return "[]"
    if (!file.isFile || file.length() !in 1..65536) throw FenceRejected("CACHE_INVALID")
    file.inputStream().use { stream ->
        val xml = Xml.newPullParser()
        xml.setInput(stream, Charsets.UTF_8.name())
        while (xml.eventType != XmlPullParser.END_DOCUMENT) {
            if (xml.eventType == XmlPullParser.START_TAG && xml.name == "string" && xml.getAttributeValue(null, "name") == PREFS) {
                return xml.nextText()
            }
            xml.next()
        }
    }
    throw FenceRejected("CACHE_INVALID")
}

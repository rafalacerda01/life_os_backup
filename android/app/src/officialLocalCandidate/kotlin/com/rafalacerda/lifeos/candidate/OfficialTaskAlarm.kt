package com.rafalacerda.lifeos.candidate

import android.app.AlarmManager
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Process
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val DELIVERY = "com.rafalacerda.lifeos.candidate.DELIVER_TASK_REMINDER"
private const val CHANNEL = "official_local_task_reminder"
private const val NOTIFICATION_ID = 22001

/** Only the candidate's own reminder record is writable by the native worker. */
internal class OfficialTaskAlarm(
    private val context: Context,
    private val fence: OfficialStartupFence,
    private val state: OfficialStartupFence.Admission,
) {
    private val record = File(fence.root, "reminder.json")
    private val pending = File(fence.root, "reminder.pending")
    private val alarms get() = context.getSystemService(AlarmManager::class.java)
    private val notifications get() = context.getSystemService(NotificationManager::class.java)

    private data class Schedule(val minute: Int, val token: String, val due: Long)

    fun status(): Map<String, Any?> {
        val schedule = load()
        val missing = schedule != null && (schedule.due <= System.currentTimeMillis() ||
            pendingIntent(schedule, PendingIntent.FLAG_NO_CREATE) == null)
        return mapOf("minute" to if (missing) null else schedule?.minute, "needsRecovery" to missing)
    }

    fun create(minute: Int): Boolean {
        if (minute !in 0..1439) throw StartupDenied("INVALID_MINUTE")
        if (!notifications.areNotificationsEnabled()) return false
        if (load() != null) throw StartupDenied("REMINDER_ALREADY_CONFIGURED")
        val schedule = nextSchedule(minute)
        save(schedule)
        arm(schedule)
        return true
    }

    fun cancel() {
        val schedule = load() ?: return
        save(null)
        pendingIntent(schedule, PendingIntent.FLAG_NO_CREATE)?.let {
            alarms.cancel(it)
            it.cancel()
        }
        notifications.cancel(CHANNEL, NOTIFICATION_ID)
    }

    fun restore(): Boolean {
        val schedule = load() ?: return false
        val current = if (schedule.due > System.currentTimeMillis()) schedule else nextSchedule(schedule.minute)
        if (current != schedule) save(current)
        arm(current)
        return true
    }

    fun deliver(intent: Intent): Boolean {
        val schedule = load() ?: throw StartupDenied("REMINDER_NOT_REGISTERED")
        if (intent.getStringExtra("namespace") != state.namespace || intent.getLongExtra("epoch", -1) != state.epoch ||
            intent.data != uri(schedule) || intent.getLongExtra("due", -1) != schedule.due ||
            System.currentTimeMillis() < schedule.due - 1000) throw StartupDenied("STALE_REMINDER")
        // Consume this token before the side effect. A crash cannot replay it.
        val next = nextSchedule(schedule.minute)
        save(next)
        arm(next)
        if (!notifications.areNotificationsEnabled()) return false
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Lembretes de tarefas", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, NOTIFICATION_ID, Intent(context, OfficialStartupActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val message = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("Life OS").setContentText("Revise suas tarefas no Life OS.")
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(open).build()
        notifications.notify(CHANNEL, NOTIFICATION_ID, message)
        return true
    }

    private fun load(): Schedule? {
        if (pending.exists()) throw StartupDenied("REMINDER_JOURNAL_PENDING")
        if (!record.exists()) return null
        if (record.canonicalFile != record.absoluteFile || !record.isFile || record.length() !in 1..1024) throw StartupDenied("REMINDER_INVALID")
        val data = JSONObject(record.readText())
        val epoch = when (val value = data.opt("epoch")) {
            is Int -> value.toLong()
            is Long -> value
            else -> throw StartupDenied("REMINDER_INVALID")
        }
        if (data.opt("version") != 1 || data.opt("namespace") != state.namespace || epoch != state.epoch) {
            throw StartupDenied("STALE_REMINDER")
        }
        return when (data.opt("phase")) {
            "DISABLED" -> if (data.length() == 4) null else throw StartupDenied("REMINDER_INVALID")
            "ACTIVE" -> {
                if (data.length() != 7) throw StartupDenied("REMINDER_INVALID")
                val minute = data.opt("minute") as? Int ?: throw StartupDenied("REMINDER_INVALID")
                val token = data.optString("token")
                val due = data.opt("due") as? Long ?: throw StartupDenied("REMINDER_INVALID")
                if (minute !in 0..1439 || !token.matches(Regex("[a-f0-9-]{36}")) || due < 1) throw StartupDenied("REMINDER_INVALID")
                Schedule(minute, token, due)
            }
            else -> throw StartupDenied("REMINDER_INVALID")
        }
    }

    private fun save(schedule: Schedule?) {
        val data = JSONObject().put("version", 1).put("namespace", state.namespace).put("epoch", state.epoch)
        if (schedule == null) data.put("phase", "DISABLED")
        else data.put("phase", "ACTIVE").put("minute", schedule.minute).put("token", schedule.token).put("due", schedule.due)
        fence.writeRecord(record, pending, data)
    }

    private fun nextSchedule(minute: Int): Schedule {
        val now = System.currentTimeMillis()
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, minute / 60)
            set(Calendar.MINUTE, minute % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= now) add(Calendar.DAY_OF_YEAR, 1)
        }
        return Schedule(minute, UUID.randomUUID().toString(), calendar.timeInMillis)
    }

    private fun uri(schedule: Schedule) = Uri.parse("lifeos-candidate://task-reminder/${schedule.token}")

    private fun pendingIntent(schedule: Schedule, flags: Int): PendingIntent? = PendingIntent.getBroadcast(
        context, NOTIFICATION_ID, Intent(context, OfficialTaskAlarmReceiver::class.java).setAction(DELIVERY)
            .setData(uri(schedule)).putExtra("namespace", state.namespace).putExtra("epoch", state.epoch).putExtra("due", schedule.due),
        flags or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun arm(schedule: Schedule) {
        val alarm = checkNotNull(pendingIntent(schedule, PendingIntent.FLAG_UPDATE_CURRENT))
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, schedule.due, alarm)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, schedule.due, alarm)
        }
    }
}

class OfficialTaskAlarmReceiver : BroadcastReceiver() {
    companion object { private val watchdog = Executors.newSingleThreadScheduledExecutor() }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in setOf(DELIVERY, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        if (Build.VERSION.SDK_INT < 28 || Application.getProcessName() != "$OFFICIAL_PACKAGE:local_candidate_worker") return
        val completion = goAsync()
        val completed = AtomicBoolean(false)
        // The watchdog only runs in the dedicated native worker process. A timed
        // out operation must not release admission while it still has a writer.
        val timeout = watchdog.schedule({
            if (completed.compareAndSet(false, true)) {
                Log.e(STARTUP_LOG, "CALLBACK_TIMEOUT $action")
                Process.killProcess(Process.myPid())
            }
        }, 7, TimeUnit.SECONDS)
        if (!CandidateWork.submit {
            try {
                val fence = OfficialStartupFence(context)
                val applied = fence.readyWork { state ->
                    val alarm = OfficialTaskAlarm(context, fence, state)
                    if (action == DELIVERY) alarm.deliver(intent) else alarm.restore()
                }
                Log.i(STARTUP_LOG, "CALLBACK_FINISHED $action effect=$applied")
            } catch (error: Exception) {
                Log.i(STARTUP_LOG, "CALLBACK_DENIED $action ${(error as? StartupDenied)?.code ?: "STORAGE_UNAVAILABLE"}")
            } finally {
                if (completed.compareAndSet(false, true)) { timeout.cancel(false); completion.finish() }
            }
        }) {
            if (completed.compareAndSet(false, true)) { timeout.cancel(false); completion.finish() }
            Log.i(STARTUP_LOG, "CALLBACK_DENIED $action WRITER_BUSY")
        }
    }
}

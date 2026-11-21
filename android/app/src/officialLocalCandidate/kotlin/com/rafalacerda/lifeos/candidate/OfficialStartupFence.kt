package com.rafalacerda.lifeos.candidate

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import java.security.MessageDigest

internal const val OFFICIAL_PACKAGE = "com.rafalacerda.lifeos"
internal const val STARTUP_LOG = "LifeOsCandidate22"

internal class StartupDenied(val code: String) : Exception(code)

/** Candidate-only admission. Legacy stores are inspected by filename, never opened here. */
internal class OfficialStartupFence(private val context: Context) {
    private val data = File(context.applicationInfo.dataDir).canonicalFile
    internal val root = File(data, "no_backup/life_os_native_startup_v1")
    private val record = File(root, "startup.json")
    private val pending = File(root, "startup.pending")

    internal data class Admission(val epoch: Long, val uid: String?, val namespace: String?) {
        val ready: Boolean get() = uid != null
    }

    /** The process keeps this descriptor while its cached Dart engine can write. */
    internal class Session(private val descriptor: RandomAccessFile) : AutoCloseable {
        override fun close() { descriptor.close() }
    }

    init {
        if (context.packageName != OFFICIAL_PACKAGE) throw StartupDenied("PACKAGE_INVALID")
        // Compatibility gate, independent of the manifest's unchanged minSdk.
        if (Build.VERSION.SDK_INT < 28) throw StartupDenied("ANDROID_VERSION_UNQUALIFIED")
        if (root.canonicalFile != root.absoluteFile) throw StartupDenied("COORDINATOR_PATH_INVALID")
    }

    fun claimSession(): Pair<Session, Admission> {
        // An absent fence on a prior installation must not even create coordination files.
        if (!root.exists()) requireEmptyInstallation()
        if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) throw StartupDenied("COORDINATOR_UNAVAILABLE")
        val session = Session(acquire("session.lock"))
        try {
            return session to coordinate {
                val existing = load()
                if (existing == null) {
                    requireEmptyInstallation()
                    Admission(1L, null, null).also(::publish)
                } else {
                    if (!existing.ready) throw StartupDenied("INTERRUPTED_BOOTSTRAP")
                    requireExistingDatabase(existing)
                    existing
                }
            }
        } catch (error: Exception) {
            session.close()
            throw error
        }
    }

    fun attest(opened: Admission, uid: String, namespace: String): Admission = coordinate {
        val current = load() ?: throw StartupDenied("ADMISSION_MISSING")
        if (current != opened || !validIdentity(uid, namespace)) throw StartupDenied("IDENTITY_MISMATCH")
        if (current.ready && (current.uid != uid || current.namespace != namespace)) throw StartupDenied("IDENTITY_MISMATCH")
        val verified = Admission(current.epoch, uid, namespace)
        requireExistingDatabase(verified)
        if (!current.ready) publish(verified)
        verified
    }

    /** Native background work only touches this coordinator and its own reminder record. */
    fun <T> readyWork(work: (Admission) -> T): T {
        if (!root.isDirectory) throw StartupDenied("ADMISSION_MISSING")
        return coordinate {
            val state = load() ?: throw StartupDenied("ADMISSION_MISSING")
            if (!state.ready) throw StartupDenied("INTERRUPTED_BOOTSTRAP")
            requireExistingDatabase(state)
            work(state)
        }
    }

    private fun acquire(name: String, waitMillis: Long = 0): RandomAccessFile {
        val path = File(root, name)
        if (path.canonicalFile != path.absoluteFile || (path.exists() && (!path.isFile || path.length() != 0L))) {
            throw StartupDenied("LOCK_PATH_INVALID")
        }
        val opened = RandomAccessFile(path, "rw")
        try {
            val start = SystemClock.elapsedRealtime()
            while (opened.channel.tryLock() == null) {
                if (SystemClock.elapsedRealtime() - start >= waitMillis) throw StartupDenied("WRITER_BUSY")
                Thread.sleep(20)
            }
            return opened
        } catch (error: Exception) {
            opened.close()
            if (error is OverlappingFileLockException) throw StartupDenied("WRITER_BUSY")
            throw error
        }
    }

    // The shared executor serializes callers inside each OS process. File locks
    // exclude another process. A prospective migration must take session then writer.
    private fun <T> coordinate(block: () -> T): T = acquire("writer.lock", waitMillis = 400).use { block() }

    private fun load(): Admission? {
        if (pending.exists()) throw StartupDenied("INTERRUPTED_JOURNAL")
        if (!record.exists()) return null
        if (record.canonicalFile != record.absoluteFile || !record.isFile || record.length() !in 1..1024) {
            throw StartupDenied("RECORD_INVALID")
        }
        val json = JSONObject(record.readText())
        val epoch = when (val item = json.opt("epoch")) {
            is Long -> item
            is Int -> item.toLong()
            else -> throw StartupDenied("RECORD_INVALID")
        }
        if (json.length() != 5 || json.opt("version") != 1 || epoch < 1) throw StartupDenied("RECORD_INVALID")
        return when (json.opt("phase")) {
            "BOOTSTRAPPING" -> if (json.get("uid") == JSONObject.NULL && json.get("namespace") == JSONObject.NULL) Admission(epoch, null, null)
                else throw StartupDenied("RECORD_INVALID")
            "READY" -> {
                val uid = json.opt("uid") as? String ?: throw StartupDenied("RECORD_INVALID")
                val namespace = json.opt("namespace") as? String ?: throw StartupDenied("RECORD_INVALID")
                if (!validIdentity(uid, namespace)) throw StartupDenied("IDENTITY_MISMATCH")
                Admission(epoch, uid, namespace)
            }
            else -> throw StartupDenied("RECORD_INVALID")
        }
    }

    private fun publish(value: Admission) {
        writeRecord(record, pending, JSONObject().put("version", 1).put("epoch", value.epoch)
            .put("phase", if (value.ready) "READY" else "BOOTSTRAPPING")
            .put("uid", value.uid ?: JSONObject.NULL).put("namespace", value.namespace ?: JSONObject.NULL))
    }

    fun writeRecord(target: File, staging: File, value: JSONObject) {
        if (!staging.createNewFile()) throw StartupDenied("INTERRUPTED_JOURNAL")
        syncDirectory()
        FileOutputStream(staging).use { out -> out.write(value.toString().toByteArray(Charsets.UTF_8)); out.fd.sync() }
        Os.rename(staging.path, target.path)
        syncDirectory()
    }

    private fun syncDirectory() {
        val fd = Os.open(root.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    }

    private fun requireEmptyInstallation() {
        fun inspect(base: File, admitCoordinator: Boolean) {
            for (entry in base.listFiles() ?: if (!base.exists()) emptyArray() else throw StartupDenied("STORAGE_UNAVAILABLE")) {
                if (entry.canonicalFile != entry.absoluteFile || !entry.isDirectory) throw StartupDenied("LEGACY_STORAGE_PRESENT")
                if (entry.name in setOf("cache", "code_cache")) continue
                val contained = entry.listFiles() ?: throw StartupDenied("STORAGE_UNAVAILABLE")
                if (entry.name == "no_backup" && admitCoordinator) {
                    if (contained.any { it != root }) throw StartupDenied("LEGACY_STORAGE_PRESENT")
                    val files = root.listFiles() ?: if (!root.exists()) emptyArray() else throw StartupDenied("STORAGE_UNAVAILABLE")
                    if (files.any { it.name !in setOf("writer.lock", "session.lock") || !it.isFile || it.length() != 0L }) {
                        throw StartupDenied("LEGACY_STORAGE_PRESENT")
                    }
                } else if (entry.name !in setOf("no_backup", "app_flutter", "files", "shared_prefs", "databases") || contained.isNotEmpty()) {
                    throw StartupDenied("LEGACY_STORAGE_PRESENT")
                }
            }
        }
        inspect(data, true)
        inspect(File(context.applicationInfo.deviceProtectedDataDir).canonicalFile, false)
    }

    private fun requireExistingDatabase(state: Admission) {
        val docs = File(data, "app_flutter")
        val name = "life_os_${state.namespace}.sqlite"
        val main = File(docs, name)
        if (main.canonicalFile != main.absoluteFile || !main.isFile || main.length() < 16) throw StartupDenied("EXPECTED_DATABASE_MISSING")
        val entries = docs.listFiles() ?: throw StartupDenied("STORAGE_UNAVAILABLE")
        val expected = setOf(name, "$name-wal", "$name-shm", "$name-journal", "life_os_local_admission_v1.sqlite")
        if (entries.any { it.name.startsWith("life_os") && (it.name !in expected || it.canonicalFile != it.absoluteFile || !it.isFile) }) {
            throw StartupDenied("LEGACY_STORAGE_PRESENT")
        }
        // Existing device-encrypted files can be used by native components before unlock.
        val device = File(context.applicationInfo.deviceProtectedDataDir).canonicalFile
        if (listOf("app_flutter", "files", "shared_prefs", "databases").any { name ->
                val dir = File(device, name)
                dir.exists() && (!dir.isDirectory || dir.listFiles()?.isNotEmpty() != false)
            }) throw StartupDenied("LEGACY_STORAGE_PRESENT")
    }

    private fun validIdentity(uid: String, namespace: String): Boolean {
        if (!uid.matches(Regex("local-v1-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))) return false
        return namespace == "u_" + MessageDigest.getInstance("SHA-256").digest(uid.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}

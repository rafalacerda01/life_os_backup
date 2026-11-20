package com.rafalacerda.lifeos.fence

import android.content.Context
import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

internal data class FenceBinding(
    val kind: String,
    val uid: String,
    val project: String?,
    val database: String?,
    val tenant: String?,
    val generation: String?,
) {
    val namespace: String get() {
        val bytes = if (generation == null) uid else JSONArray().put(2).put(project)
            .put(database).put(tenant ?: JSONObject.NULL).put(uid).put(generation).toString()
        return "u_" + MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    fun asJson(): JSONObject = JSONObject().put("kind", kind).put("uid", uid)
        .put("project", project ?: JSONObject.NULL).put("database", database ?: JSONObject.NULL)
        .put("tenant", tenant ?: JSONObject.NULL).put("generation", generation ?: JSONObject.NULL)
        .put("namespace", namespace)

    companion object {
        fun forPackage(name: String): FenceBinding? = when (name) {
            "com.rafalacerda.lifeos.fenceuid" -> FenceBinding("uid", "synthetic-fence21-uid", null, null, null, null)
            "com.rafalacerda.lifeos.fencep1" -> FenceBinding("p1", "synthetic-fence21-p1", "fence21-project", "(default)", "fence21-tenant", "00000000-0000-4000-8000-000000000021")
            "com.rafalacerda.lifeos.fencelocal" -> FenceBinding("local", "local-v1-00000000-0000-4000-8000-000000000021", null, null, null, null)
            else -> null
        }
    }
}

internal class FenceRejected(val reason: String) : Exception(reason)

/** The coordination files and the callbacks exist only in the fence lab build. */
internal class NativeWriterFence(context: Context) {
    val binding = FenceBinding.forPackage(context.packageName) ?: throw FenceRejected("WRONG_PACKAGE")
    private val root = File(context.noBackupFilesDir.canonicalFile, "native-writer-fence-v1")
    private val record = File(root, "record.json")
    private val pending = File(root, "record.pending")

    internal data class State(val epoch: Long, val frozen: Boolean, val ready: Boolean)

    internal class Lease(private val file: RandomAccessFile, private val lock: FileLock, val state: State) : AutoCloseable {
        val valid: Boolean get() = lock.isValid
        override fun close() {
            try { lock.release() } finally {
                try { file.close() } finally { processBusy.set(false) }
            }
        }
    }

    private companion object {
        // Do not open a second descriptor for a POSIX-locked inode in this process.
        val processBusy = AtomicBoolean(false)
    }

    private fun <T> locked(create: Boolean = false, block: (RandomAccessFile, FileLock) -> T): T {
        if (!processBusy.compareAndSet(false, true)) throw FenceRejected("WRITER_BUSY")
        var file: RandomAccessFile? = null
        var retained = false
        try {
            if (create && !root.isDirectory && !root.mkdir() && !root.isDirectory) throw FenceRejected("STATE_UNAVAILABLE")
            if (!root.isDirectory) throw FenceRejected("UNENROLLED")
            if (root.canonicalFile != root.absoluteFile) throw FenceRejected("LOCK_PATH_INVALID")
            val lockPath = File(root, "writer.lock")
            if (lockPath.canonicalFile != lockPath.absoluteFile) throw FenceRejected("LOCK_PATH_INVALID")
            val opened = RandomAccessFile(lockPath, "rw")
            file = opened
            val lock = try { opened.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                ?: throw FenceRejected("WRITER_BUSY")
            val result = block(opened, lock)
            retained = result is Lease
            return result
        } finally {
            if (!retained) {
                try { file?.close() } finally { processBusy.set(false) }
            }
        }
    }

    private fun read(): State {
        if (pending.exists()) throw FenceRejected("INTERRUPTED_JOURNAL")
        if (!record.exists()) throw FenceRejected("UNENROLLED")
        if (!record.isFile || record.canonicalFile != record.absoluteFile || record.length() !in 1..2048) {
            throw FenceRejected("STATE_INVALID")
        }
        val value = try { JSONObject(record.readText(Charsets.UTF_8)) } catch (_: Exception) { throw FenceRejected("STATE_INVALID") }
        val expected = binding.asJson()
        if (value.length() != expected.length() + 4 || value.opt("version") != 1 ||
            expected.keys().asSequence().any { value.opt(it) != expected.get(it) }) throw FenceRejected("IDENTITY_MISMATCH")
        val epoch = when (val stored = value.opt("epoch")) {
            is Int -> stored.toLong()
            is Long -> stored
            else -> throw FenceRejected("STATE_INVALID")
        }
        if (epoch < 1) throw FenceRejected("STATE_INVALID")
        val frozen = value.opt("frozen") as? Boolean ?: throw FenceRejected("STATE_INVALID")
        val ready = value.opt("ready") as? Boolean ?: throw FenceRejected("STATE_INVALID")
        return State(epoch, frozen, ready)
    }

    private fun write(state: State) {
        if (!pending.createNewFile()) throw FenceRejected("INTERRUPTED_JOURNAL")
        syncDirectory()
        FileOutputStream(pending).use { stream ->
            stream.write(binding.asJson().put("version", 1).put("epoch", state.epoch)
                .put("frozen", state.frozen).put("ready", state.ready).toString().toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        }
        Os.rename(pending.path, record.path)
        syncDirectory()
    }

    private fun syncDirectory() {
        val directory = Os.open(root.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(directory) } finally { Os.close(directory) }
    }

    fun enrollSynthetic() = locked(create = true) { _, _ ->
        if (record.exists() || pending.exists()) throw FenceRejected("ALREADY_ENROLLED")
        write(State(1, false, false))
    }

    fun finishSyntheticSeed(lease: Lease) {
        if (!lease.valid || lease.state.ready || read() != lease.state) throw FenceRejected("STATE_INVALID")
        write(lease.state.copy(ready = true))
    }

    fun freezeSynthetic() = locked { _, _ ->
        val current = read()
        if (current.frozen || !current.ready || current.epoch == Long.MAX_VALUE) throw FenceRejected("STATE_INVALID")
        write(current.copy(epoch = current.epoch + 1, frozen = true))
    }

    fun interruptSynthetic() = locked { _, _ ->
        read()
        if (!pending.createNewFile()) throw FenceRejected("INTERRUPTED_JOURNAL")
        syncDirectory()
        FileOutputStream(pending).use { stream -> stream.fd.sync() }
    }

    fun admit(expectedEpoch: Long? = null, syntheticSeed: Boolean = false): Lease = locked { file, lock ->
        val current = read()
        if (current.frozen) throw FenceRejected("FROZEN")
        if (current.ready == syntheticSeed) throw FenceRejected("SEED_PHASE_MISMATCH")
        if (expectedEpoch != null && current.epoch != expectedEpoch) throw FenceRejected("STALE_EPOCH")
        Lease(file, lock, current)
    }

    fun payload(epoch: Long): String = "fence21/${binding.namespace}/$epoch"
}

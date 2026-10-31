package au.interstellr.glassbridge.core

import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Uploads one file at a time to the iPhone (PROTOCOL.md section 5): `file_begin`, then
 * `file_chunk` frames of at most [chunkSize] bytes in order, then `file_end`, then waits up
 * to [ackTimeoutMs] for the matching `file_ack`.
 *
 * - [upload] blocks: call it from a worker thread, never the link thread (the ack arrives
 *   on the link thread through [handleFrame]) or the main thread.
 * - Uploads are serialized: a second [upload] waits for the first.
 * - The upload fails if the file's size changes while it's being sent (the file_end is then
 *   not sent), if the link drops, if [cancelAll] is called, or if no ack arrives in time
 *   ([Result.timedOut]).
 * - Only `ok:true` counts as success; the caller marks the file synced only then.
 * - Only a `file_ack` that arrives after this attempt's `file_end` counts: the iPhone acks at
 *   `file_end`, so an earlier one is a late answer to a previous attempt and is ignored.
 */
class Uploader @JvmOverloads constructor(
    private val sender: FrameSender,
    private val ackTimeoutMs: Long = DEFAULT_ACK_TIMEOUT_MS,
    private val chunkSize: Int = Limits.CHUNK
) {
    init {
        require(chunkSize in 1..Limits.CHUNK) { "chunkSize must be 1..${Limits.CHUNK}" }
    }

    /**
     * The outcome of one [upload]. [sha256] is the hex SHA-256 of the bytes sent (null if
     * not all were sent); [ack] is the `file_ack` object when one arrived. [timedOut] is true
     * when everything was sent but no `file_ack` came within the ack timeout.
     */
    class Result @JvmOverloads constructor(
        val id: String,
        val ok: Boolean,
        val error: String?,
        val bytesSent: Long,
        val sha256: String?,
        val ack: JSONObject?,
        val timedOut: Boolean = false
    ) {
        override fun toString(): String =
            if (ok) "Upload $id ok ($bytesSent bytes)" else "Upload $id failed: $error"
    }

    private class Waiter {
        val latch = CountDownLatch(1)
        @Volatile var ack: JSONObject? = null
        @Volatile var cancelled = false
        /** Set just before this attempt's `file_end` goes out; acks before that are ignored. */
        @Volatile var endSent = false
    }

    private val waiters = HashMap<String, Waiter>()
    private val uploadLock = Any()
    private val cancelGeneration = AtomicInteger(0)

    /** Uploads [file] and waits for its ack. See the class docs. */
    fun upload(file: File): Result = synchronized(uploadLock) { doUpload(file) }

    /**
     * Feed every frame (or just `file_ack` ones) from the link here. Returns true if it was
     * the ack an upload is waiting for. Safe from any thread; never blocks.
     */
    fun handleFrame(frame: Frame): Boolean =
        if (frame.type == MsgType.FILE_ACK) handleAck(frame.obj) else false

    /**
     * Delivers a `file_ack` object. Returns true if an upload has sent `file_end` for its id
     * and is waiting for it. An ack for an upload that hasn't reached `file_end` yet answers an
     * earlier attempt of the same file and is ignored (false).
     */
    fun handleAck(ack: JSONObject): Boolean {
        val id = Json.text(ack, "id") ?: return false
        val w = synchronized(waiters) { waiters[id] } ?: return false
        if (!w.endSent) {
            BridgeLog.w("file_ack for $id before its file_end (a late answer to an earlier attempt); ignored")
            return false
        }
        w.ack = ack
        w.latch.countDown()
        return true
    }

    /**
     * Fails the upload in progress (and any waiting for an ack) straight away. Call it when
     * the link drops. Uploads started afterwards run normally.
     */
    fun cancelAll() {
        cancelGeneration.incrementAndGet()
        val all = synchronized(waiters) { ArrayList(waiters.values) }
        for (w in all) {
            w.cancelled = true
            w.latch.countDown()
        }
    }

    private fun doUpload(file: File): Result {
        val name = file.name
        if (!file.isFile) return fail(idFor(name, 0), "file not found", 0)
        val size = file.length()
        val id = idFor(name, size)
        val mime = mimeFor(name) ?: return fail(id, "unsupported file type", 0)
        val taken = file.lastModified()
        val generation = cancelGeneration.get()
        val waiter = Waiter()
        synchronized(waiters) { waiters[id] = waiter }
        var sent = 0L
        try {
            BridgeLog.i("Upload $id: $size bytes, $mime")
            if (!sender.send(Msg.fileBegin(id, name, size, mime, taken))) return fail(id, "not connected", 0)
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buf = ByteArray(Math.max(1L, Math.min(chunkSize.toLong(), size)).toInt())
                while (sent < size) {
                    if (cancelGeneration.get() != generation) return fail(id, "cancelled", sent)
                    val want = Math.min(buf.size.toLong(), size - sent).toInt()
                    val n = readFully(input, buf, want)
                    if (n < want) return fail(id, "file changed during upload (shorter than $size bytes)", sent)
                    digest.update(buf, 0, n)
                    if (!sender.send(Msg.fileChunk(id, sent), buf, n)) return fail(id, "link dropped", sent)
                    sent += n
                }
                if (input.read() >= 0) return fail(id, "file changed during upload (longer than $size bytes)", sent)
            }
            if (file.length() != size) return fail(id, "file changed during upload", sent)
            if (cancelGeneration.get() != generation) return fail(id, "cancelled", sent)
            // Before the send: the ack can arrive on the link thread before send() returns.
            waiter.endSent = true
            if (!sender.send(Msg.fileEnd(id))) return fail(id, "link dropped", sent)
            val hex = toHex(digest.digest())
            val arrived = try {
                waiter.latch.await(ackTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return fail(id, "interrupted", sent)
            }
            if (waiter.cancelled) return fail(id, "cancelled (link dropped)", sent)
            if (!arrived) return fail(id, "no file_ack within " + (ackTimeoutMs / 1000) + " s", sent, timedOut = true)
            val ack = waiter.ack!!
            val ok = Json.bool(ack, "ok") == true
            val error = if (ok) null else (Json.str(ack, "error") ?: "the iPhone refused the file")
            val result = Result(id, ok, error, sent, hex, ack)
            BridgeLog.i(result.toString())
            return result
        } catch (e: IOException) {
            return fail(id, "read failed: $e", sent)
        } finally {
            synchronized(waiters) {
                if (waiters[id] === waiter) waiters.remove(id)
            }
        }
    }

    private fun fail(id: String, error: String, sent: Long, timedOut: Boolean = false): Result {
        BridgeLog.w("Upload $id failed: $error")
        return Result(id, false, error, sent, null, null, timedOut)
    }

    companion object {
        const val DEFAULT_ACK_TIMEOUT_MS = 60_000L

        /** `<name>:<size>`, stable across retries. */
        @JvmStatic
        fun idFor(name: String, size: Long): String = "$name:$size"

        @JvmStatic
        fun idFor(file: File): String = idFor(file.name, file.length())

        /** MIME type by extension (.jpg/.jpeg, .png, .mp4, .3gp), or null for anything else. */
        @JvmStatic
        fun mimeFor(name: String): String? {
            val dot = name.lastIndexOf('.')
            if (dot < 0 || dot == name.length - 1) return null
            return when (name.substring(dot + 1).lowercase()) {
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "mp4" -> "video/mp4"
                "3gp" -> "video/3gpp"
                else -> null
            }
        }

        @JvmStatic
        fun toHex(bytes: ByteArray): String {
            val hex = "0123456789abcdef"
            val sb = StringBuilder(bytes.size * 2)
            for (b in bytes) {
                val v = b.toInt() and 0xFF
                sb.append(hex[v ushr 4]).append(hex[v and 0x0F])
            }
            return sb.toString()
        }

        private fun readFully(input: InputStream, buf: ByteArray, want: Int): Int {
            var off = 0
            while (off < want) {
                val n = input.read(buf, off, want - off)
                if (n < 0) break
                off += n
            }
            return off
        }
    }
}

/**
 * Which files in DCIM/Camera MediaSync uploads (Glass app spec, Media sync).
 */
object MediaRules {
    /** Skip files modified this recently: a video may still be recording. */
    const val QUIET_MS = 3_000L

    /** SharedPreferences file and key for the synced `<name>:<size>` ids. */
    const val PREFS = "media_sync"
    const val KEY_SYNCED_IDS = "synced_ids"

    /** True if a file should be uploaded: not a dotfile, not empty, a known type, and quiet for [QUIET_MS]. */
    @JvmStatic
    fun isCandidate(name: String, size: Long, lastModified: Long, now: Long): Boolean =
        !name.startsWith(".") && size > 0 && Uploader.mimeFor(name) != null && now - lastModified >= QUIET_MS

    /**
     * The files to upload now, oldest first: candidates whose id isn't in [synced].
     */
    @JvmStatic
    fun pending(files: List<File>, synced: Set<String>, now: Long): List<File> {
        val out = ArrayList<File>()
        for (f in files) {
            if (!f.isFile) continue
            val size = f.length()
            if (!isCandidate(f.name, size, f.lastModified(), now)) continue
            if (synced.contains(Uploader.idFor(f.name, size))) continue
            out.add(f)
        }
        // Oldest first; ties by name so the order is stable.
        java.util.Collections.sort(out, Comparator { a, b ->
            val c = a.lastModified().compareTo(b.lastModified())
            if (c != 0) c else a.name.compareTo(b.name)
        })
        return out
    }

    /** What MediaSync does with a file after one [Uploader.upload]. */
    enum class Next {
        /** `file_ack ok:true`: mark it synced for good. */
        SYNCED,

        /**
         * The iPhone answered `ok:false`, or sent no `file_ack` within the timeout: not synced.
         * Skip it until sync is next turned on (the next session, PROTOCOL.md section 5
         * `file_ack`) and carry on with newer files, so one file can't block the rest.
         */
        NEXT_SESSION,

        /** Link dropped, cancelled, not connected, or a local problem: stop and try at the next scan. */
        NEXT_SCAN
    }

    @JvmStatic
    fun next(r: Uploader.Result): Next = when {
        r.ok -> Next.SYNCED
        r.ack != null || r.timedOut -> Next.NEXT_SESSION
        else -> Next.NEXT_SCAN
    }

    /** Longest wait [nextCheckDelayMs] returns (a file dated in the future is checked again then). */
    const val MAX_RECHECK_MS = 60_000L

    /**
     * How long until an unsynced file that is skipped only because it was modified in the
     * last [QUIET_MS] becomes a candidate (scan again then), or null if there's no such file.
     * Capped at [MAX_RECHECK_MS].
     */
    @JvmStatic
    fun nextCheckDelayMs(files: List<File>, synced: Set<String>, now: Long): Long? {
        var best: Long? = null
        for (f in files) {
            if (!f.isFile) continue
            val name = f.name
            val size = f.length()
            if (name.startsWith(".") || size <= 0 || Uploader.mimeFor(name) == null) continue
            if (synced.contains(Uploader.idFor(name, size))) continue
            val age = now - f.lastModified()
            if (age >= QUIET_MS) continue
            val wait = Math.min(QUIET_MS - age, MAX_RECHECK_MS)
            if (best == null || wait < best) best = wait
        }
        return best
    }
}

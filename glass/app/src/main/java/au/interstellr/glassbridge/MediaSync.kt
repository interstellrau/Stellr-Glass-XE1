@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.os.Environment
import android.os.FileObserver
import android.os.PowerManager
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.MediaRules
import au.interstellr.glassbridge.core.SyncedRecord
import au.interstellr.glassbridge.core.Uploader
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Uploads new shots from DCIM/Camera (brief "Media sync").
 *
 * - A FileObserver (CLOSE_WRITE | MOVED_TO) on DCIM/Camera, held in a field (a
 *   garbage-collected observer silently stops firing).
 * - One scan at a time on a single worker thread, oldest file first; dotfiles, empty files,
 *   unknown types and files modified in the last 3 s are skipped ([MediaRules]). A file still
 *   inside that 3 s window gets a re-scan when it leaves it.
 * - A file counts as synced only on `file_ack ok:true`; synced `<name>:<size>` ids live in
 *   SharedPreferences `media_sync` / `synced_ids` ([SyncedRecord]). A file the iPhone refuses
 *   (`ok:false`) or doesn't ack within 60 s is retried next session (PROTOCOL.md section 5),
 *   not in this one.
 * - A new pairing ([forgetSynced]) forgets the synced ids, so a phone paired after another one
 *   (fake_phone, then the iPhone) gets the whole backlog.
 * - A partial wake lock is held while a scan uploads, so an upload that starts with the screen
 *   on (or from the 60 s alarm) isn't frozen half way when Glass goes to sleep.
 * - Nothing uploads until `sync {enabled:true}`. When the link drops, BridgeService calls
 *   [setEnabled] (false), which also cancels the upload in flight. The phone re-sends `sync`
 *   on every connect, which triggers a scan, as does the periodic [rescan] (a safety net in
 *   case the observer misses events on emulated storage).
 */
class MediaSync(context: Context, private val uploader: Uploader) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(MediaRules.PREFS, Context.MODE_PRIVATE)
    private val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Camera")
    private val wakeLock: PowerManager.WakeLock? = try {
        (context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GlassBridge:media")
            .apply { setReferenceCounted(false) }
    } catch (e: RuntimeException) {
        BridgeLog.w("No media wake lock: $e")
        null
    }
    private val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "GlassBridge-media").apply { isDaemon = true }
    }
    private val lock = Any()
    private var pendingScan: ScheduledFuture<*>? = null // guarded by lock
    private val record = SyncedRecord(object : SyncedRecord.Store {
        override fun load(): Set<String>? = prefs.getStringSet(MediaRules.KEY_SYNCED_IDS, null)

        override fun save(ids: Set<String>) {
            prefs.edit().putStringSet(MediaRules.KEY_SYNCED_IDS, ids).apply()
        }

        // commit(): the reset must be on disk before BridgeService saves the new token.
        @SuppressLint("ApplySharedPref")
        override fun clear() {
            prefs.edit().remove(MediaRules.KEY_SYNCED_IDS).commit()
        }
    })

    /** Held in a field on purpose: see the class docs. Guarded by [lock]. */
    private var observer: FileObserver? = null

    @Volatile
    var enabled = false
        private set

    fun start() {
        startObserver()
    }

    fun stop() {
        enabled = false
        uploader.cancelAll()
        synchronized(lock) {
            observer?.stopWatching()
            observer = null
        }
        worker.shutdownNow()
    }

    /** `sync {enabled}`; false also cancels the upload in flight. Any thread. */
    fun setEnabled(on: Boolean) {
        val was = enabled
        enabled = on
        if (on) {
            if (!was) {
                BridgeLog.i("Media sync on (watching ${dir.path})")
                synchronized(lock) { refusedThisSession.clear() }
            }
            startObserver()
            schedule(0L)
        } else {
            if (was) BridgeLog.i("Media sync off")
            synchronized(lock) {
                pendingScan?.cancel(false)
                pendingScan = null
            }
            uploader.cancelAll()
        }
    }

    /** Scans again if sync is on (BridgeService calls this every 60 s). */
    fun rescan() {
        if (enabled) schedule(0L)
    }

    /**
     * Forgets every synced id so the phone Glass has just paired with gets the whole backlog
     * (BridgeService, on a `welcome` with a new `pair_token`, on the link thread before that
     * session's `sync` arrives). Returns how many were forgotten; the reset is on disk when this
     * returns. A scan from the previous session that is still finishing can't write the old ids
     * back ([SyncedRecord]); it stops, and the next scan starts from the empty record.
     */
    fun forgetSynced(): Int {
        val n = record.forgetAll()
        rescan()
        return n
    }

    /** Main thread (start) or link thread (sync): hence the lock. */
    private fun startObserver() {
        synchronized(lock) { startObserverLocked() }
    }

    private fun startObserverLocked() {
        if (observer != null) return
        if (!dir.isDirectory) {
            BridgeLog.w("${dir.path} doesn't exist yet; scanning on each sync instead")
            return
        }
        val o = object : FileObserver(dir.path, FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == null || path.startsWith(".")) return
                BridgeLog.d("DCIM/Camera: $path written")
                // Wait out the quiet period before looking at it.
                if (enabled) schedule(MediaRules.QUIET_MS + 250L)
            }
        }
        o.startWatching()
        observer = o
        BridgeLog.i("Watching ${dir.path}")
    }

    private fun schedule(delayMs: Long) {
        synchronized(lock) {
            val p = pendingScan
            // Keep an earlier scan that's still waiting; replace a later one.
            if (p != null && !p.isDone && p.getDelay(TimeUnit.MILLISECONDS) <= delayMs) return
            p?.cancel(false)
            pendingScan = try {
                worker.schedule(Runnable { scan() }, delayMs, TimeUnit.MILLISECONDS)
            } catch (e: java.util.concurrent.RejectedExecutionException) {
                null
            }
        }
    }

    /** Runs on the worker thread only, so scans never overlap. */
    private fun scan() {
        synchronized(lock) { pendingScan = null }
        if (!enabled) return
        val files = dir.listFiles()?.toList() ?: emptyList()
        val snap = record.snapshot() // a copy, with the record's generation
        val skip = HashSet(snap.ids)
        synchronized(lock) { skip.addAll(refusedThisSession) }
        val todo = MediaRules.pending(files, skip, System.currentTimeMillis())
        if (todo.isNotEmpty()) BridgeLog.i("Media sync: ${todo.size} file(s) to upload")
        try {
            for (f in todo) {
                // Sync off (the link dropped), or a new pairing forgot the ids this scan started from.
                if (!enabled || !record.isCurrent(snap)) return
                holdWakeLock()
                val r = uploader.upload(f)
                when (MediaRules.next(r)) {
                    MediaRules.Next.SYNCED -> {
                        skip.add(r.id)
                        if (!record.markSynced(snap, r.id)) {
                            BridgeLog.i("Synced ${r.id} to the previous phone; not recorded (new pairing)")
                            return
                        }
                        BridgeLog.i("Synced ${r.id}")
                    }
                    MediaRules.Next.NEXT_SESSION -> {
                        // ok:false, or no file_ack within 60 s. Not synced; try it again next
                        // session (not this one, so a slow save on the iPhone can't end up in
                        // Photos twice), and carry on with newer files.
                        BridgeLog.w("Upload ${r.id} not synced (${r.error}); retrying it next session")
                        synchronized(lock) { refusedThisSession.add(r.id) }
                        skip.add(r.id)
                    }
                    MediaRules.Next.NEXT_SCAN -> {
                        // Link trouble or cancelled: leave the rest for the next scan.
                        BridgeLog.w("Upload ${r.id} failed (${r.error}); will retry later")
                        return
                    }
                }
            }
        } finally {
            releaseWakeLock()
        }
        if (!enabled || !record.isCurrent(snap)) return
        val again = MediaRules.nextCheckDelayMs(dir.listFiles()?.toList() ?: emptyList(), skip, System.currentTimeMillis())
        if (again != null) schedule(again + 250L)
    }

    /** Keeps the CPU awake for the next upload (timed, in case a release is ever missed). */
    private fun holdWakeLock() {
        try {
            wakeLock?.acquire(UPLOAD_WAKE_MS)
        } catch (e: RuntimeException) {
            BridgeLog.w("Media wake lock failed: $e")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: RuntimeException) {
            BridgeLog.w("Media wake lock release failed: $e")
        }
    }

    /**
     * Ids not synced this session that wait for the next one: the iPhone answered ok:false, or
     * sent no file_ack in time. Cleared when sync is turned on again. Guarded by [lock].
     */
    private val refusedThisSession = HashSet<String>()

    companion object {
        /** Longest one upload may hold the CPU awake: generous for a long video plus the 60 s ack wait. */
        const val UPLOAD_WAKE_MS = 10 * 60_000L
    }
}

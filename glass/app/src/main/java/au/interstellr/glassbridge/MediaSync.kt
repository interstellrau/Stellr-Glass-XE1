@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.content.Context
import android.content.SharedPreferences
import android.os.Environment
import android.os.FileObserver
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.MediaRules
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
 *   SharedPreferences `media_sync` / `synced_ids`.
 * - Nothing uploads until `sync {enabled:true}`. When the link drops, BridgeService calls
 *   [setEnabled] (false), which also cancels the upload in flight. The phone re-sends `sync`
 *   on every connect, which triggers a scan, as does the periodic [rescan] (a safety net in
 *   case the observer misses events on emulated storage).
 */
class MediaSync(context: Context, private val uploader: Uploader) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(MediaRules.PREFS, Context.MODE_PRIVATE)
    private val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Camera")
    private val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "GlassBridge-media").apply { isDaemon = true }
    }
    private val lock = Any()
    private var pendingScan: ScheduledFuture<*>? = null // guarded by lock

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
        // Copy: the set SharedPreferences returns must not be modified.
        val synced = HashSet(prefs.getStringSet(MediaRules.KEY_SYNCED_IDS, emptySet()) ?: emptySet())
        val skip = HashSet(synced)
        synchronized(lock) { skip.addAll(refusedThisSession) }
        val todo = MediaRules.pending(files, skip, System.currentTimeMillis())
        if (todo.isNotEmpty()) BridgeLog.i("Media sync: ${todo.size} file(s) to upload")
        for (f in todo) {
            if (!enabled) return
            val r = uploader.upload(f)
            if (r.ok) {
                synced.add(r.id)
                skip.add(r.id)
                prefs.edit().putStringSet(MediaRules.KEY_SYNCED_IDS, HashSet(synced)).apply()
                BridgeLog.i("Synced ${r.id}")
            } else if (r.ack != null) {
                // The iPhone answered ok:false. Not synced; try it again next session, and
                // carry on with newer files so one bad file can't block the rest.
                BridgeLog.w("iPhone refused ${r.id}: ${r.error}; retrying it next session")
                synchronized(lock) { refusedThisSession.add(r.id) }
                skip.add(r.id)
            } else {
                // Link trouble, cancel or timeout: leave the rest for the next scan.
                BridgeLog.w("Upload ${r.id} failed (${r.error}); will retry later")
                return
            }
        }
        if (!enabled) return
        val again = MediaRules.nextCheckDelayMs(dir.listFiles()?.toList() ?: emptyList(), skip, System.currentTimeMillis())
        if (again != null) schedule(again + 250L)
    }

    /** Ids the iPhone answered ok:false for since sync was last turned on. Guarded by [lock]. */
    private val refusedThisSession = HashSet<String>()
}

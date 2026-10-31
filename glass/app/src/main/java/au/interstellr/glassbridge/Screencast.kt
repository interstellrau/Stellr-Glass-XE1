package au.interstellr.glassbridge

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import au.interstellr.glassbridge.core.BridgeConnection
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Msg
import au.interstellr.glassbridge.core.ScreencastCmd
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Sends GlassBridge's own window to the iPhone as JPEG frames (brief "Screencast"). KitKat
 * has no screen-capture API for apps, so the activity's decorView is drawn into a reused
 * RGB_565 bitmap and compressed at quality 60.
 *
 * Runs on the main thread at 1-5 fps, only while screencast is on and the card screen is in
 * front ([attach]ed between onResume and onPause). A frame is dropped if the previous one is
 * still being sent. Main thread only.
 */
object Screencast {
    const val JPEG_QUALITY = 60

    /** The link frames go out on; set by BridgeService. */
    @Volatile
    @JvmStatic
    var sender: BridgeConnection? = null

    private val main = Handler(Looper.getMainLooper())
    private var on = false
    private var intervalMs = 1000L / ScreencastCmd.DEFAULT_FPS
    /** The card screen while it's in front (weak, so a missed detach can't leak it). */
    private var activityRef: WeakReference<Activity>? = null
    private val activity: Activity? get() = activityRef?.get()
    private var bitmap: Bitmap? = null
    private var canvas: Canvas? = null
    private val jpeg = ByteArrayOutputStream(64 * 1024)
    private val sending = AtomicBoolean(false)
    private val sent = AtomicLong()
    private val dropped = AtomicLong()

    private val tick = object : Runnable {
        override fun run() {
            capture()
            if (on && activity != null) main.postDelayed(this, intervalMs)
        }
    }

    val isOn: Boolean get() = on

    /** A `screencast` command (or off when the link drops). */
    @JvmStatic
    fun configure(enable: Boolean, fps: Int) {
        val f = Math.max(ScreencastCmd.MIN_FPS, Math.min(ScreencastCmd.MAX_FPS, fps))
        if (enable != on || 1000L / f != intervalMs) {
            BridgeLog.i(if (enable) "Screencast on at $f fps" + (if (activity == null) " (frames start when the card screen is in front)" else "")
            else "Screencast off (${sent.get()} sent, ${dropped.get()} dropped)")
        }
        if (enable && !on) {
            sent.set(0)
            dropped.set(0)
        }
        on = enable
        intervalMs = 1000L / f
        reschedule()
        if (!on) releaseBitmap()
    }

    @JvmStatic
    fun attach(a: Activity) {
        activityRef = WeakReference(a)
        reschedule()
    }

    @JvmStatic
    fun detach(a: Activity) {
        if (activity === a) activityRef = null
        main.removeCallbacks(tick)
        releaseBitmap()
    }

    private fun reschedule() {
        main.removeCallbacks(tick)
        if (on && activity != null) main.postDelayed(tick, intervalMs)
    }

    private fun capture() {
        val a = activity ?: return
        val conn = sender ?: return
        if (!on || !MainActivity.visible) return
        if (!conn.isAccepted) return
        if (!sending.compareAndSet(false, true)) {
            dropped.incrementAndGet()
            return
        }
        var handedOff = false
        try {
            val decor = a.window?.decorView ?: return
            val w = decor.width
            val h = decor.height
            if (w <= 0 || h <= 0) return
            var bmp = bitmap
            if (bmp == null || bmp.width != w || bmp.height != h) {
                bmp?.recycle()
                bmp = Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565)
                bitmap = bmp
                canvas = Canvas(bmp)
            }
            val c = canvas ?: return
            decor.draw(c)
            jpeg.reset()
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, jpeg)) return
            val bytes = jpeg.toByteArray()
            handedOff = true
            conn.sendAsync(Msg.frame(w, h), bytes) { ok ->
                sending.set(false)
                if (ok) sent.incrementAndGet() else dropped.incrementAndGet()
            }
        } catch (t: Throwable) {
            BridgeLog.w("Screencast frame failed: $t")
        } finally {
            if (!handedOff) sending.set(false)
        }
    }

    private fun releaseBitmap() {
        // Only once nothing is drawing into it (main thread) and it isn't being compressed.
        canvas = null
        bitmap?.recycle()
        bitmap = null
    }
}

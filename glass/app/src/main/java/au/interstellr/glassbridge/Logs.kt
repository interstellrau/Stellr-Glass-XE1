@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.TouchpadGestures
import java.util.Locale

/**
 * Routes core's [BridgeLog] to logcat under tag "GlassBridge". tools/glass_adb.py `logs`
 * filters on that tag and on [InputLog.TAG].
 */
object Logs {
    @Volatile
    private var installed = false

    /** Idempotent; called from BridgeService.onCreate and MainActivity.onCreate. */
    @JvmStatic
    fun install() {
        if (installed) return
        installed = true
        BridgeLog.sink = object : BridgeLog.Sink {
            override fun log(priority: Int, tag: String, message: String, error: Throwable?) {
                Log.println(priority, tag, if (error == null) message else message + "\n" + Log.getStackTraceString(error))
            }
        }
    }
}

/**
 * Every key event and every generic motion event the card screen receives, logged under tag
 * "GlassBridgeInput" (CLAUDE.md owner decision 4), so real hardware can settle which way a
 * swipe goes and how a tap arrives (open questions 4 and 5).
 */
object InputLog {
    const val TAG = "GlassBridgeInput"

    @JvmStatic
    fun key(e: KeyEvent, where: String) {
        val action = when (e.action) {
            KeyEvent.ACTION_DOWN -> "DOWN"
            KeyEvent.ACTION_UP -> "UP"
            KeyEvent.ACTION_MULTIPLE -> "MULTIPLE"
            else -> e.action.toString()
        }
        Log.i(
            TAG,
            String.format(
                Locale.US,
                "key %s %s (%d) source=%s repeat=%d meta=0x%x scan=%d device=%d flags=0x%x t=%d [%s]",
                action, KeyEvent.keyCodeToString(e.keyCode), e.keyCode, source(e.source), e.repeatCount,
                e.metaState, e.scanCode, e.deviceId, e.flags, e.eventTime, where
            )
        )
    }

    @JvmStatic
    fun motion(e: MotionEvent, path: String) {
        val masked = e.actionMasked
        val line = String.format(
            Locale.US,
            "%s %s x=%.1f y=%.1f source=%s pointers=%d device=%d t=%d",
            path, actionName(masked), e.x, e.y, source(e.source), e.pointerCount, e.deviceId, e.eventTime
        )
        // MOVE and HOVER_MOVE arrive many times a second: debug level; the rest at info.
        if (masked == MotionEvent.ACTION_MOVE || masked == MotionEvent.ACTION_HOVER_MOVE) Log.d(TAG, line) else Log.i(TAG, line)
    }

    @JvmStatic
    fun gesture(r: TouchpadGestures.Result, invertSwipe: Boolean, action: String) {
        Log.i(TAG, "gesture $r invert_swipe=$invertSwipe -> $action")
    }

    @JvmStatic
    fun note(message: String) {
        Log.i(TAG, message)
    }

    @JvmStatic
    fun actionName(masked: Int): String = when (masked) {
        MotionEvent.ACTION_DOWN -> "DOWN"
        MotionEvent.ACTION_UP -> "UP"
        MotionEvent.ACTION_MOVE -> "MOVE"
        MotionEvent.ACTION_CANCEL -> "CANCEL"
        MotionEvent.ACTION_OUTSIDE -> "OUTSIDE"
        MotionEvent.ACTION_POINTER_DOWN -> "POINTER_DOWN"
        MotionEvent.ACTION_POINTER_UP -> "POINTER_UP"
        MotionEvent.ACTION_HOVER_MOVE -> "HOVER_MOVE"
        MotionEvent.ACTION_SCROLL -> "SCROLL"
        MotionEvent.ACTION_HOVER_ENTER -> "HOVER_ENTER"
        MotionEvent.ACTION_HOVER_EXIT -> "HOVER_EXIT"
        else -> masked.toString()
    }

    /** "0x00100008 touchpad" style: the raw bits plus the names of the classes they match. */
    @JvmStatic
    fun source(s: Int): String {
        val names = ArrayList<String>()
        if (has(s, InputDevice.SOURCE_TOUCHPAD)) names.add("touchpad")
        if (has(s, InputDevice.SOURCE_TOUCH_NAVIGATION)) names.add("touch_navigation")
        if (has(s, InputDevice.SOURCE_TOUCHSCREEN)) names.add("touchscreen")
        if (has(s, InputDevice.SOURCE_MOUSE)) names.add("mouse")
        if (has(s, InputDevice.SOURCE_STYLUS)) names.add("stylus")
        if (has(s, InputDevice.SOURCE_TRACKBALL)) names.add("trackball")
        if (has(s, InputDevice.SOURCE_JOYSTICK)) names.add("joystick")
        if (has(s, InputDevice.SOURCE_GAMEPAD)) names.add("gamepad")
        if (has(s, InputDevice.SOURCE_DPAD)) names.add("dpad")
        if (has(s, InputDevice.SOURCE_KEYBOARD)) names.add("keyboard")
        return String.format(Locale.US, "0x%08x", s) + if (names.isEmpty()) "" else " " + names.joinToString("+")
    }

    private fun has(s: Int, src: Int): Boolean = (s and src) == src
}

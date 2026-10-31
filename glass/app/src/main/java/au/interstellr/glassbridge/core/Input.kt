package au.interstellr.glassbridge.core

/**
 * Input rules for the card screen (brief "Card stack UI › Input", CLAUDE.md owner decision 4).
 * Platform-free so they run in JVM tests; MainActivity feeds them Android events.
 */
object InputRules {
    /** A touchpad move of more than this (ACTION_DOWN x to ACTION_UP x) is a swipe. */
    const val SWIPE_MIN_PX = 120f

    /** A touchpad tap moves at most this far in x and in y between down and up... */
    const val TAP_MAX_MOVE_PX = 30f

    /** ...and lasts less than this. */
    const val TAP_MAX_MS = 300L

    /** A downward touchpad move of at least this (and mostly vertical) is "swipe down" (leave). */
    const val DOWN_SWIPE_MIN_PX = 80f

    /** Tap actions closer together than this are one physical tap arriving two ways. */
    const val TAP_DEBOUNCE_MS = 400L

    /** A card move from a different input source within this window is the same swipe. */
    const val MOVE_DEDUPE_MS = 400L
}

/**
 * Classifies one touchpad gesture from its ACTION_DOWN and ACTION_UP positions.
 *
 * - |dx| > [swipeMinPx]: a swipe. Positive dx is [Kind.FORWARD] (an older card), unless
 *   `invert` (config.json `invert_swipe`) flips it.
 * - Otherwise dy >= [downSwipeMinPx] and dy > 2|dx|: [Kind.DOWN] (leave the screen; Glass
 *   normally also sends KEYCODE_BACK for this).
 * - Otherwise |dx| <= [tapMaxMovePx], |dy| <= [tapMaxMovePx] and the gesture took less than
 *   [tapMaxMs]: [Kind.TAP].
 * - Anything else: [Kind.NONE].
 *
 * Not thread-safe; the activity uses it on the main thread.
 */
class TouchpadGestures @JvmOverloads constructor(
    val swipeMinPx: Float = InputRules.SWIPE_MIN_PX,
    val tapMaxMovePx: Float = InputRules.TAP_MAX_MOVE_PX,
    val tapMaxMs: Long = InputRules.TAP_MAX_MS,
    val downSwipeMinPx: Float = InputRules.DOWN_SWIPE_MIN_PX
) {
    enum class Kind { NONE, TAP, FORWARD, BACKWARD, DOWN }

    class Result(val kind: Kind, val dx: Float, val dy: Float, val durationMs: Long) {
        override fun toString(): String =
            "$kind dx=${Math.round(dx)} dy=${Math.round(dy)} ${durationMs}ms"
    }

    private var active = false
    private var downX = 0f
    private var downY = 0f
    private var downT = 0L

    /** True between [down] and [up]/[cancel]. */
    val isActive: Boolean get() = active

    fun down(x: Float, y: Float, timeMs: Long) {
        active = true
        downX = x
        downY = y
        downT = timeMs
    }

    /** Ends the gesture. [invert] flips the swipe direction. An [up] without a [down] is NONE. */
    fun up(x: Float, y: Float, timeMs: Long, invert: Boolean): Result {
        if (!active) return Result(Kind.NONE, 0f, 0f, 0L)
        active = false
        val dx = x - downX
        val dy = y - downY
        val duration = timeMs - downT
        val adx = Math.abs(dx)
        val ady = Math.abs(dy)
        val kind = when {
            adx > swipeMinPx -> if ((dx > 0) != invert) Kind.FORWARD else Kind.BACKWARD
            dy >= downSwipeMinPx && dy > 2 * adx -> Kind.DOWN
            adx <= tapMaxMovePx && ady <= tapMaxMovePx && duration in 0 until tapMaxMs -> Kind.TAP
            else -> Kind.NONE
        }
        return Result(kind, dx, dy, duration)
    }

    fun cancel() {
        active = false
    }
}

/**
 * Accepts an action at most once per [windowMs] (owner decision 4: one physical tap that
 * arrives as both a key and a touchpad gesture only acts once). Rejected calls don't extend
 * the window.
 */
class Debouncer(val windowMs: Long) {
    private var hasLast = false
    private var last = 0L

    fun accept(nowMs: Long): Boolean {
        if (hasLast && nowMs - last >= 0 && nowMs - last < windowMs) return false
        hasLast = true
        last = nowMs
        return true
    }
}

/**
 * Drops a card move that arrives from a different input source within [windowMs] of the last
 * accepted one (a swipe that Glass delivers both as a touchpad gesture and as a TAB or DPAD
 * key). Repeated moves from the same source always pass, so fast repeated swipes still work.
 */
class SourceDeduper(val windowMs: Long) {
    private var lastSource: String? = null
    private var last = 0L

    fun accept(source: String, nowMs: Long): Boolean {
        val prev = lastSource
        if (prev != null && prev != source && nowMs - last >= 0 && nowMs - last < windowMs) return false
        lastSource = source
        last = nowMs
        return true
    }
}

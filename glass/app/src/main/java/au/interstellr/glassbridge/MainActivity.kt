package au.interstellr.glassbridge

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.text.TextUtils
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Card
import au.interstellr.glassbridge.core.Debouncer
import au.interstellr.glassbridge.core.Deck
import au.interstellr.glassbridge.core.GlassConfig
import au.interstellr.glassbridge.core.InputRules
import au.interstellr.glassbridge.core.LinkStatus
import au.interstellr.glassbridge.core.Msg
import au.interstellr.glassbridge.core.NavState
import au.interstellr.glassbridge.core.SourceDeduper
import au.interstellr.glassbridge.core.TouchpadGestures
import java.io.File
import java.util.Date

/**
 * The card stack on the 640x360 display (brief "Card stack UI").
 *
 * Built in code with px sizes, like the GDK's cards: black background, 40 px side margins,
 * title 30 px grey (#9E9E9E) on one line, body 44 px white (4 lines max), footer 24 px grey
 * with link state (empty screen) or source and time (cards) on the left and a "2/5" pager on
 * the right. All text sans-serif-light. The nav card is pinned at the front: a 170 px
 * [ManeuverView] on the left, the distance at 64 px and the instruction at 32 px (3 lines) on
 * the right, ETA and remaining distance in the footer. The footer turns amber (#FFB300)
 * whenever the iPhone isn't linked.
 *
 * Input (every event is logged under tag GlassBridgeInput):
 * - tap = KEYCODE_DPAD_CENTER, KEYCODE_ENTER or a touchpad tap, debounced 400 ms across all
 *   three: dismisses the current card and sends `ack dismissed` (a notification card first
 *   sends `ack tapped`);
 * - touchpad swipe (|dx| > 120 px between ACTION_DOWN and ACTION_UP): positive dx = forward =
 *   an older card, flipped by config.json `invert_swipe`;
 * - DPAD right / Tab = older card, DPAD left / Shift-Tab = newer card;
 * - swipe down (KEYCODE_BACK, or a downward touchpad swipe) leaves the screen.
 *
 * The touchpad is read from generic motion events (SOURCE_TOUCHPAD), with ordinary touch
 * events handled the same way as a fallback in case XE24 delivers it that way instead.
 */
class MainActivity : Activity(), GlassState.Listener {

    companion object {
        /** True while the card screen is in front (onResume to onPause). */
        @Volatile
        @JvmStatic
        var visible = false
            private set

        const val SIDE_MARGIN_PX = 40
        const val TOP_PADDING_PX = 26
        const val BOTTOM_PADDING_PX = 18
        const val TITLE_PX = 30f
        const val BODY_PX = 44f
        const val FOOTER_PX = 24f
        const val NAV_DISTANCE_PX = 64f
        const val NAV_INSTRUCTION_PX = 32f
        const val NAV_GAP_PX = 30

        val GREY = Color.parseColor("#9E9E9E")
        val AMBER = Color.parseColor("#FFB300")
    }

    private val light: Typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)

    private lateinit var textPage: LinearLayout
    private lateinit var titleView: TextView
    private lateinit var bodyView: TextView
    private lateinit var navPage: LinearLayout
    private lateinit var maneuverView: ManeuverView
    private lateinit var distanceView: TextView
    private lateinit var instructionView: TextView
    private lateinit var footerLeft: TextView
    private lateinit var pagerView: TextView

    private var keys: List<String> = emptyList()
    private var currentKey: String? = null
    private var currentIndex = 0
    private var invertSwipe = false

    private val gestures = TouchpadGestures()
    private val tapDebounce = Debouncer(InputRules.TAP_DEBOUNCE_MS)
    private val moveDedupe = SourceDeduper(InputRules.MOVE_DEDUPE_MS)

    // ----- lifecycle --------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Logs.install()
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
        setContentView(buildViews())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        visible = true
        // Starts the service, or (if it's running) re-reads wifi.json, re-checks mock GPS and
        // skips the reconnect wait: opening the card screen is as good as `glass_adb.py start`.
        BridgeService.start(this)
        loadConfig()
        GlassState.addListener(this)
        GlassState.prune(System.currentTimeMillis())
        render()
        Screencast.attach(this)
    }

    override fun onPause() {
        visible = false
        Screencast.detach(this)
        GlassState.removeListener(this)
        super.onPause()
    }

    override fun onGlassStateChanged() {
        if (visible) render()
    }

    /** config.json is read every time the card screen opens (PROTOCOL.md section 8). */
    private fun loadConfig() {
        val dir = getExternalFilesDir(null)
        val cfg = if (dir != null) GlassConfig.load(File(dir, GlassConfig.FILE_NAME)) else GlassConfig.DEFAULT
        if (cfg.invertSwipe != invertSwipe) BridgeLog.i("invert_swipe is now ${cfg.invertSwipe}")
        invertSwipe = cfg.invertSwipe
        InputLog.note("card screen opened: invert_swipe=$invertSwipe (positive dx = " +
            (if (invertSwipe) "newer" else "older") + " card)")
    }

    // ----- views ------------------------------------------------------------------------

    private fun buildViews(): View {
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.BLACK)
        root.setPadding(SIDE_MARGIN_PX, TOP_PADDING_PX, SIDE_MARGIN_PX, BOTTOM_PADDING_PX)
        root.isSoundEffectsEnabled = false

        val content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        // Text card: title and body.
        textPage = LinearLayout(this)
        textPage.orientation = LinearLayout.VERTICAL
        titleView = text(TITLE_PX, GREY).apply {
            setSingleLine(true)
            ellipsize = TextUtils.TruncateAt.END
        }
        bodyView = text(BODY_PX, Color.WHITE).apply {
            maxLines = 4
            ellipsize = TextUtils.TruncateAt.END
        }
        textPage.addView(titleView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        textPage.addView(bodyView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        content.addView(textPage, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        // Nav card: arrow on the left, distance and instruction on the right.
        navPage = LinearLayout(this)
        navPage.orientation = LinearLayout.HORIZONTAL
        navPage.gravity = Gravity.CENTER_VERTICAL
        maneuverView = ManeuverView(this)
        navPage.addView(maneuverView, LinearLayout.LayoutParams(ManeuverView.SIZE_PX, ManeuverView.SIZE_PX))
        val right = LinearLayout(this)
        right.orientation = LinearLayout.VERTICAL
        distanceView = text(NAV_DISTANCE_PX, Color.WHITE).apply {
            setSingleLine(true)
            ellipsize = TextUtils.TruncateAt.END
        }
        instructionView = text(NAV_INSTRUCTION_PX, Color.WHITE).apply {
            maxLines = 3
            ellipsize = TextUtils.TruncateAt.END
        }
        right.addView(distanceView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        right.addView(instructionView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        val rightParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        rightParams.leftMargin = NAV_GAP_PX
        navPage.addView(right, rightParams)
        navPage.visibility = View.GONE
        content.addView(navPage, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        // Footer: link state or source and time on the left, pager on the right.
        val footer = LinearLayout(this)
        footer.orientation = LinearLayout.HORIZONTAL
        footer.gravity = Gravity.CENTER_VERTICAL
        footerLeft = text(FOOTER_PX, GREY).apply {
            setSingleLine(true)
            ellipsize = TextUtils.TruncateAt.END
        }
        pagerView = text(FOOTER_PX, GREY).apply {
            setSingleLine(true)
            gravity = Gravity.END
        }
        footer.addView(footerLeft, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val pagerParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        pagerParams.leftMargin = 16
        footer.addView(pagerView, pagerParams)
        root.addView(footer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        return root
    }

    private fun text(px: Float, color: Int): TextView {
        val t = TextView(this)
        t.setTextSize(TypedValue.COMPLEX_UNIT_PX, px)
        t.setTextColor(color)
        t.typeface = light
        t.includeFontPadding = true
        t.isFocusable = false
        t.isSoundEffectsEnabled = false
        return t
    }

    // ----- rendering --------------------------------------------------------------------

    private fun render() {
        val nav = GlassState.nav
        val stack = GlassState.cards
        val cards = stack.cards
        val ids = ArrayList<String>(cards.size)
        for (c in cards) ids.add(c.id)
        keys = Deck.keys(nav != null, ids)
        currentIndex = Deck.position(keys, currentKey, currentIndex, GlassState.consumeJump())
        currentKey = if (keys.isEmpty()) null else keys[currentIndex]
        val link = GlassState.link
        val key = currentKey
        when {
            key == null -> showEmpty(link)
            key == Deck.NAV_KEY && nav != null -> showNav(nav, link)
            else -> {
                val card = stack.find(key)
                if (card != null) showCard(card, link) else showEmpty(link)
            }
        }
        pagerView.text = Deck.pagerText(currentIndex, keys.size)
    }

    private fun showEmpty(link: LinkStatus) {
        textPage.visibility = View.VISIBLE
        navPage.visibility = View.GONE
        setTitle(LinkStatus.TITLE_EMPTY)
        bodyView.text = link.emptyText
        footerLeft.text = link.footerText
        setFooterColor(link)
    }

    private fun showCard(card: Card, link: LinkStatus) {
        textPage.visibility = View.VISIBLE
        navPage.visibility = View.GONE
        setTitle(card.title)
        bodyView.text = card.text
        footerLeft.text = Deck.cardFooter(card.source, DateFormat.getTimeFormat(this).format(Date(card.time)))
        setFooterColor(link)
        if (GlassState.cards.markShown(card.id) && !Deck.isLocalCard(card)) {
            BridgeService.current?.sendAck(card.id, Msg.EVENT_SHOWN)
        }
    }

    private fun showNav(nav: NavState, link: LinkStatus) {
        textPage.visibility = View.GONE
        navPage.visibility = View.VISIBLE
        maneuverView.setManeuver(nav.maneuver)
        distanceView.text = Deck.navHeadline(nav)
        instructionView.text = nav.instruction
        footerLeft.text = Deck.navFooter(nav)
        setFooterColor(link)
    }

    private fun setTitle(title: String) {
        titleView.text = title
        titleView.visibility = if (title.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun setFooterColor(link: LinkStatus) {
        val c = if (link.isWarning) AMBER else GREY
        footerLeft.setTextColor(c)
        pagerView.setTextColor(c)
    }

    // ----- input ------------------------------------------------------------------------

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        InputLog.key(event, "dispatchKeyEvent")
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (event.repeatCount == 0) tap("key " + KeyEvent.keyCodeToString(keyCode))
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                if (event.repeatCount == 0) move(+1, "key DPAD_RIGHT")
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                if (event.repeatCount == 0) move(-1, "key DPAD_LEFT")
                return true
            }
            KeyEvent.KEYCODE_TAB -> {
                if (event.repeatCount == 0) move(if (event.isShiftPressed) -1 else +1, "key TAB")
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER,
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_TAB -> return true
        }
        return super.onKeyUp(keyCode, event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        leave("KEYCODE_BACK")
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        InputLog.motion(ev, "motion")
        return super.dispatchGenericMotionEvent(ev)
    }

    /** The touchpad, as the brief expects it on Glass: generic motion from SOURCE_TOUCHPAD. */
    override fun onGenericMotionEvent(ev: MotionEvent): Boolean {
        if ((ev.source and InputDevice.SOURCE_TOUCHPAD) == InputDevice.SOURCE_TOUCHPAD && handleGesture(ev, "touchpad")) return true
        return super.onGenericMotionEvent(ev)
    }

    /**
     * Fallback in case XE24 delivers the touchpad as ordinary touch events instead (Glass has no
     * touchscreen, so any touch event is the touchpad). Logged as "touch ..." so the logs show
     * which path real hardware uses.
     */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        InputLog.motion(ev, "touch")
        if (handleGesture(ev, "touch")) return true
        return super.dispatchTouchEvent(ev)
    }

    /**
     * Feeds one event to the gesture classifier; true when it completed a recognised gesture
     * and acted on it. Only those events are consumed, so Glass's own key translation still
     * gets anything this code doesn't understand.
     */
    private fun handleGesture(ev: MotionEvent, path: String): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> gestures.down(ev.x, ev.y, ev.eventTime)
            MotionEvent.ACTION_CANCEL -> gestures.cancel()
            MotionEvent.ACTION_UP -> {
                val r = gestures.up(ev.x, ev.y, ev.eventTime, invertSwipe)
                return when (r.kind) {
                    TouchpadGestures.Kind.TAP -> { InputLog.gesture(r, invertSwipe, "tap ($path)"); tap(path); true }
                    TouchpadGestures.Kind.FORWARD -> { InputLog.gesture(r, invertSwipe, "older card ($path)"); move(+1, path); true }
                    TouchpadGestures.Kind.BACKWARD -> { InputLog.gesture(r, invertSwipe, "newer card ($path)"); move(-1, path); true }
                    TouchpadGestures.Kind.DOWN -> { InputLog.gesture(r, invertSwipe, "leave ($path)"); leave("$path swipe down"); true }
                    TouchpadGestures.Kind.NONE -> { InputLog.gesture(r, invertSwipe, "nothing ($path)"); false }
                }
            }
        }
        return false
    }

    /** One tap, from any source; debounced across all of them (owner decision 4). */
    private fun tap(source: String) {
        if (!tapDebounce.accept(SystemClock.uptimeMillis())) {
            InputLog.note("tap from $source ignored (within ${InputRules.TAP_DEBOUNCE_MS} ms of the last tap)")
            return
        }
        val key = currentKey
        if (key == null) {
            InputLog.note("tap from $source on the empty screen: nothing to dismiss")
            return
        }
        if (key == Deck.NAV_KEY) {
            InputLog.note("tap from $source on the nav card: it stays (it ends with nav_end)")
            return
        }
        val card = GlassState.cards.find(key) ?: return
        InputLog.note("tap from $source dismisses card ${card.id}")
        val service = BridgeService.current
        val local = Deck.isLocalCard(card)
        if (!local && card.isNotification) service?.sendAck(card.id, Msg.EVENT_TAPPED)
        GlassState.dismiss(card.id)
        if (!local) service?.sendAck(card.id, Msg.EVENT_DISMISSED)
    }

    /** Moves through the pages; delta +1 is an older card. */
    private fun move(delta: Int, source: String) {
        if (!moveDedupe.accept(source, SystemClock.uptimeMillis())) {
            InputLog.note("move $delta from $source ignored (same swipe as another source)")
            return
        }
        if (keys.isEmpty()) return
        val next = Deck.move(currentIndex, delta, keys.size)
        if (next == currentIndex) {
            InputLog.note("move $delta from $source: already at the " + if (delta > 0) "oldest card" else "front")
            return
        }
        currentIndex = next
        currentKey = keys[next]
        InputLog.note("move $delta from $source: now ${Deck.pagerText(currentIndex, keys.size)}")
        render()
    }

    private fun leave(source: String) {
        InputLog.note("$source: leaving the card screen")
        finish()
    }
}

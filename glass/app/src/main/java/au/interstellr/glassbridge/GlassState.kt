package au.interstellr.glassbridge

import android.os.Handler
import android.os.Looper
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Card
import au.interstellr.glassbridge.core.CardStack
import au.interstellr.glassbridge.core.Deck
import au.interstellr.glassbridge.core.Endpoint
import au.interstellr.glassbridge.core.LinkState
import au.interstellr.glassbridge.core.LinkStatus
import au.interstellr.glassbridge.core.NavState

/**
 * Everything the card screen shows: link state (including "needs pairing" after `rejected`),
 * the phone's name, the card stack (25 max, newest first, TTL-pruned, an existing id moves to
 * the front) and the pinned nav state.
 *
 * Main thread only: BridgeService posts to the main looper before touching it, and listeners
 * are called on the main thread.
 */
object GlassState {

    interface Listener {
        fun onGlassStateChanged()
    }

    private val main = Handler(Looper.getMainLooper())
    private val listeners = ArrayList<Listener>()
    private val expiryTask = Runnable { prune(System.currentTimeMillis()) }

    /** The card stack. Read freely on the main thread; change it only through this object. */
    @JvmStatic
    val cards = CardStack()

    /** The pinned nav card, or null when guidance isn't active. */
    @JvmStatic
    var nav: NavState? = null
        private set

    @JvmStatic
    var link: LinkStatus = LinkStatus.INITIAL
        private set

    /** Set by `rejected`, cleared by the next `welcome` (PROTOCOL.md section 6). */
    private var rejected = false

    /** A page the screen should jump to on its next render (a new card, a wake card, a new nav step). */
    private var pendingJump: String? = null

    @JvmStatic
    fun addListener(l: Listener) {
        checkMain("addListener")
        if (!listeners.contains(l)) listeners.add(l)
    }

    @JvmStatic
    fun removeListener(l: Listener) {
        checkMain("removeListener")
        listeners.remove(l)
    }

    /** The pending jump target (and clears it). The card screen calls this while rendering. */
    @JvmStatic
    fun consumeJump(): String? {
        val j = pendingJump
        pendingJump = null
        return j
    }

    // ----- cards and nav ----------------------------------------------------------------

    /** Adds or replaces a card. Returns true if its id is new. New and wake cards come to the front. */
    @JvmStatic
    fun putCard(card: Card): Boolean {
        checkMain("putCard")
        val now = System.currentTimeMillis()
        cards.prune(now)
        val isNew = cards.put(card)
        if (isNew || card.wake) pendingJump = card.id
        BridgeLog.i((if (isNew) "Card " else "Card replaced ") + card.id + " \"" + card.title + "\" (" + card.style +
            (if (card.expiresAt != null) ", ttl " + card.ttlS + " s" else "") + "), " + cards.size + " in the stack")
        scheduleExpiry(now)
        notifyChanged()
        return isNew
    }

    /** Removes a card; returns it, or null if it wasn't there. */
    @JvmStatic
    fun dismiss(id: String): Card? {
        checkMain("dismiss")
        val c = cards.remove(id)
        if (c != null) {
            BridgeLog.i("Card $id removed, ${cards.size} left")
            scheduleExpiry(System.currentTimeMillis())
            notifyChanged()
        } else {
            BridgeLog.d("Dismiss $id: no such card")
        }
        return c
    }

    /** Sets the pinned nav card. Returns true for a new step (the caller wakes and chimes). */
    @JvmStatic
    fun setNav(n: NavState): Boolean {
        checkMain("setNav")
        val newStep = n.isNewStep(nav)
        nav = n
        if (newStep) {
            pendingJump = Deck.NAV_KEY
            BridgeLog.i("Nav step ${n.step}/${n.stepsTotal}: ${n.maneuver} ${n.distanceText} ${n.instruction}")
        }
        notifyChanged()
        return newStep
    }

    @JvmStatic
    fun endNav() {
        checkMain("endNav")
        if (nav != null) {
            nav = null
            BridgeLog.i("Nav ended")
            notifyChanged()
        }
    }

    /** Drops expired cards. Returns true if any went. */
    @JvmStatic
    fun prune(now: Long): Boolean {
        checkMain("prune")
        val changed = cards.prune(now)
        scheduleExpiry(now)
        if (changed) {
            BridgeLog.i("Expired cards removed, ${cards.size} left")
            notifyChanged()
        }
        return changed
    }

    // ----- link -------------------------------------------------------------------------

    /** Discovery finished an attempt: [endpoint] is what will be dialled, or null if nothing was found. */
    @JvmStatic
    fun onSearching(endpoint: Endpoint?) {
        checkMain("onSearching")
        setLink(link.with(state = if (rejected) LinkState.NEEDS_PAIRING else LinkState.SEARCHING, endpoint = endpoint, reason = null))
    }

    /** TCP is up and hello was sent. */
    @JvmStatic
    fun onConnected(endpoint: Endpoint) {
        checkMain("onConnected")
        setLink(link.with(state = if (rejected) LinkState.NEEDS_PAIRING else LinkState.CONNECTING, endpoint = endpoint, reason = null))
    }

    @JvmStatic
    fun onWelcome(phoneName: String) {
        checkMain("onWelcome")
        rejected = false
        setLink(link.with(state = LinkState.LINKED, phoneName = phoneName, reason = null))
    }

    @JvmStatic
    fun onRejected(reason: String) {
        checkMain("onRejected")
        rejected = true
        setLink(link.with(state = LinkState.NEEDS_PAIRING, reason = reason))
    }

    @JvmStatic
    fun onDisconnected(reason: String) {
        checkMain("onDisconnected")
        setLink(link.with(state = if (rejected) LinkState.NEEDS_PAIRING else LinkState.SEARCHING, reason = reason))
    }

    private fun setLink(l: LinkStatus) {
        val old = link
        link = l
        if (old.state != l.state || old.phoneName != l.phoneName || old.endpoint != l.endpoint) {
            BridgeLog.d("Link: $l")
            notifyChanged()
        }
    }

    // ----- internals --------------------------------------------------------------------

    private fun scheduleExpiry(now: Long) {
        main.removeCallbacks(expiryTask)
        var earliest: Long? = null
        for (c in cards.cards) {
            val e = c.expiresAt ?: continue
            if (earliest == null || e < earliest) earliest = e
        }
        if (earliest != null) main.postDelayed(expiryTask, Math.max(0L, earliest - now) + 50L)
    }

    private fun notifyChanged() {
        for (l in ArrayList(listeners)) {
            try {
                l.onGlassStateChanged()
            } catch (t: Throwable) {
                BridgeLog.e("GlassState listener threw", t)
            }
        }
    }

    private fun checkMain(what: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            BridgeLog.e("GlassState.$what called off the main thread", IllegalStateException(what))
        }
    }
}

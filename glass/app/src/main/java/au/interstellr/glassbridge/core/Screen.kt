package au.interstellr.glassbridge.core

/**
 * Platform-free rules behind the card screen: link state texts, the page order and position
 * (pinned nav card, then the card stack), footers and spoken nav text. MainActivity and
 * BridgeService only turn these into views, notifications and speech.
 */

/** Where the link is, as the card screen shows it. */
enum class LinkState {
    /** Discovering the iPhone, dialling it, or waiting before the next attempt. */
    SEARCHING,

    /** TCP is up and `hello` was sent; no `welcome` yet. */
    CONNECTING,

    /** `welcome` received: the iPhone accepted this Glass. */
    LINKED,

    /** The iPhone answered `rejected`; shown until the next `welcome` (PROTOCOL.md section 6). */
    NEEDS_PAIRING
}

/**
 * The link as the UI shows it. [endpoint] is the last endpoint tried or connected (null when
 * discovery found nothing), [phoneName] the name from the last `welcome`.
 */
class LinkStatus(
    val state: LinkState,
    val phoneName: String?,
    val endpoint: Endpoint?,
    val reason: String?
) {
    val isLinked: Boolean get() = state == LinkState.LINKED

    /** Body text of the empty card screen. */
    val emptyText: String
        get() = when (state) {
            LinkState.LINKED -> TEXT_EMPTY_LINKED
            LinkState.NEEDS_PAIRING -> Pairing.REJECTED_HINT
            else -> TEXT_LOOKING
        }

    /** Left footer text of the empty card screen. */
    val footerText: String
        get() = when (state) {
            LinkState.LINKED -> "Connected to " + (phoneName ?: Welcome.DEFAULT_PHONE_NAME)
            LinkState.CONNECTING -> "Connecting to " + (endpoint?.let { hostPort(it) } ?: "iPhone")
            LinkState.NEEDS_PAIRING -> "Not paired" + (endpoint?.let { " with " + it.host } ?: "")
            LinkState.SEARCHING -> endpoint?.let { "Trying $it" } ?: "No iPhone found yet"
        }

    /**
     * Left footer on a card or nav page: null while linked (the page shows its own source and
     * time, or ETA), otherwise the link state, so "not paired" (PROTOCOL.md section 6) and
     * "looking for the iPhone" stay readable on every page, not only on the empty screen.
     */
    val pageFooterText: String?
        get() = when (state) {
            LinkState.LINKED -> null
            LinkState.NEEDS_PAIRING -> Pairing.REJECTED_FOOTER
            else -> footerText
        }

    /** True when the footer is amber (#FFB300): every state except [LinkState.LINKED]. */
    val isWarning: Boolean get() = state != LinkState.LINKED

    /** One line for the service's ongoing notification. */
    val notificationText: String
        get() = when (state) {
            LinkState.LINKED -> "Connected to " + (phoneName ?: Welcome.DEFAULT_PHONE_NAME)
            LinkState.CONNECTING -> "Connecting to " + (endpoint?.let { hostPort(it) } ?: "iPhone")
            LinkState.NEEDS_PAIRING -> "Not paired. " + Pairing.REJECTED_HINT
            LinkState.SEARCHING -> TEXT_LOOKING
        }

    fun with(
        state: LinkState = this.state,
        phoneName: String? = this.phoneName,
        endpoint: Endpoint? = this.endpoint,
        reason: String? = this.reason
    ): LinkStatus = LinkStatus(state, phoneName, endpoint, reason)

    override fun toString(): String = "LinkStatus($state, phone=$phoneName, endpoint=$endpoint, reason=$reason)"

    companion object {
        const val TEXT_EMPTY_LINKED = "Cards from your iPhone show up here."
        const val TEXT_LOOKING = "Looking for your iPhone…"
        const val TITLE_EMPTY = "StellrGlass"

        @JvmField
        val INITIAL = LinkStatus(LinkState.SEARCHING, null, null, null)

        private fun hostPort(e: Endpoint): String = e.host + ":" + e.port
    }
}

/**
 * What StellrGlass's live card on Glass's own timeline says: a [headline] and a [detail]
 * line. "Listening" means the ANCS subscription is up (PROTOCOL.md section 10), which works
 * over Bluetooth whatever the TCP link is doing.
 */
data class TimelineStatus(val headline: String, val detail: String) {
    companion object {
        const val HEADLINE_LISTENING = "Listening for notifications"
        const val HEADLINE_NOT_PAIRED = "Not paired"
        const val DETAIL_OPEN_IPHONE_APP = "Open StellrGlass on your iPhone to get its notifications"

        @JvmStatic
        fun of(link: LinkStatus, listening: Boolean): TimelineStatus = when {
            listening -> TimelineStatus(HEADLINE_LISTENING, link.notificationText)
            link.isLinked -> TimelineStatus(link.footerText, DETAIL_OPEN_IPHONE_APP)
            link.state == LinkState.NEEDS_PAIRING -> TimelineStatus(HEADLINE_NOT_PAIRED, Pairing.REJECTED_HINT)
            else -> TimelineStatus(LinkStatus.TEXT_LOOKING, link.footerText)
        }
    }
}

/**
 * The pages of the card screen: the pinned nav card first (when guidance is active), then the
 * cards newest first. Pages are identified by key: [NAV_KEY] or the card id.
 */
object Deck {
    /** Key of the nav page; a card id can't start with NUL in practice. */
    const val NAV_KEY = "\u0000nav"

    @JvmStatic
    fun keys(hasNav: Boolean, cardIds: List<String>): List<String> {
        val out = ArrayList<String>(cardIds.size + 1)
        if (hasNav) out.add(NAV_KEY)
        out.addAll(cardIds)
        return out
    }

    /**
     * The index to show after the pages changed. A pending [jumpTo] page wins (a new card,
     * a wake card, or a new nav step); otherwise the page [currentKey] stays in view; if it's
     * gone, [previousIndex] clamped into range (the next older page after a dismissal).
     */
    @JvmStatic
    fun position(keys: List<String>, currentKey: String?, previousIndex: Int, jumpTo: String?): Int {
        if (keys.isEmpty()) return 0
        if (jumpTo != null) {
            val j = keys.indexOf(jumpTo)
            if (j >= 0) return j
        }
        if (currentKey != null) {
            val c = keys.indexOf(currentKey)
            if (c >= 0) return c
        }
        return clamp(previousIndex, keys.size)
    }

    /** [index] moved by [delta] and clamped (no wrap-around). */
    @JvmStatic
    fun move(index: Int, delta: Int, total: Int): Int = if (total <= 0) 0 else clamp(index + delta, total)

    /** "2/5"; "" when there are no pages. */
    @JvmStatic
    fun pagerText(index: Int, total: Int): String = if (total <= 0) "" else "${clamp(index, total) + 1}/$total"

    /** Left footer of a card: "source · time", either part left out when empty. */
    @JvmStatic
    fun cardFooter(source: String?, timeText: String?): String {
        val parts = ArrayList<String>(2)
        if (!source.isNullOrBlank()) parts.add(source.trim())
        if (!timeText.isNullOrBlank()) parts.add(timeText.trim())
        return parts.joinToString(" · ")
    }

    /** Left footer of the nav card: ETA and remaining distance, else the destination. */
    @JvmStatic
    fun navFooter(nav: NavState): String {
        val f = nav.footerText
        if (f.isNotEmpty()) return f
        return nav.destination ?: ""
    }

    /** The big text on the nav card: the distance, or "Arrived". */
    @JvmStatic
    fun navHeadline(nav: NavState): String = if (nav.arrived) "Arrived" else nav.distanceText

    /** Local cards (made on Glass, such as "Paired") are never acked to the iPhone. */
    @JvmStatic
    fun isLocalCard(card: Card): Boolean = card.id == Pairing.CARD_ID && card.source == Pairing.CARD_SOURCE

    private fun clamp(i: Int, total: Int): Int = Math.max(0, Math.min(i, total - 1))
}

/** What Glass says aloud for a `nav` with `announce:true`. */
object NavSpeech {
    /** Closer than this, the distance isn't spoken (the turn is now). */
    const val SPEAK_DISTANCE_MIN_M = 15.0

    /**
     * "In 250 metres, Turn left onto King William Street". Just the instruction when
     * arriving, arrived or closer than [SPEAK_DISTANCE_MIN_M]; "" when there's no instruction.
     */
    @JvmStatic
    fun text(nav: NavState): String {
        val instruction = nav.instruction.trim()
        if (instruction.isEmpty()) return ""
        if (nav.arrived || nav.maneuver == "arrive" || nav.distanceM < SPEAK_DISTANCE_MIN_M) return instruction
        return "In " + spokenDistance(nav.distanceM) + ", " + instruction
    }

    /** [formatDistance] in words: "40 metres", "1.2 kilometres", "1 kilometre", "12 kilometres". */
    @JvmStatic
    fun spokenDistance(meters: Double): String {
        val d = formatDistance(meters)
        return when {
            d.endsWith(" km") -> {
                var n = d.substring(0, d.length - 3)
                if (n.endsWith(".0")) n = n.substring(0, n.length - 2)
                n + if (n == "1") " kilometre" else " kilometres"
            }
            d.endsWith(" m") -> {
                val n = d.substring(0, d.length - 2)
                n + if (n == "1") " metre" else " metres"
            }
            else -> d
        }
    }
}

/** Battery maths for `status`. */
object BatteryMath {
    /** Percent 0..100 from ACTION_BATTERY_CHANGED's level and scale; -1 when unknown. */
    @JvmStatic
    fun percent(level: Int, scale: Int): Int {
        if (level < 0 || scale <= 0) return -1
        return Math.max(0, Math.min(100, Math.round(level * 100f / scale)))
    }
}

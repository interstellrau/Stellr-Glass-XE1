package au.interstellr.glassbridge.core

/**
 * What Glass does with each iPhone-to-Glass message (PROTOCOL.md section 5). BridgeService
 * implements it. Every method is called on the link thread and must not block.
 */
interface GlassHandler {
    fun onWelcome(welcome: Welcome)
    fun onRejected(rejected: Rejected)
    fun onPong()
    fun onRequestStatus()
    fun onCard(card: Card)
    fun onDismiss(id: String)
    fun onSpeak(text: String)
    fun onNav(nav: NavState)
    fun onNavEnd()
    fun onLocation(fix: LocationFix)
    fun onSync(enabled: Boolean)
    fun onFileAck(frame: Frame)
    fun onScreencast(cmd: ScreencastCmd)

    /** [network] is null when the message has no usable SSID; [ssid] is whatever was sent ("" if none). */
    fun onWifiAdd(network: WifiNetwork?, ssid: String)

    /** Glass-to-iPhone types, unknown types and unusable messages. The payload was already consumed. */
    fun onIgnored(frame: Frame, why: String)
}

/**
 * Turns frames into [GlassHandler] calls. Every type in PROTOCOL.md section 5 has a branch;
 * unknown types are ignored, as the protocol requires.
 */
object MessageRouter {
    const val WHY_TO_PHONE = "a Glass-to-iPhone message"
    const val WHY_UNKNOWN = "unknown type"

    /** Routes [frame]; returns the name of the handler method called (for logs and tests). */
    @JvmStatic
    @JvmOverloads
    fun route(frame: Frame, h: GlassHandler, now: Long = System.currentTimeMillis()): String {
        val o = frame.obj
        when (frame.type) {
            MsgType.WELCOME -> { h.onWelcome(Welcome.from(o)); return "onWelcome" }
            MsgType.REJECTED -> { h.onRejected(Rejected.from(o)); return "onRejected" }
            MsgType.PONG -> { h.onPong(); return "onPong" }
            MsgType.PING -> return ignore(frame, h, "answered by the link")
            MsgType.REQUEST_STATUS -> { h.onRequestStatus(); return "onRequestStatus" }
            MsgType.CARD -> { h.onCard(Card.from(o, now)); return "onCard" }
            MsgType.DISMISS -> {
                val id = Json.text(o, "id")
                if (id.isNullOrEmpty()) return ignore(frame, h, "dismiss without an id")
                h.onDismiss(id)
                return "onDismiss"
            }
            MsgType.SPEAK -> {
                val text = Json.text(o, "text")
                if (text.isNullOrBlank()) return ignore(frame, h, "speak without text")
                h.onSpeak(text)
                return "onSpeak"
            }
            MsgType.NAV -> { h.onNav(NavState.from(o)); return "onNav" }
            MsgType.NAV_END -> { h.onNavEnd(); return "onNavEnd" }
            MsgType.LOCATION -> {
                val fix = LocationFix.from(o, now) ?: return ignore(frame, h, "location without a usable lat/lon")
                h.onLocation(fix)
                return "onLocation"
            }
            MsgType.SYNC -> { h.onSync(Json.bool(o, "enabled") ?: false); return "onSync" }
            MsgType.FILE_ACK -> { h.onFileAck(frame); return "onFileAck" }
            MsgType.SCREENCAST -> { h.onScreencast(ScreencastCmd.from(o)); return "onScreencast" }
            MsgType.WIFI_ADD -> { h.onWifiAdd(WifiNetwork.from(o), Json.text(o, "ssid") ?: ""); return "onWifiAdd" }
            MsgType.HELLO, MsgType.STATUS, MsgType.ACK, MsgType.FILE_BEGIN, MsgType.FILE_CHUNK,
            MsgType.FILE_END, MsgType.FRAME, MsgType.WIFI_RESULT -> return ignore(frame, h, WHY_TO_PHONE)
            else -> return ignore(frame, h, WHY_UNKNOWN)
        }
    }

    private fun ignore(frame: Frame, h: GlassHandler, why: String): String {
        h.onIgnored(frame, why)
        return "onIgnored"
    }
}

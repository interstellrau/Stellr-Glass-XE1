package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.lang.reflect.Modifier

/**
 * The platform-free logic behind the Glass app layer: touchpad gestures and debouncing,
 * link state texts, page order and position, message routing, nav speech, maneuver shapes
 * and the media re-scan timer.
 */
class AppLogicTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun j(s: String) = JSONObject(s)

    // ----- touchpad gestures ---------------------------------------------------------------

    @Test
    fun swipeDirectionFollowsDxAndInvertSwipe() {
        val g = TouchpadGestures()
        g.down(100f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.FORWARD, g.up(300f, 95f, 200, false).kind)
        g.down(100f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.BACKWARD, g.up(300f, 95f, 200, true).kind)
        g.down(600f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.BACKWARD, g.up(400f, 95f, 200, false).kind)
        g.down(600f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.FORWARD, g.up(400f, 95f, 200, true).kind)
        // A long, slow swipe is still a swipe.
        g.down(100f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.FORWARD, g.up(900f, 60f, 2000, false).kind)
    }

    @Test
    fun swipeNeedsMoreThan120Px() {
        val g = TouchpadGestures()
        g.down(100f, 90f, 0)
        val r = g.up(220f, 90f, 100, false)
        assertEquals(TouchpadGestures.Kind.NONE, r.kind)
        assertEquals(120f, r.dx, 0f)
        g.down(100f, 90f, 0)
        assertEquals(TouchpadGestures.Kind.FORWARD, g.up(220.5f, 90f, 100, false).kind)
    }

    @Test
    fun tapIsSmallAndShort() {
        val g = TouchpadGestures()
        g.down(500f, 90f, 1000)
        val tap = g.up(510f, 95f, 1150, false)
        assertEquals(TouchpadGestures.Kind.TAP, tap.kind)
        assertEquals(150L, tap.durationMs)
        g.down(500f, 90f, 1000)
        assertEquals(TouchpadGestures.Kind.TAP, g.up(530f, 60f, 1299, false).kind) // 30 px, 299 ms: still a tap
        g.down(500f, 90f, 1000)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(505f, 90f, 1300, false).kind) // 300 ms: too long
        g.down(500f, 90f, 1000)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(531f, 90f, 1100, false).kind) // 31 px in x
        g.down(500f, 90f, 1000)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(500f, 59f, 1100, false).kind) // 31 px in y
        // invert_swipe never affects taps.
        g.down(500f, 90f, 1000)
        assertEquals(TouchpadGestures.Kind.TAP, g.up(500f, 90f, 1100, true).kind)
    }

    @Test
    fun swipeDownAndStrayEvents() {
        val g = TouchpadGestures()
        g.down(500f, 20f, 0)
        assertEquals(TouchpadGestures.Kind.DOWN, g.up(520f, 150f, 200, false).kind)
        g.down(500f, 20f, 0)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(560f, 100f, 200, false).kind) // 80 down but 60 across
        g.down(500f, 150f, 0)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(500f, 20f, 200, false).kind) // upward: nothing
        // UP without DOWN, and after CANCEL.
        assertEquals(TouchpadGestures.Kind.NONE, TouchpadGestures().up(900f, 90f, 10, false).kind)
        g.down(100f, 90f, 0)
        assertTrue(g.isActive)
        g.cancel()
        assertFalse(g.isActive)
        assertEquals(TouchpadGestures.Kind.NONE, g.up(400f, 90f, 100, false).kind)
    }

    @Test
    fun tapDebounceIs400MsAcrossEverything() {
        val d = Debouncer(InputRules.TAP_DEBOUNCE_MS)
        assertTrue(d.accept(10_000))
        assertFalse(d.accept(10_001)) // the same tap arriving a second way
        assertFalse(d.accept(10_399))
        assertTrue(d.accept(10_400))
        // A rejected tap doesn't extend the window.
        assertTrue(d.accept(20_000))
        assertFalse(d.accept(20_300))
        assertTrue(d.accept(20_450))
    }

    @Test
    fun movesFromAnotherSourceWithin400MsAreTheSameSwipe() {
        val d = SourceDeduper(InputRules.MOVE_DEDUPE_MS)
        assertTrue(d.accept("touchpad", 0))
        assertFalse(d.accept("key TAB", 100))
        assertTrue(d.accept("touchpad", 150)) // repeated swipes from one source always pass
        assertTrue(d.accept("touchpad", 200))
        assertFalse(d.accept("key DPAD_RIGHT", 599))
        assertTrue(d.accept("key TAB", 600))
        assertTrue(d.accept("key TAB", 601))
    }

    // ----- link state texts ----------------------------------------------------------------

    @Test
    fun linkStatusTexts() {
        val ep = Endpoint("192.168.1.20", 9090, Endpoint.VIA_CONFIG)
        val searching = LinkStatus.INITIAL
        assertEquals("Looking for your iPhone…", searching.emptyText)
        assertEquals("No iPhone found yet", searching.footerText)
        assertTrue(searching.isWarning)
        assertFalse(searching.isLinked)

        val trying = searching.with(endpoint = ep)
        assertEquals("Trying 192.168.1.20:9090 (config)", trying.footerText)
        assertEquals("Looking for your iPhone…", trying.emptyText)

        val connecting = trying.with(state = LinkState.CONNECTING)
        assertEquals("Connecting to 192.168.1.20:9090", connecting.footerText)
        assertEquals("Looking for your iPhone…", connecting.emptyText)
        assertTrue(connecting.isWarning)

        val linked = connecting.with(state = LinkState.LINKED, phoneName = "Alexander's iPhone")
        assertEquals("Cards from your iPhone show up here.", linked.emptyText)
        assertEquals("Connected to Alexander's iPhone", linked.footerText)
        assertFalse(linked.isWarning)
        assertTrue(linked.isLinked)
        assertEquals("Connected to iPhone", linked.with(phoneName = null).footerText)

        val rejected = linked.with(state = LinkState.NEEDS_PAIRING, reason = Rejected.BAD_TOKEN)
        assertEquals("Pair on your iPhone: GlassBridge › Glass › Pair Glass", rejected.emptyText)
        assertEquals("Not paired with 192.168.1.20", rejected.footerText)
        assertTrue(rejected.isWarning)
        assertTrue(rejected.notificationText.contains("Pair Glass"))
        assertEquals("Not paired", rejected.with(endpoint = null).footerText)
    }

    @Test
    fun cardAndNavPagesShowTheLinkStateWhileNotLinked() {
        val ep = Endpoint("172.20.10.1", 9090, Endpoint.VIA_HOTSPOT)
        // Linked: the page keeps its own footer (source and time, or ETA).
        assertNull(LinkStatus(LinkState.LINKED, "Alexander's iPhone", ep, null).pageFooterText)
        // Not paired: readable on every page, not only on the empty screen (PROTOCOL.md section 6).
        val rejected = LinkStatus(LinkState.NEEDS_PAIRING, null, ep, Rejected.PAIRING_REQUIRED)
        assertEquals("Not paired: pair on your iPhone", rejected.pageFooterText)
        assertEquals(Pairing.REJECTED_FOOTER, rejected.with(endpoint = null).pageFooterText)
        // Looking or connecting: the same text as the empty screen's footer.
        assertEquals("Trying 172.20.10.1:9090 (hotspot)", LinkStatus(LinkState.SEARCHING, null, ep, null).pageFooterText)
        assertEquals("No iPhone found yet", LinkStatus.INITIAL.pageFooterText)
        assertEquals("Connecting to 172.20.10.1:9090", LinkStatus(LinkState.CONNECTING, null, ep, null).pageFooterText)
    }

    // ----- pages ----------------------------------------------------------------------------

    @Test
    fun deckKeysPositionAndPager() {
        val keys = Deck.keys(true, listOf("c3", "c2", "c1"))
        assertEquals(listOf(Deck.NAV_KEY, "c3", "c2", "c1"), keys)
        assertEquals(listOf("c1"), Deck.keys(false, listOf("c1")))

        // A pending jump wins, then the current page, then the clamped previous index.
        assertEquals(1, Deck.position(keys, "c1", 3, "c3"))
        assertEquals(3, Deck.position(keys, "c1", 0, null))
        assertEquals(3, Deck.position(keys, "c1", 0, "gone")) // jump target already dismissed
        assertEquals(2, Deck.position(keys, "dismissed", 2, null)) // the next older card slides in
        assertEquals(3, Deck.position(keys, "dismissed", 9, null))
        assertEquals(0, Deck.position(emptyList(), "c1", 4, "c1"))

        // A new card arriving underneath keeps the same card in view.
        val before = Deck.keys(false, listOf("b", "a"))
        val i = Deck.position(before, "a", 1, null)
        val after = Deck.keys(false, listOf("new", "b", "a"))
        assertEquals("a", after[Deck.position(after, before[i], i, null)])
        // Nav starting while a card is in view (without a jump) keeps that card too.
        val withNav = Deck.keys(true, listOf("b", "a"))
        assertEquals("b", withNav[Deck.position(withNav, "b", 0, null)])

        assertEquals("2/5", Deck.pagerText(1, 5))
        assertEquals("1/1", Deck.pagerText(0, 1))
        assertEquals("", Deck.pagerText(0, 0))
        assertEquals(4, Deck.move(4, +1, 5))
        assertEquals(0, Deck.move(0, -1, 5))
        assertEquals(3, Deck.move(2, +1, 5))
        assertEquals(0, Deck.move(3, -1, 0))
    }

    @Test
    fun footersAndLocalCards() {
        assertEquals("fake_phone · 10:42", Deck.cardFooter("fake_phone", "10:42"))
        assertEquals("10:42", Deck.cardFooter(null, "10:42"))
        assertEquals("10:42", Deck.cardFooter("  ", "10:42"))
        assertEquals("Messages", Deck.cardFooter("Messages", ""))

        val nav = NavState.from(j("{\"type\":\"nav\",\"instruction\":\"Turn left\",\"maneuver\":\"left\",\"distance_m\":240,\"step\":2,\"steps_total\":5,\"eta_min\":7,\"remaining_m\":1234}"))
        assertEquals("7 min · 1.2 km", Deck.navFooter(nav))
        assertEquals("240 m", Deck.navHeadline(nav))
        val bare = NavState.from(j("{\"type\":\"nav\",\"instruction\":\"Go\",\"maneuver\":\"straight\",\"distance_m\":5,\"step\":1,\"steps_total\":2,\"destination\":\"Rundle Mall\"}"))
        assertEquals("Rundle Mall", Deck.navFooter(bare))
        val arrived = NavState.from(j("{\"type\":\"nav\",\"instruction\":\"Arrive\",\"maneuver\":\"arrive\",\"distance_m\":0,\"step\":5,\"steps_total\":5,\"arrived\":true}"))
        assertEquals("Arrived", Deck.navHeadline(arrived))

        val paired = Pairing.pairedCard(Welcome.from(j("{\"type\":\"welcome\",\"phone_name\":\"fake_phone\",\"pair_token\":\"0123456789abcdef0123456789abcdef\",\"pair_code\":\"0042\"}")), 1L)
        assertTrue(Deck.isLocalCard(paired))
        assertEquals("fake_phone\nCode 0042", paired.text)
        assertTrue(paired.wake)
        assertTrue(paired.chime)
        // A phone card that happens to use the same id isn't local.
        assertFalse(Deck.isLocalCard(Card.from(j("{\"id\":\"glassbridge-paired\",\"title\":\"x\",\"text\":\"y\"}"), 1L)))
        assertFalse(Deck.isLocalCard(Card.from(j("{\"id\":\"c1\",\"title\":\"x\",\"text\":\"y\"}"), 1L)))
    }

    // ----- nav speech, battery ----------------------------------------------------------------

    @Test
    fun navSpeech() {
        fun nav(m: String, d: Double, instr: String = "Turn left onto King William Street", arrived: Boolean = false) =
            NavState.from(JSONObject().put("type", "nav").put("instruction", instr).put("maneuver", m)
                .put("distance_m", d).put("step", 2).put("steps_total", 4).put("arrived", arrived))
        assertEquals("In 250 metres, Turn left onto King William Street", NavSpeech.text(nav("left", 248.0)))
        assertEquals("In 40 metres, Turn left onto King William Street", NavSpeech.text(nav("left", 41.0)))
        assertEquals("Turn left onto King William Street", NavSpeech.text(nav("left", 10.0)))
        assertEquals("Arrive at Rundle Mall", NavSpeech.text(nav("arrive", 100.0, "Arrive at Rundle Mall")))
        assertEquals("You have arrived", NavSpeech.text(nav("straight", 100.0, "You have arrived", arrived = true)))
        assertEquals("", NavSpeech.text(nav("left", 100.0, "  ")))

        assertEquals("1 kilometre", NavSpeech.spokenDistance(999.0))
        assertEquals("1.2 kilometres", NavSpeech.spokenDistance(1234.0))
        assertEquals("12 kilometres", NavSpeech.spokenDistance(12_300.0))
        assertEquals("25 metres", NavSpeech.spokenDistance(27.0))
        assertEquals("0 metres", NavSpeech.spokenDistance(0.0))
    }

    @Test
    fun batteryPercent() {
        assertEquals(87, BatteryMath.percent(87, 100))
        assertEquals(50, BatteryMath.percent(128, 256))
        assertEquals(100, BatteryMath.percent(120, 100))
        assertEquals(-1, BatteryMath.percent(-1, 100))
        assertEquals(-1, BatteryMath.percent(50, 0))
    }

    // ----- message routing --------------------------------------------------------------------

    /** Records which handler method ran with what. */
    private class Recorder : GlassHandler {
        val calls = ArrayList<String>()
        var last: Any? = null
        override fun onWelcome(welcome: Welcome) { calls.add("welcome"); last = welcome }
        override fun onRejected(rejected: Rejected) { calls.add("rejected"); last = rejected }
        override fun onPong() { calls.add("pong") }
        override fun onRequestStatus() { calls.add("request_status") }
        override fun onCard(card: Card) { calls.add("card"); last = card }
        override fun onDismiss(id: String) { calls.add("dismiss"); last = id }
        override fun onSpeak(text: String) { calls.add("speak"); last = text }
        override fun onNav(nav: NavState) { calls.add("nav"); last = nav }
        override fun onNavEnd() { calls.add("nav_end") }
        override fun onLocation(fix: LocationFix) { calls.add("location"); last = fix }
        override fun onSync(enabled: Boolean) { calls.add("sync"); last = enabled }
        override fun onFileAck(frame: Frame) { calls.add("file_ack"); last = frame }
        override fun onScreencast(cmd: ScreencastCmd) { calls.add("screencast"); last = cmd }
        override fun onWifiAdd(network: WifiNetwork?, ssid: String) { calls.add("wifi_add"); last = Pair(network, ssid) }
        override fun onIgnored(frame: Frame, why: String) { calls.add("ignored"); last = why }
    }

    private fun route(json: String): Recorder {
        val r = Recorder()
        MessageRouter.route(Frame(j(json), null), r, 1_800_000_000_000L)
        assertEquals("exactly one handler call for $json", 1, r.calls.size)
        return r
    }

    @Test
    fun everyProtocolTypeHasARoute() {
        val types = MsgType::class.java.declaredFields
            .filter { Modifier.isStatic(it.modifiers) && it.type == String::class.java }
            .map { it.get(null) as String }
            .toSet()
        assertEquals("PROTOCOL.md section 5 has 23 types", 23, types.size)

        val toGlass = mapOf(
            "welcome" to "{\"type\":\"welcome\",\"server\":\"s\",\"version\":2,\"phone_name\":\"P\"}",
            "rejected" to "{\"type\":\"rejected\",\"reason\":\"pairing_required\"}",
            "pong" to "{\"type\":\"pong\"}",
            "request_status" to "{\"type\":\"request_status\"}",
            "card" to "{\"type\":\"card\",\"id\":\"c1\",\"title\":\"T\",\"text\":\"X\"}",
            "dismiss" to "{\"type\":\"dismiss\",\"id\":\"c1\"}",
            "speak" to "{\"type\":\"speak\",\"text\":\"hello\"}",
            "nav" to "{\"type\":\"nav\",\"instruction\":\"Go\",\"maneuver\":\"left\",\"distance_m\":10,\"step\":1,\"steps_total\":2}",
            "nav_end" to "{\"type\":\"nav_end\"}",
            "location" to "{\"type\":\"location\",\"lat\":-34.9285,\"lon\":138.6007,\"acc_m\":5,\"time\":1793491200123}",
            "sync" to "{\"type\":\"sync\",\"enabled\":true}",
            "file_ack" to "{\"type\":\"file_ack\",\"id\":\"a.jpg:3\",\"ok\":true}",
            "screencast" to "{\"type\":\"screencast\",\"on\":true,\"fps\":9}",
            "wifi_add" to "{\"type\":\"wifi_add\",\"ssid\":\"My iPhone\",\"password\":\"secret123\",\"security\":\"WPA\"}"
        )
        val toPhone = setOf("hello", "status", "ack", "file_begin", "file_chunk", "file_end", "frame", "wifi_result")
        for (t in types) {
            when {
                t in toGlass -> assertEquals(t, route(toGlass.getValue(t)).calls[0])
                t in toPhone -> {
                    val r = route("{\"type\":\"$t\"}")
                    assertEquals("ignored", r.calls[0])
                    assertEquals(MessageRouter.WHY_TO_PHONE, r.last)
                }
                t == "ping" -> assertEquals("ignored", route("{\"type\":\"ping\"}").calls[0]) // BridgeConnection answers it
                else -> throw AssertionError("type $t has no expectation in this test")
            }
        }
        val unknown = route("{\"type\":\"x_future_thing\",\"x_extra\":1}")
        assertEquals("ignored", unknown.calls[0])
        assertEquals(MessageRouter.WHY_UNKNOWN, unknown.last)
    }

    @Test
    fun routedValuesAreParsed() {
        val w = route("{\"type\":\"welcome\",\"phone_name\":\"fake_phone\",\"pair_token\":\"0123456789abcdef0123456789abcdef\",\"pair_code\":\"0042\"}").last as Welcome
        assertTrue(w.isNewPairing)
        assertEquals("0042", w.pairCode)
        assertEquals(Rejected.BAD_TOKEN, (route("{\"type\":\"rejected\",\"reason\":\"bad_token\"}").last as Rejected).reason)

        val c = route("{\"type\":\"card\",\"id\":\"n1\",\"title\":\"Messages\",\"text\":\"Hi\",\"style\":\"notification\",\"chime\":true,\"wake\":true,\"ttl_s\":30}").last as Card
        assertTrue(c.isNotification)
        assertTrue(c.chime && c.wake)
        assertEquals(1_800_000_030_000L, c.expiresAt)

        assertEquals(5, (route("{\"type\":\"screencast\",\"on\":true,\"fps\":9}").last as ScreencastCmd).fps)
        assertEquals(false, route("{\"type\":\"sync\"}").last)
        assertEquals(true, route("{\"type\":\"sync\",\"enabled\":true}").last)
        assertEquals("c9", route("{\"type\":\"dismiss\",\"id\":\"c9\"}").last)
        assertEquals("ignored", route("{\"type\":\"dismiss\"}").calls[0])
        assertEquals("ignored", route("{\"type\":\"speak\",\"text\":\"  \"}").calls[0])
        assertEquals("ignored", route("{\"type\":\"location\",\"lon\":138.6}").calls[0])
        val fix = route("{\"type\":\"location\",\"lat\":-34.9,\"lon\":138.6}").last as LocationFix
        assertEquals(LocationFix.DEFAULT_ACCURACY_M, fix.accM, 0.0)

        @Suppress("UNCHECKED_CAST")
        val noSsid = route("{\"type\":\"wifi_add\",\"password\":\"x\"}").last as Pair<WifiNetwork?, String>
        assertNull(noSsid.first)
        assertEquals("", noSsid.second)
        @Suppress("UNCHECKED_CAST")
        val wep = route("{\"type\":\"wifi_add\",\"ssid\":\"Old\",\"password\":\"0123456789\",\"security\":\"wep\"}").last as Pair<WifiNetwork?, String>
        assertEquals(WifiNetwork.WEP, wep.first!!.security)
        assertEquals("Old", wep.second)
    }

    // ----- maneuver shapes ----------------------------------------------------------------------

    @Test
    fun oneDistinctShapePerManeuverInsideTheBox() {
        val sigs = HashMap<String, String>()
        for (m in NavState.MANEUVERS) {
            val s = ManeuverShapes.of(m)
            assertTrue("$m draws something", s.lines.isNotEmpty() || s.rings.isNotEmpty() || s.dots.isNotEmpty())
            for (p in s.allPoints()) {
                assertTrue("$m point ${p[0]},${p[1]} inside the box", p[0] >= 0.02f && p[0] <= 0.98f && p[1] >= 0.02f && p[1] <= 0.98f)
            }
            for (l in s.lines) assertEquals("$m polyline has x,y pairs", 0, l.size % 2)
            sigs[m] = s.signature()
        }
        assertEquals("10 maneuvers, 10 different shapes", 10, sigs.values.toSet().size)
        assertEquals(ManeuverShapes.of("straight").signature(), ManeuverShapes.of("roundabout").signature())
        assertEquals(ManeuverShapes.of("straight").signature(), ManeuverShapes.of(null).signature())

        // Left mirrors right; the arrow of a right turn points right (0 degrees), left points left.
        val right = ManeuverShapes.of("right")
        val left = ManeuverShapes.of("left")
        assertEquals(0f, right.heads[0][2], 0f)
        assertEquals(180f, left.heads[0][2], 0f)
        assertEquals(1f - right.heads[0][0], left.heads[0][0], 1e-3f)
        assertEquals(-45f, ManeuverShapes.of("slight_right").heads[0][2], 0f)
        assertEquals(-135f, ManeuverShapes.of("slight_left").heads[0][2], 0f)
        assertEquals(135f, ManeuverShapes.of("sharp_left").heads[0][2], 0f)
        // U-turn ends pointing down on the right-hand side (left-hand traffic).
        val u = ManeuverShapes.of("uturn")
        assertEquals(90f, u.heads[0][2], 0f)
        assertTrue(u.heads[0][0] > 0.5f)
        assertNotEquals(ManeuverShapes.of("depart").signature(), ManeuverShapes.of("straight").signature())
    }

    // ----- media re-scan timer ----------------------------------------------------------------

    @Test
    fun uploadOutcomeDecidesWhenAFileIsTriedAgain() {
        fun result(ok: Boolean, error: String?, ack: JSONObject?, timedOut: Boolean = false) =
            Uploader.Result("IMG_1.jpg:10", ok, error, 10, null, ack, timedOut)
        val okAck = j("{\"type\":\"file_ack\",\"id\":\"IMG_1.jpg:10\",\"ok\":true}")
        val refusedAck = j("{\"type\":\"file_ack\",\"id\":\"IMG_1.jpg:10\",\"ok\":false,\"error\":\"size mismatch\"}")
        assertEquals(MediaRules.Next.SYNCED, MediaRules.next(result(true, null, okAck)))
        assertEquals(MediaRules.Next.NEXT_SESSION, MediaRules.next(result(false, "size mismatch", refusedAck)))
        // No file_ack within 60 s: next session, not the next scan (PROTOCOL.md section 5).
        assertEquals(MediaRules.Next.NEXT_SESSION, MediaRules.next(result(false, "no file_ack within 60 s", null, timedOut = true)))
        // Link trouble: try again at the next scan.
        for (e in listOf("not connected", "link dropped", "cancelled", "cancelled (link dropped)", "file changed during upload")) {
            assertEquals(e, MediaRules.Next.NEXT_SCAN, MediaRules.next(result(false, e, null)))
        }
    }

    @Test
    fun nextCheckDelayForFilesStillBeingWritten() {
        val now = 1_800_000_000_000L
        fun mk(name: String, bytes: Int, ageMs: Long): File {
            val f = File(tmp.root, name)
            f.writeBytes(ByteArray(bytes) { 1 })
            assertTrue(f.setLastModified(now - ageMs))
            return f
        }
        val old = mk("IMG_1.jpg", 10, 60_000)
        assertNull(MediaRules.nextCheckDelayMs(listOf(old), emptySet(), now))

        val fresh = mk("VID_2.mp4", 10, 1_000)
        val dot = mk(".pending.jpg", 10, 0)
        val empty = mk("IMG_3.jpg", 0, 0)
        val txt = mk("notes.txt", 10, 0)
        val delay = MediaRules.nextCheckDelayMs(listOf(old, fresh, dot, empty, txt), emptySet(), now)
        assertNotNull(delay)
        // File mtimes may be stored with 1 s granularity: allow for that.
        assertTrue("delay $delay", delay!! in 1..MediaRules.QUIET_MS)
        // Already synced: no wait.
        assertNull(MediaRules.nextCheckDelayMs(listOf(fresh), setOf(Uploader.idFor(fresh)), now))
        // A file dated in the future is looked at again after at most a minute.
        val future = mk("IMG_4.jpg", 10, -3_600_000)
        assertEquals(MediaRules.MAX_RECHECK_MS, MediaRules.nextCheckDelayMs(listOf(future), emptySet(), now))
    }
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The other platform-free logic in core: message builders and parsers, pairing, config.json,
 * network helpers, Wi-Fi parsing, the card stack and media rules.
 */
class CoreLogicTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun j(s: String) = JSONObject(s)

    // ----- Msg builders ------------------------------------------------------------------

    @Test
    fun helloCarriesTokenOnlyWhenPresent() {
        val h = Msg.hello("Glass 1", "XE24", "2.0", "0123456789abcdef0123456789abcdef")
        assertEquals("hello", h.getString("type"))
        assertEquals("glass-explorer", h.getString("device"))
        assertEquals(2, h.getInt("version"))
        assertEquals("Glass 1", h.getString("model"))
        assertEquals("XE24", h.getString("firmware"))
        assertEquals("2.0", h.getString("app_version"))
        assertEquals("0123456789abcdef0123456789abcdef", h.getString("token"))
        assertFalse(Msg.hello("m", "f", "a", null).has("token"))
        assertFalse(Msg.hello("m", "f", "a", "").has("token"))
    }

    @Test
    fun statusAndOtherBuilders() {
        val s = Msg.status(140, true, 9216, 12288, null, null, false, true, 3600)
        assertEquals(100, s.getInt("battery"))
        assertTrue(s.getBoolean("charging"))
        assertEquals(9216L, s.getLong("storage_free_mb"))
        assertEquals(12288L, s.getLong("storage_total_mb"))
        assertFalse(s.has("wifi_ssid"))
        assertFalse(s.has("wifi_rssi"))
        assertFalse(s.getBoolean("mock_location"))
        assertTrue(s.getBoolean("screen_on"))
        assertEquals(3600L, s.getLong("uptime_s"))
        val s2 = Msg.status(50, false, 1, 2, "My iPhone", -52, true, false, 1)
        assertEquals("My iPhone", s2.getString("wifi_ssid"))
        assertEquals(-52, s2.getInt("wifi_rssi"))

        val ack = Msg.ack("c1", Msg.EVENT_SHOWN)
        assertEquals("ack", ack.getString("type"))
        assertEquals("c1", ack.getString("id"))
        assertEquals("shown", ack.getString("event"))
        assertEquals(3, ack.length())
        val fb = Msg.fileBegin("IMG.jpg:10", "IMG.jpg", 10, "image/jpeg", 1793491200123L)
        assertEquals(1793491200123L, fb.getLong("taken"))
        assertEquals(10L, fb.getLong("size"))
        assertEquals(0L, Msg.fileChunk("x", 0).getLong("offset"))
        assertEquals("x", Msg.fileEnd("x").getString("id"))
        assertEquals(640, Msg.frame(640, 360).getInt("w"))
        val wr = Msg.wifiResult("Net", false, "bad password")
        assertEquals("bad password", wr.getString("error"))
        assertFalse(Msg.wifiResult("Net", true).has("error"))
        assertEquals("ping", Msg.ping().getString("type"))
        assertEquals("pong", Msg.pong().getString("type"))
    }

    // ----- Card / NavState / LocationFix / ScreencastCmd ---------------------------------

    @Test
    fun cardDefaultsAndTtl() {
        val now = 1_800_000_000_000L
        val c = Card.from(j("{\"type\":\"card\",\"id\":\"c1\",\"title\":\"Hi\",\"text\":\"Hello\"}"), now)
        assertEquals("c1", c.id)
        assertEquals("Hi", c.title)
        assertEquals("Hello", c.text)
        assertEquals(Card.STYLE_INFO, c.style)
        assertEquals(now, c.time)
        assertFalse(c.chime)
        assertFalse(c.wake)
        assertNull(c.expiresAt)
        assertFalse(c.isExpired(now + 10_000_000))

        val n = Card.from(j("{\"type\":\"card\",\"id\":\"n\",\"title\":\"Messages\",\"text\":\"x\",\"style\":\"notification\"," +
            "\"chime\":true,\"wake\":true,\"ttl_s\":30,\"time\":1793491200123,\"source\":\"Shortcuts\"}"), now)
        assertTrue(n.isNotification)
        assertTrue(n.chime)
        assertTrue(n.wake)
        assertEquals(1793491200123L, n.time)
        assertEquals(now + 30_000, n.expiresAt)
        assertFalse(n.isExpired(now + 29_999))
        assertTrue(n.isExpired(now + 30_000))
        assertEquals("Shortcuts", n.source)

        val odd = Card.from(j("{\"type\":\"card\",\"id\":7,\"title\":null,\"style\":\"weird\",\"time\":1.7934912e12,\"ttl_s\":0}"), now)
        assertEquals("7", odd.id)
        assertEquals("", odd.title)
        assertEquals("", odd.text)
        assertEquals(Card.STYLE_INFO, odd.style)
        assertEquals(1793491200000L, odd.time)
        assertNull(odd.expiresAt)

        assertEquals("card-$now", Card.from(j("{\"type\":\"card\"}"), now).id)
    }

    @Test
    fun navStateParsing() {
        val nav = NavState.from(j("{\"type\":\"nav\",\"instruction\":\"Turn left onto King William St\",\"maneuver\":\"left\"," +
            "\"distance_m\":27.4,\"street\":\"King William St\",\"step\":2,\"steps_total\":5,\"eta_min\":7,\"remaining_m\":1234.5}"))
        assertEquals("left", nav.maneuver)
        assertEquals(27.4, nav.distanceM, 1e-9)
        assertEquals("25 m", nav.distanceText)
        assertEquals(2, nav.step)
        assertEquals(5, nav.stepsTotal)
        assertEquals(7, nav.etaMin)
        assertEquals("7 min · 1.2 km", nav.footerText)
        assertFalse(nav.arrived)
        assertFalse(nav.announce)
        assertTrue(nav.isNewStep(null))
        val unknown = NavState.from(j("{\"type\":\"nav\",\"maneuver\":\"roundabout_exit_3\",\"distance_m\":5,\"step\":2,\"steps_total\":5,\"announce\":true}"))
        assertEquals("straight", unknown.maneuver)
        assertTrue(unknown.announce)
        assertFalse(unknown.isNewStep(nav))
        assertEquals("", unknown.footerText)
        for (m in NavState.MANEUVERS) assertEquals(m, NavState.maneuverOf(m))
        assertEquals("straight", NavState.maneuverOf(null))
    }

    @Test
    fun locationFixParsing() {
        val f = LocationFix.from(j("{\"type\":\"location\",\"lat\":-34.9285,\"lon\":138.6007,\"acc_m\":5,\"alt_m\":50.5," +
            "\"speed_mps\":1.2,\"bearing\":-1,\"time\":1793491200123}"))!!
        assertEquals(-34.9285, f.lat, 1e-9)
        assertEquals(138.6007, f.lon, 1e-9)
        assertEquals(5.0, f.accM, 1e-9)
        assertEquals(50.5, f.altM!!, 1e-9)
        assertEquals(1.2, f.speedMps!!, 1e-9)
        assertNull(f.bearing)
        assertEquals(1793491200123L, f.time)
        val noAcc = LocationFix.from(j("{\"type\":\"location\",\"lat\":1,\"lon\":2}"), 99L)!!
        assertEquals(LocationFix.DEFAULT_ACCURACY_M, noAcc.accM, 1e-9)
        assertEquals(99L, noAcc.time)
        assertNull(LocationFix.from(j("{\"type\":\"location\",\"lon\":2}")))
        assertNull(LocationFix.from(j("{\"type\":\"location\",\"lat\":\"NaN\",\"lon\":2}")))
        assertNull(LocationFix.from(j("{\"type\":\"location\",\"lat\":91,\"lon\":2}")))
    }

    @Test
    fun screencastCommand() {
        val c = ScreencastCmd.from(j("{\"type\":\"screencast\",\"on\":true}"))
        assertTrue(c.on)
        assertEquals(2, c.fps)
        assertEquals(500L, c.intervalMs)
        assertEquals(5, ScreencastCmd.from(j("{\"type\":\"screencast\",\"on\":true,\"fps\":30}")).fps)
        assertEquals(1, ScreencastCmd.from(j("{\"type\":\"screencast\",\"on\":true,\"fps\":0}")).fps)
        assertFalse(ScreencastCmd.from(j("{\"type\":\"screencast\",\"on\":false}")).on)
    }

    // ----- Pairing -------------------------------------------------------------------------

    @Test
    fun welcomeAndPairing() {
        val paired = Welcome.from(j("{\"type\":\"welcome\",\"server\":\"GlassBridge iOS\",\"version\":2,\"phone_name\":\"Alexander's iPhone\"," +
            "\"pair_token\":\"0123456789abcdef0123456789abcdef\",\"pair_code\":\"0042\"}"))
        assertTrue(paired.isNewPairing)
        assertEquals("0123456789abcdef0123456789abcdef", paired.pairToken)
        assertEquals("0042", paired.pairCode)
        assertEquals("Alexander's iPhone", paired.phoneName)
        assertEquals(2, paired.version)
        val card = Pairing.pairedCard(paired, 5L)
        assertEquals("Paired", card.title)
        assertEquals("Alexander's iPhone\nCode 0042", card.text)
        assertTrue(card.wake)
        assertTrue(card.chime)
        assertEquals(Pairing.CARD_ID, card.id)

        val plain = Welcome.from(j("{\"type\":\"welcome\",\"server\":\"fake_phone\",\"version\":2,\"phone_name\":\"fake_phone\"}"))
        assertFalse(plain.isNewPairing)
        assertNull(plain.pairCode)
        assertEquals("iPhone", Welcome.from(j("{\"type\":\"welcome\"}")).phoneName)
        assertEquals("0042", Welcome.from(j("{\"type\":\"welcome\",\"pair_token\":\"abc\",\"pair_code\":42}")).pairCode)
        assertNull(Welcome.from(j("{\"type\":\"welcome\",\"pair_token\":\"  \",\"pair_code\":\"1234\"}")).pairToken)

        assertTrue(Pairing.isWellFormed("0123456789abcdef0123456789abcdef"))
        assertFalse(Pairing.isWellFormed("0123456789ABCDEF0123456789abcdef"))
        assertFalse(Pairing.isWellFormed("0123"))
        assertEquals("abc", Pairing.normalizeToken("  abc \n"))
        assertNull(Pairing.normalizeToken("a\u0000b"))
        assertNull(Pairing.normalizeToken("x".repeat(300)))

        val r = Rejected.from(j("{\"type\":\"rejected\",\"reason\":\"bad_token\",\"message\":\"Pair again\"}"))
        assertEquals(Rejected.BAD_TOKEN, r.reason)
        assertEquals("Pair again", r.message)
        assertEquals(Rejected.PAIRING_REQUIRED, Rejected.from(j("{\"type\":\"rejected\"}")).reason)
        assertTrue(Pairing.REJECTED_HINT.startsWith("Pair on your iPhone: GlassBridge"))
    }

    // ----- config.json -----------------------------------------------------------------------

    @Test
    fun glassConfigParsing() {
        val c = GlassConfig.parse("{\"host\":\"192.168.1.20\",\"port\":9191,\"invert_swipe\":true}")
        assertEquals("192.168.1.20", c.host)
        assertEquals(9191, c.port)
        assertTrue(c.invertSwipe)
        assertEquals(Endpoint("192.168.1.20", 9191, Endpoint.VIA_CONFIG), c.endpoint())

        val noHost = GlassConfig.parse("{\"invert_swipe\":true}")
        assertNull(noHost.host)
        assertNull(noHost.endpoint())
        assertTrue(noHost.invertSwipe)
        assertEquals(9090, noHost.port)

        assertEquals(9090, GlassConfig.parse("{\"host\":\"mac.local\"}").port)
        assertNull(GlassConfig.parse("{\"host\":\"  \"}").endpoint())
        assertEquals(9191, GlassConfig.parse("{\"host\":\"h\",\"port\":\"9191\"}").port)
        assertEquals(9090, GlassConfig.parse("{\"host\":\"h\",\"port\":70000}").port)
        assertEquals(9090, GlassConfig.parse("{\"host\":\"h\",\"port\":true}").port)
        assertFalse(GlassConfig.parse("{\"invert_swipe\":\"no\"}").invertSwipe)
        assertTrue(GlassConfig.parse("{\"invert_swipe\":1}").invertSwipe)
        assertNull(GlassConfig.parse("not json").host)
        assertNull(GlassConfig.parse("").host)
        assertNull(GlassConfig.parse(null).host)

        val f = File(tmp.root, "config.json")
        assertNull(GlassConfig.load(f).host)
        f.writeText("{\"host\":\"10.0.0.2\",\"port\":9090}")
        assertEquals("10.0.0.2", GlassConfig.load(f).host)
    }

    // ----- network helpers ------------------------------------------------------------------

    @Test
    fun netUtil() {
        // DhcpInfo stores 172.20.10.1 as 0x010A14AC (little-endian).
        assertEquals("172.20.10.1", NetUtil.ipv4FromLittleEndian(0x010A14AC))
        assertEquals("192.168.1.254", NetUtil.ipv4FromLittleEndian(0xFE01A8C0.toInt()))
        assertEquals("0.0.0.0", NetUtil.ipv4FromLittleEndian(0))
        for (last in 0..15) assertTrue("172.20.10.$last", NetUtil.isHotspotAddress("172.20.10.$last"))
        assertFalse(NetUtil.isHotspotAddress("172.20.10.16"))
        assertFalse(NetUtil.isHotspotAddress("172.20.11.1"))
        assertFalse(NetUtil.isHotspotAddress("192.168.1.1"))
        assertFalse(NetUtil.isHotspotAddress("172.20.10"))
        assertFalse(NetUtil.isHotspotAddress("172.20.10.300"))
        assertFalse(NetUtil.isHotspotAddress(null))
        assertEquals(Endpoint("172.20.10.1", 9090, Endpoint.VIA_HOTSPOT), NetUtil.hotspotEndpoint(0x010A14AC))
        assertNull(NetUtil.hotspotEndpoint(0))
        assertNull(NetUtil.hotspotEndpoint(0x0101A8C0)) // 192.168.1.1
        assertEquals("My iPhone", NetUtil.cleanSsid("\"My iPhone\""))
        assertEquals("Plain", NetUtil.cleanSsid("Plain"))
        assertNull(NetUtil.cleanSsid("<unknown ssid>"))
        assertNull(NetUtil.cleanSsid("0x"))
        assertNull(NetUtil.cleanSsid("\"\""))
        assertNull(NetUtil.cleanSsid(null))
    }

    // ----- Wi-Fi --------------------------------------------------------------------------

    @Test
    fun wifiNetworks() {
        val one = WifiNetwork.parseFile("{\"ssid\":\"My iPhone\",\"password\":\"secret123\",\"security\":\"WPA\"}")
        assertEquals(1, one.size)
        assertEquals("My iPhone", one[0].ssid)
        assertEquals(WifiNetwork.WPA, one[0].security)
        assertNull(one[0].problem())

        val many = WifiNetwork.parseFile("[{\"ssid\":\"A\",\"password\":\"12345678\"},{\"ssid\":\"B\"},{\"password\":\"x\"}," +
            "{\"ssid\":\"C\",\"password\":\"0123456789\",\"security\":\"wep\"},{\"ssid\":\"D\",\"security\":\"WPA2\",\"password\":\"short\"}]")
        assertEquals(listOf("A", "B", "C", "D"), many.map { it.ssid })
        assertEquals(listOf("WPA", "OPEN", "WEP", "WPA"), many.map { it.security })
        assertNotNull(many[3].problem())
        assertTrue(WifiNetwork.parseFile("garbage").isEmpty())
        assertTrue(WifiNetwork.parseFile("").isEmpty())

        assertEquals("WPA", WifiNetwork.normalizeSecurity("WPA3", "x"))
        assertEquals("WPA", WifiNetwork.normalizeSecurity("wpa2-psk", "x"))
        assertEquals("OPEN", WifiNetwork.normalizeSecurity("nopass", null))
        assertEquals("OPEN", WifiNetwork.normalizeSecurity(null, null))
        assertEquals("WPA", WifiNetwork.normalizeSecurity(null, "pw"))
        assertEquals("\"Net\"", WifiNetwork.quoted("Net"))
        assertTrue(WifiNetwork.isHexWepKey("0123456789"))
        assertTrue(WifiNetwork.isHexWepKey("0123456789abcdef0123456789"))
        assertFalse(WifiNetwork.isHexWepKey("012345678g"))
        assertEquals("0123456789", WifiNetwork.wepKeyValue("0123456789"))
        assertEquals("\"abcde\"", WifiNetwork.wepKeyValue("abcde"))
        assertEquals("\"passphrase\"", WifiNetwork.pskValue("passphrase"))
        val raw = "a".repeat(64)
        assertEquals(raw, WifiNetwork.pskValue(raw))
        assertNull(WifiNetwork(  "x", raw, WifiNetwork.WPA).problem())
        assertNotNull(WifiNetwork("x", null, WifiNetwork.WEP).problem())
        assertEquals(WifiNetwork.WPA, WifiNetwork.from(j("{\"ssid\":\"Z\",\"password\":\"12345678\",\"security\":\"WPA\"}"))!!.security)
        assertFalse(WifiNetwork("x", "secretpw", "WPA").toString().contains("secretpw"))
    }

    // ----- card stack ------------------------------------------------------------------------

    private fun card(id: String, ttlAt: Long? = null) =
        Card(id, "t$id", "x", null, 0L, Card.STYLE_INFO, false, false, null, ttlAt)

    @Test
    fun cardStack() {
        val s = CardStack()
        assertTrue(s.put(card("a")))
        assertTrue(s.put(card("b")))
        assertTrue(s.put(card("c")))
        assertEquals(listOf("c", "b", "a"), s.cards.map { it.id })
        assertFalse(s.put(card("a"))) // replaced, moves to the front
        assertEquals(listOf("a", "c", "b"), s.cards.map { it.id })
        assertTrue(s.markShown("a"))
        assertFalse(s.markShown("a"))
        assertFalse(s.markShown("zzz"))
        s.put(card("a"))
        assertTrue("a replaced card counts as new", s.markShown("a"))
        assertEquals("c", s.remove("c")!!.id)
        assertNull(s.remove("c"))
        assertEquals(listOf("a", "b"), s.cards.map { it.id })

        for (i in 0 until 30) s.put(card("n$i"))
        assertEquals(CardStack.MAX_CARDS, s.size)
        assertEquals("n29", s[0].id)
        assertEquals("n5", s[24].id)
        assertEquals(-1, s.indexOf("a"))

        s.clear()
        s.put(card("keep"))
        s.put(card("old", ttlAt = 1000L))
        s.put(card("new", ttlAt = 5000L))
        assertFalse(s.prune(999L))
        assertTrue(s.prune(1000L))
        assertEquals(listOf("new", "keep"), s.cards.map { it.id })
        assertTrue(s.prune(6000L))
        assertEquals(listOf("keep"), s.cards.map { it.id })

        // Keep the same card in view while the stack changes underneath.
        s.clear()
        s.put(card("x")); s.put(card("y")); s.put(card("z")) // z y x
        assertEquals(2, s.positionAfterChange("x", 0))
        s.put(card("w")) // w z y x
        assertEquals(3, s.positionAfterChange("x", 2))
        s.remove("x")
        assertEquals(2, s.positionAfterChange("x", 3))
        s.clear()
        assertEquals(0, s.positionAfterChange("x", 3))
    }

    // ----- media rules -------------------------------------------------------------------

    @Test
    fun mediaRulesAndIds() {
        assertEquals("image/jpeg", Uploader.mimeFor("IMG_0001.JPG"))
        assertEquals("image/jpeg", Uploader.mimeFor("a.jpeg"))
        assertEquals("image/png", Uploader.mimeFor("a.png"))
        assertEquals("video/mp4", Uploader.mimeFor("VID.mp4"))
        assertEquals("video/3gpp", Uploader.mimeFor("v.3gp"))
        assertNull(Uploader.mimeFor("notes.txt"))
        assertNull(Uploader.mimeFor("noext"))
        assertNull(Uploader.mimeFor("trailingdot."))
        assertEquals("IMG.jpg:1234", Uploader.idFor("IMG.jpg", 1234))

        val now = 1_000_000L
        assertTrue(MediaRules.isCandidate("a.jpg", 10, now - 3000, now))
        assertFalse(MediaRules.isCandidate("a.jpg", 10, now - 2999, now))
        assertFalse(MediaRules.isCandidate(".pending.jpg", 10, 0, now))
        assertFalse(MediaRules.isCandidate("a.jpg", 0, 0, now))
        assertFalse(MediaRules.isCandidate("a.txt", 10, 0, now))

        val dir = tmp.newFolder("Camera")
        fun mk(name: String, bytes: Int, mtime: Long): File =
            File(dir, name).also { it.writeBytes(ByteArray(bytes)); it.setLastModified(mtime) }
        val t = System.currentTimeMillis() - 60_000
        val newer = mk("b.jpg", 5, t)
        val older = mk("a.mp4", 5, t - 10_000)
        val synced = mk("c.jpg", 7, t - 20_000)
        mk(".hidden.jpg", 5, t)
        mk("empty.jpg", 0, t)
        mk("fresh.jpg", 5, System.currentTimeMillis())
        val pending = MediaRules.pending(dir.listFiles()!!.toList(), setOf(Uploader.idFor(synced)), System.currentTimeMillis())
        assertEquals(listOf(older.name, newer.name), pending.map { it.name })
    }

    // ----- Json accessors ----------------------------------------------------------------

    @Test
    fun jsonAccessorsTreatNullAndNumbersConsistently() {
        val o = j("{\"s\":\"x\",\"n\":null,\"i\":5,\"f\":2.5,\"big\":12345678901234,\"b\":false,\"bs\":\"TRUE\",\"neg\":-2.5}")
        assertNull(Json.str(o, "n")) // Android's optString would say "null"
        assertNull(Json.raw(o, "n"))
        assertFalse(Json.has(o, "n"))
        assertNull(Json.str(o, "i"))
        assertEquals("5", Json.text(o, "i"))
        assertEquals(5, Json.int(o, "i"))
        assertEquals(3L, Json.long(o, "f"))
        assertEquals(-2L, Json.long(o, "neg")) // Math.round rounds half up: -2.5 -> -2
        assertEquals(12345678901234L, Json.long(o, "big"))
        assertNull(Json.int(o, "big"))
        assertEquals(false, Json.bool(o, "b"))
        assertEquals(true, Json.bool(o, "bs"))
        assertNull(Json.bool(o, "i"))
        assertNull(Json.long(o, "s"))
        assertTrue(Json.isInteger(5))
        assertFalse(Json.isInteger(5.0))
    }
}

package au.interstellr.glassbridge.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * [MessageRouter] on real wire traffic: BridgeConnection against
 * `python3 tools/fake_phone.py --selftest --port N` (GLASSBRIDGE_TEST_PORT=N), with a handler
 * that does what BridgeService does on the JVM side of each message: store the pair token on
 * `welcome` and send `status`, ack `shown` for each card, and feed `file_ack` to the uploader.
 * Skipped unless GLASSBRIDGE_TEST_PORT is set.
 */
class LiveRouterTest {

    private var port = 0
    private var host = "127.0.0.1"
    private val clients = ArrayList<BridgeConnection>()

    /** A JVM stand-in for BridgeService's GlassHandler. */
    private class GlassLike : GlassHandler, BridgeConnection.Listener {
        lateinit var conn: BridgeConnection
        @Volatile var token: String? = null
        val routes = ArrayList<String>() // guarded by itself
        val cards = ArrayList<Card>() // guarded by routes
        @Volatile var welcome: Welcome? = null
        @Volatile var syncEnabled: Boolean? = null
        @Volatile var cast: ScreencastCmd? = null

        override fun onConnecting() {}
        override fun onConnected(endpoint: Endpoint) {}
        override fun onDisconnected(reason: String) {}
        override fun onFrame(frame: Frame) {
            val r = MessageRouter.route(frame, this)
            synchronized(routes) { routes.add(frame.type + ":" + r) }
        }

        override fun onWelcome(welcome: Welcome) {
            if (welcome.isNewPairing) token = welcome.pairToken
            this.welcome = welcome
            conn.sendAsync(Msg.status(87, false, 9000, 12000, "My iPhone", -50, true, true, 100))
        }
        override fun onRejected(rejected: Rejected) {}
        override fun onPong() {}
        override fun onRequestStatus() {}
        override fun onCard(card: Card) {
            synchronized(routes) { cards.add(card) }
            if (card.id == "st-card") conn.sendAsync(Msg.ack(card.id, Msg.EVENT_SHOWN))
        }
        override fun onDismiss(id: String) {}
        override fun onSpeak(text: String) {}
        override fun onNav(nav: NavState) {}
        override fun onNavEnd() {}
        override fun onLocation(fix: LocationFix) {}
        override fun onSync(enabled: Boolean) { syncEnabled = enabled }
        override fun onFileAck(frame: Frame) {}
        override fun onScreencast(cmd: ScreencastCmd) { cast = cmd }
        override fun onWifiAdd(network: WifiNetwork?, ssid: String) {}
        override fun onIgnored(frame: Frame, why: String) {}

        fun card(id: String, timeoutMs: Long = 10_000): Card {
            val end = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < end) {
                synchronized(routes) { cards.firstOrNull { it.id == id }?.let { return it } }
                Thread.sleep(20)
            }
            throw AssertionError("no card $id; routes: " + synchronized(routes) { ArrayList(routes) })
        }

        fun awaitWelcome(timeoutMs: Long = 10_000): Welcome {
            val end = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < end) {
                welcome?.let { return it }
                Thread.sleep(20)
            }
            throw AssertionError("no welcome")
        }
    }

    @Before
    fun setUp() {
        val p = (System.getenv("GLASSBRIDGE_TEST_PORT") ?: System.getProperty("glassbridge.testPort"))?.trim()
        assumeTrue("GLASSBRIDGE_TEST_PORT not set: LiveRouterTest skipped", !p.isNullOrEmpty())
        port = p!!.toInt()
        host = (System.getenv("GLASSBRIDGE_TEST_HOST") ?: System.getProperty("glassbridge.testHost"))
            ?.trim()?.takeIf { it.isNotEmpty() } ?: "127.0.0.1"
    }

    @After
    fun tearDown() {
        for (c in clients) c.stop()
    }

    private fun connect(g: GlassLike): BridgeConnection {
        val c = BridgeConnection({ Endpoint(host, port, "test") }, { Msg.hello("Glass 1", "XE24", "2.0-liveroutertest", g.token) }, g)
        g.conn = c
        clients.add(c)
        c.start()
        return c
    }

    @Test
    fun pairStatusCardAckAndReconnectWithToken() {
        val g = GlassLike()
        val c = connect(g)

        val w = g.awaitWelcome()
        assertTrue("first hello has no token, so fake_phone pairs it", w.isNewPairing)
        assertTrue(Pairing.isWellFormed(g.token))
        assertEquals("fake_phone", w.phoneName)

        // status (sent from onWelcome) comes back as card st-card; its ack shown as st-ack.
        val stCard = g.card("st-card")
        assertTrue(stCard.text, stCard.text.contains("battery=87"))
        assertEquals("fake_phone", stCard.source)
        assertTrue("card time is epoch ms above 2^31", stCard.time > Int.MAX_VALUE)
        val stAck = g.card("st-ack")
        assertEquals("ack st-card shown", stAck.text)
        g.card("st-pong") // the ping fake_phone sent was answered by BridgeConnection

        assertEquals(true, g.syncEnabled)
        assertNotNull(g.cast)
        assertTrue(g.cast!!.on)
        assertEquals(2, g.cast!!.fps)
        val routes = synchronized(g.routes) { ArrayList(g.routes) }
        assertTrue(routes.toString(), routes.contains("welcome:onWelcome"))
        assertTrue(routes.toString(), routes.contains("sync:onSync"))
        assertTrue(routes.toString(), routes.contains("screencast:onScreencast"))
        assertFalse("ping never reaches the router: $routes", routes.any { it.startsWith("ping:") })
        c.stop()

        // Reconnect with the stored token: accepted, no pair fields.
        val token = g.token
        val g2 = GlassLike()
        g2.token = token
        connect(g2)
        val w2 = g2.awaitWelcome()
        assertFalse("stored token should be accepted without pairing", w2.isNewPairing)
        assertEquals(token, g2.token)
        g2.card("st-card")
    }

    /** Every GlassHandler method as a no-op. */
    private open class NoopHandler : GlassHandler {
        override fun onWelcome(welcome: Welcome) {}
        override fun onRejected(rejected: Rejected) {}
        override fun onPong() {}
        override fun onRequestStatus() {}
        override fun onCard(card: Card) {}
        override fun onDismiss(id: String) {}
        override fun onSpeak(text: String) {}
        override fun onNav(nav: NavState) {}
        override fun onNavEnd() {}
        override fun onLocation(fix: LocationFix) {}
        override fun onSync(enabled: Boolean) {}
        override fun onFileAck(frame: Frame) {}
        override fun onScreencast(cmd: ScreencastCmd) {}
        override fun onWifiAdd(network: WifiNetwork?, ssid: String) {}
        override fun onIgnored(frame: Frame, why: String) {}
    }

    @Test
    fun uploadAckIsRoutedToTheUploader() {
        val routedAcks = ArrayList<String>()
        lateinit var uploader: Uploader
        val handler = object : NoopHandler() {
            override fun onFileAck(frame: Frame) {
                synchronized(routedAcks) { routedAcks.add(frame.str("id") ?: "") }
                uploader.handleFrame(frame)
            }
        }
        val listener = object : BridgeConnection.Listener {
            override fun onConnecting() {}
            override fun onConnected(endpoint: Endpoint) {}
            override fun onDisconnected(reason: String) {}
            override fun onFrame(frame: Frame) {
                MessageRouter.route(frame, handler)
            }
        }
        val c = BridgeConnection({ Endpoint(host, port, "test") }, { Msg.hello("Glass 1", "XE24", "2.0-liveroutertest", null) }, listener)
        clients.add(c)
        uploader = Uploader(c, 10_000)
        c.start()
        val end = System.currentTimeMillis() + 10_000
        while (!c.isAccepted && System.currentTimeMillis() < end) Thread.sleep(20)
        assertTrue("not accepted by fake_phone", c.isAccepted)

        val f = java.io.File.createTempFile("IMG_router", ".jpg")
        try {
            val data = ByteArray(300 * 1024) { (it * 31 + 7).toByte() }
            f.writeBytes(data)
            val r = uploader.upload(f)
            assertTrue("upload failed: ${r.error}", r.ok)
            assertEquals(TestUtil.sha256Hex(data), r.sha256)
            assertEquals(Json.str(r.ack!!, "sha256"), r.sha256)
            assertEquals(listOf(Uploader.idFor(f)), synchronized(routedAcks) { ArrayList(routedAcks) })
        } finally {
            f.delete()
        }
    }
}

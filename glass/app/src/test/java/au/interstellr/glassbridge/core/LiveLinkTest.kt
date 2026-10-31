package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The real Kotlin BridgeConnection and Uploader over TCP against
 * `python3 tools/fake_phone.py --selftest --port N`, with GLASSBRIDGE_TEST_PORT=N.
 * Skipped unless GLASSBRIDGE_TEST_PORT is set (GLASSBRIDGE_TEST_HOST defaults to 127.0.0.1).
 *
 * The selftest script (tools/fake_phone.py): a hello without the current token is paired
 * (welcome carries pair_token and pair_code), then the phone sends sync, screencast and a
 * ping; it answers pong, status, ack st-card, uploads, frames and ping with cards whose ids
 * are st-pong, st-card, st-ack, st-frame and st-ping. Heartbeat replies can arrive in
 * between, so frames are matched by type and id.
 */
class LiveLinkTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private var port = 0
    private var host = "127.0.0.1"
    private val clients = ArrayList<BridgeConnection>()

    /** Records every frame; waits for one matching a predicate. */
    private class Rec : BridgeConnection.Listener {
        private val frames = ArrayList<Frame>()
        @Volatile var uploader: Uploader? = null
        val connected = CountDownLatch(1)
        @Volatile var disconnects = 0

        override fun onConnecting() {}
        override fun onConnected(endpoint: Endpoint) { connected.countDown() }
        override fun onDisconnected(reason: String) { disconnects++ }
        override fun onFrame(frame: Frame) {
            uploader?.handleFrame(frame)
            synchronized(frames) { frames.add(frame) }
        }

        fun mark(): Int = synchronized(frames) { frames.size }

        fun all(): List<Frame> = synchronized(frames) { ArrayList(frames) }

        fun indexOf(from: Int, pred: (Frame) -> Boolean): Int = synchronized(frames) {
            for (i in from until frames.size) if (pred(frames[i])) return i
            -1
        }

        fun await(what: String, from: Int = 0, timeoutMs: Long = 10_000, pred: (Frame) -> Boolean): Frame {
            val end = System.currentTimeMillis() + timeoutMs
            while (true) {
                val i = indexOf(from, pred)
                if (i >= 0) return synchronized(frames) { frames[i] }
                if (System.currentTimeMillis() > end) {
                    throw AssertionError("no $what within $timeoutMs ms; received: " +
                        all().joinToString("\n  ", "\n  ") { Frame.describe(it.obj, it.payload, 200) })
                }
                Thread.sleep(20)
            }
        }

        fun awaitCard(id: String, from: Int = 0, timeoutMs: Long = 10_000): Frame =
            await("card $id", from, timeoutMs) { it.type == "card" && it.str("id") == id }
    }

    @Before
    fun setUp() {
        val p = (System.getenv("GLASSBRIDGE_TEST_PORT") ?: System.getProperty("glassbridge.testPort"))?.trim()
        assumeTrue("GLASSBRIDGE_TEST_PORT not set: LiveLinkTest skipped", !p.isNullOrEmpty())
        port = p!!.toInt()
        host = (System.getenv("GLASSBRIDGE_TEST_HOST") ?: System.getProperty("glassbridge.testHost"))
            ?.trim()?.takeIf { it.isNotEmpty() } ?: "127.0.0.1"
        // Shortened heartbeat so the client's own ping shows up within the test.
        BridgeConnection.PING_AFTER_MS = 1_500
        BridgeConnection.DEAD_AFTER_MS = 6_000
        BridgeConnection.WATCHDOG_TICK_MS = 100
        BridgeConnection.BACKOFF_START_MS = 500
        BridgeConnection.BACKOFF_MAX_MS = 2_000
    }

    @After
    fun tearDown() {
        for (c in clients) c.stop()
        BridgeConnection.resetTimings()
    }

    private fun connect(token: String? = null): Pair<BridgeConnection, Rec> {
        val rec = Rec()
        val c = BridgeConnection(
            { Endpoint(host, port, "test") },
            { Msg.hello("Glass 1", "XE24", "2.0-livelinktest", token) },
            rec
        )
        clients.add(c)
        c.start()
        assertTrue("couldn't connect to fake_phone at $host:$port (is it running with --selftest?)",
            rec.connected.await(10, TimeUnit.SECONDS))
        return c to rec
    }

    private fun welcomeOf(rec: Rec): Welcome = Welcome.from(rec.await("welcome") { it.type == "welcome" }.obj)

    @Test
    fun helloWelcomePairsThenTokenIsAccepted() {
        val (c, rec) = connect(token = null)
        val wf = rec.await("welcome") { it.type == "welcome" }
        assertEquals("fake_phone", wf.str("server"))
        assertEquals(2, wf.int("version"))
        val w = Welcome.from(wf.obj)
        assertTrue("welcome should carry pair fields: ${wf.obj}", w.isNewPairing)
        assertTrue("pair_token ${w.pairToken}", Pairing.isWellFormed(w.pairToken))
        assertTrue("pair_code ${w.pairCode}", w.pairCode!!.matches(Regex("^[0-9]{4}$")))
        assertEquals("fake_phone", w.phoneName)
        assertEquals("fake_phone\nCode ${w.pairCode}", Pairing.pairedCard(w).text)

        // After welcome: sync, then screencast, then a ping that BridgeConnection answers.
        val sync = rec.await("sync") { it.type == "sync" }
        assertEquals(true, sync.bool("enabled"))
        val cast = ScreencastCmd.from(rec.await("screencast") { it.type == "screencast" }.obj)
        assertTrue(cast.on)
        assertEquals(2, cast.fps)
        val iWelcome = rec.indexOf(0) { it.type == "welcome" }
        assertTrue(iWelcome < rec.indexOf(0) { it.type == "sync" })
        assertTrue(rec.indexOf(0) { it.type == "sync" } < rec.indexOf(0) { it.type == "screencast" })
        rec.awaitCard("st-pong")
        assertTrue(c.isAccepted)
        c.stop()

        // Reconnect with the stored token: accepted without pair fields.
        val (c2, rec2) = connect(token = w.pairToken)
        val w2 = welcomeOf(rec2)
        assertFalse("welcome after a good token must not carry pair fields", w2.isNewPairing)
        assertNull(w2.pairCode)
        rec2.awaitCard("st-pong")
        assertTrue(c2.isAccepted)
    }

    @Test
    fun statusGetsACardAndAckGetsAReply() {
        val (c, rec) = connect()
        welcomeOf(rec)
        val m = rec.mark()
        assertTrue(c.send(Msg.status(87, false, 9216, 12288, "FakeHotspot", -52, true, true, 123)))
        val cf = rec.awaitCard("st-card", m)
        val card = Card.from(cf.obj)
        assertEquals("Selftest", card.title)
        assertEquals("status battery=87", card.text)
        assertEquals("fake_phone", card.source)
        assertEquals(Card.STYLE_INFO, card.style)
        assertTrue("card time ${card.time} must be epoch ms read as a long", card.time > (1L shl 31))
        assertEquals(87, cf.int("battery"))

        val m2 = rec.mark()
        assertTrue(c.send(Msg.ack("st-card", Msg.EVENT_SHOWN)))
        val ack = rec.awaitCard("st-ack", m2)
        assertEquals("ack st-card shown", ack.str("text"))
        assertEquals("st-card", ack.str("ack_id"))
        assertEquals("shown", ack.str("event"))
    }

    @Test
    fun upload600KbInThreeChunksMatchesFakePhoneSha256() {
        val (c, rec) = connect()
        welcomeOf(rec)
        assertEquals(true, rec.await("sync") { it.type == "sync" }.bool("enabled"))

        val data = ByteArray(600 * 1024).also { Random(600).nextBytes(it) }
        val file = File(tmp.root, "IMG_20261101_090000.jpg")
        file.writeBytes(data)
        val chunkSizes = ArrayList<Int>()
        val counting = object : FrameSender {
            override fun send(obj: JSONObject, payload: ByteArray?, length: Int): Boolean {
                if (Json.str(obj, "type") == "file_chunk") synchronized(chunkSizes) { chunkSizes.add(length) }
                return c.send(obj, payload, length)
            }
        }
        val up = Uploader(counting, ackTimeoutMs = 30_000)
        rec.uploader = up
        val r = up.upload(file)
        assertTrue("upload failed: ${r.error}", r.ok)
        assertEquals("IMG_20261101_090000.jpg:614400", r.id)
        assertEquals(listOf(262144, 262144, 90112), synchronized(chunkSizes) { ArrayList(chunkSizes) })
        val ack = r.ack!!
        val local = TestUtil.sha256Hex(data)
        assertEquals("fake_phone's sha256 of the received bytes", local, Json.str(ack, "sha256"))
        assertEquals(local, r.sha256)
        assertEquals(614400L, Json.long(ack, "received"))
        assertEquals(true, Json.bool(ack, "ok"))

        // A re-upload of a completed id is acked ok with the same hash (stable ids across retries).
        val again = up.upload(file)
        assertTrue("re-upload failed: ${again.error}", again.ok)
        assertEquals(local, Json.str(again.ack!!, "sha256"))
    }

    @Test
    fun screencastFrameArrivesIntact() {
        val (c, rec) = connect()
        welcomeOf(rec)
        assertTrue(ScreencastCmd.from(rec.await("screencast") { it.type == "screencast" }.obj).on)
        val jpeg = ByteArray(30_000).also { Random(7).nextBytes(it) }
        jpeg[0] = 0xFF.toByte(); jpeg[1] = 0xD8.toByte(); jpeg[2] = 0xFF.toByte(); jpeg[3] = 0xE0.toByte()
        jpeg[jpeg.size - 2] = 0xFF.toByte(); jpeg[jpeg.size - 1] = 0xD9.toByte()
        val m = rec.mark()
        val sent = CountDownLatch(1)
        var ok = false
        c.sendAsync(Msg.frame(640, 360), jpeg) { r -> ok = r; sent.countDown() }
        assertTrue(sent.await(10, TimeUnit.SECONDS))
        assertTrue("sendAsync reported failure", ok)
        val card = rec.awaitCard("st-frame", m)
        assertEquals("frame 640x360 30000 bytes", card.str("text"))
        assertEquals(640, card.int("w"))
        assertEquals(360, card.int("h"))
        assertEquals(30000, card.int("size"))
        assertEquals(TestUtil.sha256Hex(jpeg), card.str("sha256"))
        assertEquals(true, card.bool("jpeg"))
    }

    @Test
    fun pingIsAnsweredWithPong() {
        BridgeConnection.PING_AFTER_MS = 60_000 // no automatic pings in this test
        BridgeConnection.DEAD_AFTER_MS = 120_000
        val (c, rec) = connect()
        welcomeOf(rec)
        rec.awaitCard("st-pong") // the phone's ping was answered
        val m = rec.mark()
        assertTrue(c.send(Msg.ping()))
        rec.await("pong", m) { it.type == "pong" }
        val card = rec.awaitCard("st-ping", m)
        assertEquals("ping answered", card.str("text"))
    }

    @Test
    fun clientHeartbeatPingsAfterSilence() {
        val (c, rec) = connect()
        welcomeOf(rec)
        rec.awaitCard("st-pong")
        val m = rec.mark()
        // Nothing sent by the test: the watchdog pings after PING_AFTER_MS (1.5 s) of silence.
        rec.await("pong for the watchdog's ping", m, 8_000) { it.type == "pong" }
        assertNotNull(rec.awaitCard("st-ping", m, 8_000))
        assertTrue(c.isConnected)
        assertEquals("the link must not have dropped", 0, rec.disconnects)
    }
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * BridgeConnection against a scripted in-JVM server on 127.0.0.1 (no Python needed):
 * hello, ping handling, heartbeat, watchdog, backoff, the 5 s retry after `rejected`,
 * protocol errors and stop().
 */
class BridgeConnectionTest {

    private lateinit var server: ServerSocket
    private val conns = Collections.synchronizedList(ArrayList<Socket>())
    private var bc: BridgeConnection? = null

    /** Records listener calls in order, as text. */
    private class Rec : BridgeConnection.Listener {
        val events = LinkedBlockingQueue<String>()
        val frames = LinkedBlockingQueue<Frame>()
        override fun onConnecting() { events.add("connecting") }
        override fun onConnected(endpoint: Endpoint) { events.add("connected") }
        override fun onFrame(frame: Frame) { events.add("frame:" + frame.type); frames.add(frame) }
        override fun onDisconnected(reason: String) { events.add("disconnected:$reason") }

        fun next(timeoutMs: Long = 5000): String =
            events.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: throw AssertionError("no listener event within $timeoutMs ms")

        fun waitFor(prefix: String, timeoutMs: Long = 5000): String {
            val end = System.currentTimeMillis() + timeoutMs
            while (true) {
                val left = end - System.currentTimeMillis()
                if (left <= 0) throw AssertionError("no '$prefix' event within $timeoutMs ms")
                val e = events.poll(left, TimeUnit.MILLISECONDS) ?: continue
                if (e.startsWith(prefix)) return e
            }
        }
    }

    /** Server-side view of one accepted connection. */
    private inner class Peer(val sock: Socket) {
        val reader = FrameReader(sock.getInputStream())
        val writer = FrameWriter(sock.getOutputStream())
        fun read(): Frame? = reader.read()
        fun send(o: JSONObject, p: ByteArray? = null) = writer.write(o, p)
    }

    @Before
    fun setUp() {
        server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        server.soTimeout = 15_000
        BridgeConnection.WATCHDOG_TICK_MS = 50
        BridgeConnection.BACKOFF_START_MS = 100
        BridgeConnection.BACKOFF_MAX_MS = 400
        BridgeConnection.REJECTED_RETRY_MS = 300
        BridgeConnection.PING_AFTER_MS = 60_000
        BridgeConnection.DEAD_AFTER_MS = 120_000
    }

    @After
    fun tearDown() {
        bc?.stop()
        for (s in conns) try { s.close() } catch (e: Exception) {}
        server.close()
        BridgeConnection.resetTimings()
    }

    private fun endpoint() = Endpoint("127.0.0.1", server.localPort, "test")

    private fun startClient(rec: Rec, resolve: () -> Endpoint? = { endpoint() }, token: String? = null): BridgeConnection {
        val c = BridgeConnection(resolve, { Msg.hello("Glass 1", "XE24", "test", token) }, rec)
        bc = c
        c.start()
        return c
    }

    private fun accept(): Peer {
        val s = server.accept()
        s.soTimeout = 15_000
        conns.add(s)
        return Peer(s)
    }

    @Test
    fun helloFirstThenFramesPingAnsweredAndNotForwarded() {
        val rec = Rec()
        val c = startClient(rec, token = "0123456789abcdef0123456789abcdef")
        val p = accept()
        val hello = p.read()!!
        assertEquals("hello", hello.type)
        assertEquals("glass-explorer", hello.str("device"))
        assertEquals("0123456789abcdef0123456789abcdef", hello.str("token"))
        assertEquals("connecting", rec.next())
        assertEquals("connected", rec.next())
        assertTrue(c.isConnected)
        assertFalse(c.isAccepted)

        p.send(JSONObject().put("type", "welcome").put("server", "t").put("version", 2).put("phone_name", "Test"))
        assertEquals("frame:welcome", rec.next())
        p.send(Msg.ping())
        assertEquals("pong", p.read()!!.type) // answered by BridgeConnection itself
        p.send(JSONObject().put("type", "card").put("id", "c1").put("title", "Hi").put("text", "Hello"))
        assertEquals("frame:card", rec.next()) // the ping was not forwarded
        assertTrue(c.isAccepted)

        // send() from the client side, with a payload.
        assertTrue(c.send(Msg.frame(2, 2), byteArrayOf(-1, -40, -1, 0)))
        val fr = p.read()!!
        assertEquals("frame", fr.type)
        assertEquals(4, fr.payload!!.size)

        val done = CountDownLatch(1)
        var asyncOk = false
        c.sendAsync(Msg.ack("c1", Msg.EVENT_SHOWN)) { ok -> asyncOk = ok; done.countDown() }
        assertEquals("ack", p.read()!!.type)
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertTrue(asyncOk)

        p.sock.close()
        assertTrue(rec.next().startsWith("disconnected:"))
        assertFalse(c.isConnected)
        assertFalse(c.send(Msg.ping()))
    }

    @Test
    fun heartbeatPingsAfterSilenceAndDropsAtDeadline() {
        BridgeConnection.PING_AFTER_MS = 300
        BridgeConnection.DEAD_AFTER_MS = 900
        val rec = Rec()
        startClient(rec)
        val p = accept()
        assertEquals("hello", p.read()!!.type)
        val t0 = System.currentTimeMillis()
        assertEquals("ping", p.read()!!.type)
        val pingAt = System.currentTimeMillis() - t0
        assertTrue("ping after ${pingAt} ms", pingAt in 200..800)
        // Answering resets the silence timer: no disconnect at 900 ms from the start.
        p.send(Msg.pong())
        assertEquals("frame:pong", rec.waitFor("frame:"))
        // Then say nothing: exactly one more ping, then the link is dropped.
        assertEquals("ping", p.read()!!.type)
        val reason = rec.waitFor("disconnected:", 5000)
        assertTrue(reason, reason.contains("nothing received"))
    }

    @Test
    fun watchdogUnblocksAReaderStuckMidPayload() {
        BridgeConnection.PING_AFTER_MS = 200
        BridgeConnection.DEAD_AFTER_MS = 600
        val rec = Rec()
        startClient(rec)
        val p = accept()
        p.read()
        // Header promising 1000 bytes, then only 10 of them.
        p.sock.getOutputStream().write("{\"type\":\"file_chunk\",\"id\":\"x\",\"offset\":0,\"bytes\":1000}\n0123456789".toByteArray())
        p.sock.getOutputStream().flush()
        val reason = rec.waitFor("disconnected:", 5000)
        assertTrue(reason, reason.contains("nothing received"))
    }

    @Test
    fun protocolErrorDropsTheLink() {
        val rec = Rec()
        startClient(rec)
        val p = accept()
        p.read()
        p.sock.getOutputStream().write("this is not json\n".toByteArray())
        val reason = rec.waitFor("disconnected:")
        assertTrue(reason, reason.contains("protocol error"))
    }

    @Test
    fun rejectedRetriesAfterTheFixedDelayAndClosesAtOnce() {
        BridgeConnection.BACKOFF_START_MS = 2000 // so a 300 ms retry can only be the rejected rule
        BridgeConnection.BACKOFF_MAX_MS = 4000
        val rec = Rec()
        startClient(rec)
        val p1 = accept()
        p1.read()
        p1.send(JSONObject().put("type", "rejected").put("reason", "pairing_required").put("message", "Pair first"))
        // The phone keeps the socket open here; Glass must close on its own.
        assertEquals("frame:rejected", rec.waitFor("frame:"))
        val reason = rec.waitFor("disconnected:")
        assertTrue(reason, reason.contains("rejected (pairing_required)"))
        val t0 = System.currentTimeMillis()
        val p2 = accept()
        val gap = System.currentTimeMillis() - t0
        assertEquals("hello", p2.read()!!.type)
        assertTrue("reconnected after $gap ms", gap in 150..1500)
    }

    @Test
    fun backoffDoublesToTheCapWhileNothingIsFound() {
        val times = Collections.synchronizedList(ArrayList<Long>())
        val rec = Rec()
        startClient(rec, resolve = { times.add(System.currentTimeMillis()); null })
        val end = System.currentTimeMillis() + 5000
        while (times.size < 6 && System.currentTimeMillis() < end) Thread.sleep(20)
        bc!!.stop()
        assertTrue("attempts: ${times.size}", times.size >= 6)
        val gaps = (1 until 6).map { times[it] - times[it - 1] }
        // Expected 100, 200, 400, 400, 400 ms.
        val want = listOf(100L, 200L, 400L, 400L, 400L)
        for (i in gaps.indices) {
            assertTrue("gap $i was ${gaps[i]} ms, want about ${want[i]}", gaps[i] >= want[i] - 20 && gaps[i] < want[i] + 400)
        }
    }

    @Test
    fun welcomedSessionResetsTheBackoffAndRetryNowSkipsTheWait() {
        BridgeConnection.BACKOFF_START_MS = 300
        BridgeConnection.BACKOFF_MAX_MS = 30_000
        val rec = Rec()
        val c = startClient(rec)
        val p1 = accept()
        p1.read()
        p1.send(JSONObject().put("type", "welcome").put("phone_name", "T"))
        rec.waitFor("frame:welcome")
        p1.sock.close()
        rec.waitFor("disconnected:")
        val t0 = System.currentTimeMillis()
        val p2 = accept()
        val gap = System.currentTimeMillis() - t0
        assertTrue("reconnect after a welcomed session took $gap ms", gap < 1500)
        p2.read()
        p2.sock.close() // no welcome this time: the next wait doubles (600 ms) ...
        rec.waitFor("disconnected:")
        Thread.sleep(50)
        c.retryNow() // ... unless retryNow() cuts it short
        val t1 = System.currentTimeMillis()
        accept().read()
        assertTrue("retryNow didn't skip the wait", System.currentTimeMillis() - t1 < 400)
    }

    @Test
    fun stopEndsTheLinkAndTheLoop() {
        val rec = Rec()
        val attempts = Collections.synchronizedList(ArrayList<Long>())
        val c = startClient(rec, resolve = { attempts.add(1); endpoint() })
        val p = accept()
        p.read()
        rec.waitFor("connected")
        c.stop()
        val reason = rec.waitFor("disconnected:")
        assertTrue(reason, reason.contains("stopped"))
        val n = attempts.size
        Thread.sleep(600)
        assertEquals("no attempts after stop()", n, attempts.size)
        assertFalse(c.send(Msg.ping()))
    }

    @Test
    fun onRetryWaitComesBeforeEveryWaitWithItsLength() {
        // BridgeService lets the CPU sleep again here (the 60 s alarm tick's wake lock).
        val waits = LinkedBlockingQueue<Long>()
        val listener = object : BridgeConnection.Listener {
            override fun onConnecting() {}
            override fun onConnected(endpoint: Endpoint) {}
            override fun onFrame(frame: Frame) {}
            override fun onDisconnected(reason: String) {}
            override fun onRetryWait(ms: Long) { waits.add(ms) }
        }
        val c = BridgeConnection({ null }, { Msg.hello("Glass 1", "XE24", "test", null) }, listener)
        bc = c
        c.start()
        assertEquals(100L, waits.poll(3, TimeUnit.SECONDS))
        assertEquals(200L, waits.poll(3, TimeUnit.SECONDS))
        assertEquals(400L, waits.poll(3, TimeUnit.SECONDS))
    }

    @Test
    fun connectFailureIsRetried() {
        val dead = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val deadPort = dead.localPort
        dead.close() // nothing listens there now
        val tries = Collections.synchronizedList(ArrayList<Long>())
        val rec = Rec()
        startClient(rec, resolve = {
            tries.add(1)
            if (tries.size < 3) Endpoint("127.0.0.1", deadPort, "dead") else endpoint()
        })
        val p = accept()
        assertEquals("hello", p.read()!!.type)
        assertEquals(3, tries.size)
        // Failed attempts don't produce onConnected/onDisconnected, only onConnecting.
        assertEquals(listOf("connecting", "connecting", "connecting", "connected"), (0 until 4).map { rec.next() })
    }
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Where to dial the iPhone. [via] says how it was found: [VIA_CONFIG], [VIA_HOTSPOT],
 * [VIA_BONJOUR] (or anything else, for tests).
 */
data class Endpoint @JvmOverloads constructor(
    val host: String,
    val port: Int = Limits.DEFAULT_PORT,
    val via: String = ""
) {
    override fun toString(): String = "$host:$port" + if (via.isEmpty()) "" else " ($via)"

    companion object {
        const val VIA_CONFIG = "config"
        const val VIA_HOTSPOT = "hotspot"
        const val VIA_BONJOUR = "bonjour"
    }
}

/**
 * The TCP client loop that keeps Glass linked to the iPhone (PROTOCOL.md sections 1, 4, 6).
 *
 * On its own thread ("GlassBridge-link") it repeats: [Listener.onConnecting], [resolve] an
 * endpoint (null = not found), connect with a [CONNECT_TIMEOUT_MS] timeout, tcpNoDelay and
 * keepAlive, send the frame from [hello], [Listener.onConnected], then read frames until the
 * link drops, then [Listener.onDisconnected] and wait before the next attempt:
 *
 * - backoff starts at [BACKOFF_START_MS] and doubles to [BACKOFF_MAX_MS] after each attempt
 *   that fails (nothing found, connect failed, or the link ended without a `welcome`);
 * - after a session that got `welcome`, the next wait is [BACKOFF_START_MS] again;
 * - after `rejected`, the next wait is a fixed [REJECTED_RETRY_MS] (5 s), and the link is
 *   closed straight away after the frame is delivered.
 *
 * A watchdog thread per link checks every [WATCHDOG_TICK_MS]: after [PING_AFTER_MS] with
 * nothing received it sends one `ping`; after [DEAD_AFTER_MS] it closes the socket, which
 * also unblocks a reader stuck mid-payload or a writer stuck on a full socket. Every received
 * frame resets the silence timer. Silence is measured on [clockMs] (BridgeService makes that
 * a clock that keeps counting in deep sleep), and [checkSilence] runs the same check on
 * demand, because the watchdog thread's sleep stops while the CPU is suspended. Incoming
 * `ping` is answered with `pong` here and not passed on; every other frame (including
 * `pong`, `welcome` and `rejected`) goes to [Listener.onFrame].
 *
 * Threading: every listener callback runs on the link thread, in order: onConnecting,
 * onConnected, onFrame..., onDisconnected, then onRetryWait before each wait. Callbacks must not block (hop to the main
 * thread for UI state). [send] may be called from any thread; it blocks while another frame
 * is being written, so call it off the main thread, or use [sendAsync]. A listener that
 * throws is logged and ignored.
 *
 * Lifecycle: [start] once, [stop] once; to link again after stop, make a new instance.
 * The timing constants are global vars so tests can shorten them.
 */
class BridgeConnection(
    private val resolve: () -> Endpoint?,
    private val hello: () -> JSONObject,
    private val listener: Listener
) : FrameSender {

    interface Listener {
        /** A new attempt starts (before [resolve] runs). */
        fun onConnecting()

        /** TCP connected and `hello` sent. Acceptance comes later as a `welcome` frame. */
        fun onConnected(endpoint: Endpoint)

        /** A frame arrived (never `ping`, which is answered here). */
        fun onFrame(frame: Frame)

        /** The link that [onConnected] reported has gone. Not called for failed attempts. */
        fun onDisconnected(reason: String)

        /**
         * The loop is about to wait [ms] before the next attempt (after a failed attempt, a
         * rejection or a lost link). The service uses it to let the CPU sleep again.
         */
        fun onRetryWait(ms: Long) {}
    }

    companion object {
        @Volatile @JvmStatic var PING_AFTER_MS = 15_000L
        @Volatile @JvmStatic var DEAD_AFTER_MS = 30_000L
        @Volatile @JvmStatic var WATCHDOG_TICK_MS = 1_000L
        @Volatile @JvmStatic var CONNECT_TIMEOUT_MS = 5_000
        @Volatile @JvmStatic var BACKOFF_START_MS = 2_000L
        @Volatile @JvmStatic var BACKOFF_MAX_MS = 30_000L
        @Volatile @JvmStatic var REJECTED_RETRY_MS = 5_000L

        /** The default [clockMs]: monotonic, but it stops while the CPU is suspended. */
        private val MONOTONIC_MS: () -> Long = { System.nanoTime() / 1_000_000L }

        /**
         * The clock (milliseconds, any origin) that silence is measured on. BridgeService sets
         * `SystemClock.elapsedRealtime`, which keeps counting while Glass is in deep sleep, so a
         * link that died silently during sleep is closed at the first check after waking.
         * Set it before [start]: times read from two different clocks can't be compared.
         * Tests set a fake clock; [resetTimings] restores the default.
         */
        @Volatile @JvmStatic var clockMs: () -> Long = MONOTONIC_MS

        /** Restores the protocol's timings and the default clock (tests call this when they're done). */
        @JvmStatic
        fun resetTimings() {
            PING_AFTER_MS = 15_000L
            DEAD_AFTER_MS = 30_000L
            WATCHDOG_TICK_MS = 1_000L
            CONNECT_TIMEOUT_MS = 5_000
            BACKOFF_START_MS = 2_000L
            BACKOFF_MAX_MS = 30_000L
            REJECTED_RETRY_MS = 5_000L
            clockMs = MONOTONIC_MS
        }

        private fun now(): Long = clockMs()

        private fun closeQuietly(s: Socket) {
            try {
                s.close()
            } catch (e: IOException) {
            }
        }
    }

    private enum class Outcome { FAILED, WELCOMED, REJECTED, STOPPED }

    /** One TCP connection. [reason] doubles as the closed flag (non-null = closed). */
    private class Link(val socket: Socket, val endpoint: Endpoint) {
        val writer = FrameWriter(socket.getOutputStream())
        val reason = AtomicReference<String?>(null)
        @Volatile var lastRx = now()
        @Volatile var pingSent = false
        @Volatile var welcomed = false
        @Volatile var rejected = false
        val isClosed: Boolean get() = reason.get() != null
    }

    private val lock = Any()
    private var started = false
    @Volatile private var running = false
    @Volatile private var link: Link? = null
    private var connecting: Socket? = null // guarded by lock
    private val wakeRequested = AtomicBoolean(false)
    @Volatile private var wakeLatch: CountDownLatch? = null
    private val sender: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "GlassBridge-send").apply { isDaemon = true }
    }

    /** True while a TCP link is up and `hello` has been sent. */
    val isConnected: Boolean get() = link.let { it != null && !it.isClosed }

    /** True once the current link has received `welcome` (the iPhone accepted this Glass). */
    val isAccepted: Boolean get() = link.let { it != null && !it.isClosed && it.welcomed }

    /** The endpoint of the current link, or null. */
    val endpoint: Endpoint? get() = link?.takeIf { !it.isClosed }?.endpoint

    /** Starts the link thread. Calling it again does nothing. */
    fun start() {
        synchronized(lock) {
            if (started) return
            started = true
            running = true
        }
        Thread({ runLoop() }, "GlassBridge-link").apply { isDaemon = true }.start()
    }

    /**
     * Stops for good: closes the link (onDisconnected("stopped") follows on the link
     * thread), aborts a connect in progress and ends the loop. [resolve] can't be
     * interrupted, so the thread may linger until it returns. Safe from any thread.
     */
    fun stop() {
        val s: Socket?
        synchronized(lock) {
            running = false
            s = connecting
        }
        if (s != null) closeQuietly(s)
        link?.let { close(it, "stopped") }
        wakeLatch?.countDown()
        sender.shutdown()
    }

    /** Skips the current backoff wait (for example when Wi-Fi has just connected). */
    fun retryNow() {
        wakeRequested.set(true)
        wakeLatch?.countDown()
    }

    /** Closes the current link (if any); the loop reconnects with the normal backoff. */
    fun drop(reason: String) {
        link?.let { close(it, reason) }
    }

    /**
     * Runs the watchdog's check now, on the caller's thread: closes the link if nothing has been
     * received for [DEAD_AFTER_MS], or sends the one `ping` once [PING_AFTER_MS] has passed.
     * BridgeService calls it from the 60 s alarm tick: the watchdog thread's sleep doesn't run
     * while the CPU is suspended, so this makes the check happen inside the tick's wake lock,
     * before the tick decides whether to redial. Returns true if this call closed the link.
     * Never blocks (the ping is written on its own thread). Safe from any thread.
     */
    fun checkSilence(): Boolean {
        val l = link ?: return false
        return checkSilence(l)
    }

    /**
     * Sends one frame on the current link. Returns false when not connected, when the frame
     * breaks the limits (nothing is written), or when the write fails (the link is then
     * dropped). Blocks while another frame is being written.
     */
    override fun send(obj: JSONObject, payload: ByteArray?, length: Int): Boolean {
        val l = link ?: return false
        if (l.isClosed) return false
        return writeOn(l, obj, payload, length)
    }

    /**
     * Queues a frame for the "GlassBridge-send" thread and returns at once. [done] (optional)
     * gets the result of [send] on that thread. The payload must not change until then.
     */
    @JvmOverloads
    fun sendAsync(obj: JSONObject, payload: ByteArray? = null, done: ((Boolean) -> Unit)? = null) {
        try {
            sender.execute {
                val ok = send(obj, payload, payload?.size ?: 0)
                if (done != null) {
                    try {
                        done(ok)
                    } catch (t: Throwable) {
                        BridgeLog.e("sendAsync callback threw", t)
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            done?.invoke(false)
        }
    }

    // ----- loop ------------------------------------------------------------------------

    private fun runLoop() {
        var delay = BACKOFF_START_MS
        try {
            while (running) {
                val outcome = try {
                    attempt()
                } catch (t: Throwable) {
                    // Never let one bad attempt end reconnecting for good.
                    BridgeLog.e("Link attempt failed unexpectedly", t)
                    val l = synchronized(lock) { link.also { link = null } }
                    if (l != null) {
                        close(l, "internal error: $t")
                        safely("onDisconnected") { listener.onDisconnected("internal error: $t") }
                    }
                    Outcome.FAILED
                }
                if (!running || outcome == Outcome.STOPPED) break
                val wait: Long
                when (outcome) {
                    Outcome.REJECTED -> {
                        delay = BACKOFF_START_MS
                        wait = REJECTED_RETRY_MS
                    }
                    Outcome.WELCOMED -> {
                        wait = BACKOFF_START_MS
                        delay = Math.min(BACKOFF_START_MS * 2, BACKOFF_MAX_MS)
                    }
                    else -> {
                        wait = Math.min(delay, BACKOFF_MAX_MS)
                        delay = Math.min(delay * 2, BACKOFF_MAX_MS)
                    }
                }
                BridgeLog.i("Reconnecting in " + formatSeconds(wait))
                safely("onRetryWait") { listener.onRetryWait(wait) }
                pause(wait)
            }
        } catch (t: Throwable) {
            BridgeLog.e("Link loop crashed", t)
        }
        BridgeLog.i("Link loop stopped")
    }

    private fun attempt(): Outcome {
        safely("onConnecting") { listener.onConnecting() }
        val ep = try {
            resolve()
        } catch (t: Throwable) {
            BridgeLog.w("Finding the iPhone failed", t)
            null
        }
        if (!running) return Outcome.STOPPED
        if (ep == null) {
            BridgeLog.i("iPhone not found")
            return Outcome.FAILED
        }

        val socket = Socket()
        synchronized(lock) {
            if (!running) return Outcome.STOPPED
            connecting = socket
        }
        BridgeLog.i("Connecting to $ep")
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(ep.host, ep.port), CONNECT_TIMEOUT_MS)
        } catch (e: Exception) {
            closeQuietly(socket)
            BridgeLog.i("Connect to $ep failed: $e")
            return if (running) Outcome.FAILED else Outcome.STOPPED
        } finally {
            synchronized(lock) { connecting = null }
        }
        if (!running) {
            closeQuietly(socket)
            return Outcome.STOPPED
        }

        val l = try {
            Link(socket, ep)
        } catch (e: IOException) {
            closeQuietly(socket)
            BridgeLog.w("Socket setup failed: $e")
            return Outcome.FAILED
        }
        try {
            l.writer.write(hello())
        } catch (t: Throwable) {
            closeQuietly(socket)
            BridgeLog.w("Sending hello failed: $t")
            return Outcome.FAILED
        }
        l.lastRx = now()
        synchronized(lock) {
            if (!running) {
                closeQuietly(socket)
                return Outcome.STOPPED
            }
            link = l
        }
        BridgeLog.i("Connected to $ep; hello sent")
        startWatchdog(l)
        safely("onConnected") { listener.onConnected(ep) }

        var reason = "closed by the iPhone"
        try {
            val reader = FrameReader(socket.getInputStream())
            while (true) {
                val f = reader.read() ?: break
                l.lastRx = now()
                l.pingSent = false
                when (f.type) {
                    MsgType.PING -> {
                        writeOn(l, Msg.pong(), null, 0)
                        continue
                    }
                    MsgType.WELCOME -> l.welcomed = true
                    MsgType.REJECTED -> l.rejected = true
                }
                safely("onFrame") { listener.onFrame(f) }
                if (l.rejected) {
                    close(l, "rejected (" + (f.str("reason") ?: "no reason") + ")")
                    break
                }
            }
        } catch (e: ProtocolException) {
            reason = "protocol error: " + e.message
        } catch (e: IOException) {
            reason = "connection lost: $e"
        } catch (e: RuntimeException) {
            BridgeLog.e("Reader failed", e)
            reason = "internal error: $e"
        }
        close(l, reason)
        synchronized(lock) {
            if (link === l) link = null
        }
        val why = l.reason.get() ?: reason
        BridgeLog.i("Disconnected from $ep: $why")
        safely("onDisconnected") { listener.onDisconnected(why) }
        return when {
            l.rejected -> Outcome.REJECTED
            l.welcomed -> Outcome.WELCOMED
            !running -> Outcome.STOPPED
            else -> Outcome.FAILED
        }
    }

    private fun startWatchdog(l: Link) {
        val t = Thread({
            try {
                while (!l.isClosed) {
                    Thread.sleep(WATCHDOG_TICK_MS)
                    checkSilence(l)
                }
            } catch (e: InterruptedException) {
                // exit
            }
        }, "GlassBridge-watchdog")
        t.isDaemon = true
        t.start()
    }

    /**
     * One silence check of [l] (the watchdog thread every [WATCHDOG_TICK_MS], or [checkSilence]).
     * Synchronized on the link so the two callers can't both send the ping. Returns true if
     * this call closed the link.
     */
    private fun checkSilence(l: Link): Boolean {
        synchronized(l) {
            if (l.isClosed) return false
            val silence = now() - l.lastRx
            if (silence >= DEAD_AFTER_MS) {
                // The measured silence can be far past the limit when Glass has just woken up.
                BridgeLog.i("Nothing received for " + formatSeconds(silence) + "; closing the link")
                return close(l, "nothing received for " + formatSeconds(DEAD_AFTER_MS))
            }
            if (silence >= PING_AFTER_MS && !l.pingSent) {
                l.pingSent = true
                // On its own thread: if a writer is stuck on a full socket, the ping
                // waits for it, but the watchdog keeps counting towards DEAD_AFTER_MS.
                Thread({ writeOn(l, Msg.ping(), null, 0) }, "GlassBridge-ping")
                    .apply { isDaemon = true }
                    .start()
            }
            return false
        }
    }

    private fun writeOn(l: Link, obj: JSONObject, payload: ByteArray?, length: Int): Boolean {
        if (l.isClosed) return false
        return try {
            l.writer.write(obj, payload, length)
            true
        } catch (e: ProtocolException) {
            BridgeLog.w("Not sent: " + e.message)
            false
        } catch (e: IllegalArgumentException) {
            BridgeLog.w("Not sent: " + e.message)
            false
        } catch (e: IOException) {
            close(l, "write failed: $e")
            false
        }
    }

    /** Closes [l] with [why] as its reason; false if it was already closed. */
    private fun close(l: Link, why: String): Boolean {
        if (!l.reason.compareAndSet(null, why)) return false
        val s = l.socket
        try {
            s.shutdownInput()
        } catch (e: Exception) {
        }
        try {
            s.shutdownOutput()
        } catch (e: Exception) {
        }
        closeQuietly(s)
        return true
    }

    private fun pause(ms: Long) {
        if (ms <= 0) return
        val latch = CountDownLatch(1)
        wakeLatch = latch
        try {
            if (running && !wakeRequested.getAndSet(false)) {
                latch.await(ms, TimeUnit.MILLISECONDS)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            wakeLatch = null
            wakeRequested.set(false)
        }
    }

    private inline fun safely(what: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            BridgeLog.e("Listener $what threw", t)
        }
    }

    private fun formatSeconds(ms: Long): String =
        if (ms % 1000L == 0L) (ms / 1000L).toString() + " s" else String.format(java.util.Locale.US, "%.1f s", ms / 1000.0)
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.Random

/** Uploader against an in-memory sender that plays the iPhone's MediaReceiver rules. */
class UploaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /**
     * Records frames; on file_end, answers with a file_ack (from another thread) like the
     * iPhone would, unless [ackMode] says otherwise.
     */
    private class FakePhone(var ackMode: String = "ok") : FrameSender {
        val frames = ArrayList<Frame>()
        val received = ByteArrayOutputStream()
        var connected = true
        var uploader: Uploader? = null
        var onChunk: ((Int) -> Unit)? = null
        private var chunks = 0

        override fun send(obj: JSONObject, payload: ByteArray?, length: Int): Boolean {
            if (!connected) return false
            // Copy, as the real writer has finished with the buffer when send returns.
            val bytes = FrameWriter.encode(JSONObject(obj.toString()), payload, length)
            val f = TestUtil.readAll(bytes, bytes.size).single()
            synchronized(frames) { frames.add(f) }
            when (f.type) {
                "file_chunk" -> {
                    received.write(f.payload ?: ByteArray(0))
                    onChunk?.invoke(++chunks)
                }
                "file_end" -> {
                    val id = f.str("id")!!
                    val sha = TestUtil.sha256Hex(received.toByteArray())
                    val ack = when (ackMode) {
                        "ok" -> JSONObject().put("type", "file_ack").put("id", id).put("ok", true).put("sha256", sha)
                        "refuse" -> JSONObject().put("type", "file_ack").put("id", id).put("ok", false).put("error", "size mismatch")
                        else -> null
                    }
                    if (ack != null) {
                        Thread {
                            Thread.sleep(50)
                            uploader!!.handleFrame(Frame(ack, null))
                        }.start()
                    }
                }
            }
            return true
        }

        fun types(): List<String> = synchronized(frames) { frames.map { it.type } }
        fun of(type: String): List<Frame> = synchronized(frames) { frames.filter { it.type == type } }
    }

    private fun file(name: String, size: Int, seed: Long = 1): Pair<File, ByteArray> {
        val data = ByteArray(size).also { Random(seed).nextBytes(it) }
        val f = File(tmp.root, name)
        f.writeBytes(data)
        f.setLastModified(1793491200000L)
        return f to data
    }

    @Test
    fun uploads600KbAsBeginThreeChunksEndAndWaitsForTheAck() {
        val (f, data) = file("IMG_0001.jpg", 600 * 1024)
        val phone = FakePhone()
        val up = Uploader(phone)
        phone.uploader = up
        val r = up.upload(f)
        assertTrue(r.error, r.ok)
        assertEquals("IMG_0001.jpg:614400", r.id)
        assertEquals(614400L, r.bytesSent)
        assertEquals(TestUtil.sha256Hex(data), r.sha256)
        assertEquals(r.sha256, r.ack!!.getString("sha256"))
        assertEquals(listOf("file_begin", "file_chunk", "file_chunk", "file_chunk", "file_end"), phone.types())
        val begin = phone.of("file_begin").single()
        assertEquals("IMG_0001.jpg:614400", begin.str("id"))
        assertEquals("IMG_0001.jpg", begin.str("name"))
        assertEquals(614400L, begin.long("size"))
        assertEquals("image/jpeg", begin.str("mime"))
        assertEquals(1793491200000L, begin.long("taken"))
        val chunks = phone.of("file_chunk")
        assertEquals(listOf(0L, 262144L, 524288L), chunks.map { it.long("offset") })
        assertEquals(listOf(262144, 262144, 90112), chunks.map { it.payload!!.size })
        assertEquals(listOf(262144, 262144, 90112), chunks.map { it.int("bytes") })
    }

    @Test
    fun refusedAckIsAFailure() {
        val (f, _) = file("v.mp4", 1000)
        val phone = FakePhone("refuse")
        val up = Uploader(phone)
        phone.uploader = up
        val r = up.upload(f)
        assertFalse(r.ok)
        assertEquals("size mismatch", r.error)
    }

    @Test
    fun noAckTimesOut() {
        val (f, _) = file("a.png", 10)
        val phone = FakePhone("none")
        val up = Uploader(phone, ackTimeoutMs = 300)
        phone.uploader = up
        val t0 = System.currentTimeMillis()
        val r = up.upload(f)
        assertFalse(r.ok)
        assertTrue(r.error!!, r.error!!.startsWith("no file_ack"))
        assertTrue(r.timedOut)
        assertNull(r.ack)
        assertTrue(System.currentTimeMillis() - t0 >= 290)
    }

    @Test
    fun ackBeforeFileEndIsALateAnswerToAnEarlierAttemptAndIgnored() {
        val (f, data) = file("IMG_0002.jpg", 600 * 1024)
        val phone = FakePhone()
        val up = Uploader(phone)
        phone.uploader = up
        val id = Uploader.idFor(f)
        val early = JSONObject().put("type", "file_ack").put("id", id).put("ok", false).put("error", "from an earlier attempt")
        var earlyMatched: Boolean? = null
        // While the chunks are still going out, a file_ack for the same id arrives.
        phone.onChunk = { n -> if (n == 1) earlyMatched = up.handleAck(early) }
        val r = up.upload(f)
        assertEquals(false, earlyMatched)
        assertTrue(r.error, r.ok) // the answer to this attempt's file_end counts
        assertEquals(TestUtil.sha256Hex(data), r.sha256)
        assertFalse(r.timedOut)
    }

    @Test
    fun cancelAllEndsTheWaitAtOnce() {
        val (f, _) = file("a.3gp", 10)
        val phone = FakePhone("none")
        val up = Uploader(phone, ackTimeoutMs = 30_000)
        phone.uploader = up
        Thread {
            Thread.sleep(200)
            up.cancelAll()
        }.start()
        val t0 = System.currentTimeMillis()
        val r = up.upload(f)
        assertFalse(r.ok)
        assertTrue(r.error!!, r.error!!.startsWith("cancelled"))
        assertFalse(r.timedOut)
        assertTrue(System.currentTimeMillis() - t0 < 10_000)
        // The next upload works normally.
        phone.ackMode = "ok"
        assertTrue(up.upload(file("b.jpg", 10).first).ok)
    }

    @Test
    fun fileThatGrowsMidUploadFailsWithoutFileEnd() {
        val (f, _) = file("growing.mp4", 300_000)
        val phone = FakePhone()
        val up = Uploader(phone)
        phone.uploader = up
        phone.onChunk = { n ->
            if (n == 1) FileOutputStream(f, true).use { it.write(ByteArray(5000)) }
        }
        val r = up.upload(f)
        assertFalse(r.ok)
        assertTrue(r.error!!, r.error!!.contains("changed"))
        assertFalse(phone.types().contains("file_end"))
    }

    @Test
    fun fileThatShrinksMidUploadFails() {
        val (f, _) = file("shrinking.mp4", 600_000)
        val phone = FakePhone()
        val up = Uploader(phone)
        phone.uploader = up
        phone.onChunk = { n ->
            if (n == 1) FileOutputStream(f, false).use { it.write(ByteArray(1000)) }
        }
        val r = up.upload(f)
        assertFalse(r.ok)
        assertTrue(r.error!!, r.error!!.contains("changed"))
        assertFalse(phone.types().contains("file_end"))
    }

    @Test
    fun notConnectedUnknownTypeAndMissingFile() {
        val phone = FakePhone()
        phone.connected = false
        val up = Uploader(phone)
        assertEquals("not connected", up.upload(file("a.jpg", 10).first).error)
        assertEquals("unsupported file type", Uploader(FakePhone()).upload(file("a.txt", 10).first).error)
        assertEquals("file not found", Uploader(FakePhone()).upload(File(tmp.root, "nope.jpg")).error)
    }

    @Test
    fun ackForAnotherIdIsIgnored() {
        val up = Uploader(FakePhone())
        assertFalse(up.handleAck(JSONObject().put("type", "file_ack").put("id", "x:1").put("ok", true)))
        assertFalse(up.handleFrame(Frame(JSONObject().put("type", "card"), null)))
    }

    @Test
    fun emptyFileStillGetsBeginAndEnd() {
        val (f, _) = file("empty.jpg", 0)
        val phone = FakePhone()
        val up = Uploader(phone)
        phone.uploader = up
        val r = up.upload(f)
        assertTrue(r.error, r.ok)
        assertEquals(listOf("file_begin", "file_end"), phone.types())
        assertNull(phone.of("file_begin").single().payload)
    }
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.util.Collections
import java.util.Random

/**
 * Framing (PROTOCOL.md section 3) and formatDistance. Pure JVM, no network.
 */
class FramingTest {

    private class Expected(val obj: JSONObject, val payload: ByteArray?)

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    /** A mix of frames covering the awkward cases, encoded with FrameWriter. */
    private fun mixedFrames(): List<Expected> {
        val rnd = Random(42)
        val big = ByteArray(300_000).also { rnd.nextBytes(it) }
        val all256 = ByteArray(256) { it.toByte() }
        val jsonPayload = bytes("{\"type\":\"card\",\"id\":\"fake\",\"bytes\":3}\nabc\n{\"type\":\"ping\"}\r\n\n")
        return listOf(
            Expected(JSONObject().put("type", "card").put("id", "c1").put("title", "Hi").put("text", "Hello"), null),
            Expected(Msg.fileChunk("a.jpg:5", 0), bytes("ABCDE")),
            Expected(Msg.ping(), null),
            Expected(Msg.fileChunk("j:1", 5), jsonPayload),
            Expected(JSONObject().put("type", "card").put("id", "u").put("title", "Café 東京")
                .put("text", "line1\nline2\t\"quoted\" \\ back / slash 🚀   end"), null),
            Expected(Msg.frame(640, 360), all256),
            Expected(Msg.fileChunk("nl", 0), bytes("\n\n\r\n")),
            Expected(Msg.fileChunk("cr", 0), bytes("ends in CR\r")),
            Expected(JSONObject().put("type", "x_future_thing").put("x_num", 1.5).put("time", 1793491200123L), byteArrayOf(1, 2, 3, 4, 5, 6, 7)),
            Expected(Msg.fileChunk("big", 0), big),
            Expected(Msg.status(87, false, 9216, 12288, null, null, true, true, 42), null),
            Expected(Msg.pong(), null)
        )
    }

    private fun encodeAll(frames: List<Expected>): ByteArray {
        val bos = ByteArrayOutputStream()
        val w = FrameWriter(bos)
        for (f in frames) w.write(JSONObject(f.obj.toString()), f.payload)
        return bos.toByteArray()
    }

    private fun assertFrame(e: Expected, got: Frame, where: String) {
        val wantObj = JSONObject(e.obj.toString())
        if (e.payload != null) wantObj.put("bytes", e.payload.size)
        assertTrue("$where: object ${got.obj} != $wantObj", TestUtil.jsonEquals(wantObj, got.obj))
        if (e.payload == null) {
            assertNull("$where: unexpected payload", got.payload)
        } else {
            assertArrayEquals("$where: payload", e.payload, got.payload)
        }
    }

    @Test
    fun mixedFramesRoundTripThroughEveryReadSize() {
        val frames = mixedFrames()
        val data = encodeAll(frames)
        for (size in intArrayOf(1, 2, 3, 5, 7, 13, 64, 255, 1000, 4096, 65535, 65536, 65537, 262144, data.size)) {
            val got = TestUtil.readAll(data, size)
            assertEquals("frame count at read size $size", frames.size, got.size)
            for (i in frames.indices) assertFrame(frames[i], got[i], "read size $size, frame $i")
        }
    }

    @Test
    fun payloadContainingNewlinesAndJsonIsNotParsedAsFrames() {
        val payload = bytes("{\"type\":\"card\",\"id\":\"inner\"}\n{\"type\":\"ping\"}\n")
        val data = FrameWriter.encode(Msg.fileChunk("f", 0), payload) + FrameWriter.encode(Msg.ping())
        val got = TestUtil.readAll(data, 1)
        assertEquals(2, got.size)
        assertEquals("file_chunk", got[0].type)
        assertArrayEquals(payload, got[0].payload)
        assertEquals("ping", got[1].type)
    }

    @Test
    fun crlfAndBlankLines() {
        val data = bytes("\n\r\n\r\n{\"type\":\"a\"}\r\n\r\n\n{\"type\":\"b\",\"bytes\":5}\r\nx\r\ny\n\n\r\n{\"type\":\"c\", \"k\" : 1}\r\n")
        for (size in intArrayOf(1, 2, 3, 100)) {
            val got = TestUtil.readAll(data, size)
            assertEquals(listOf("a", "b", "c"), got.map { it.type })
            assertNull(got[0].payload)
            assertArrayEquals(bytes("x\r\ny\n"), got[1].payload)
            assertEquals(1, got[2].int("k"))
        }
    }

    @Test
    fun bytesFieldRules() {
        // absent, 0, a string, a fraction, an integral float, a boolean: no payload.
        val data = bytes(
            "{\"type\":\"a\"}\n{\"type\":\"b\",\"bytes\":0}\n{\"type\":\"c\",\"bytes\":\"5\"}\n" +
                "{\"type\":\"d\",\"bytes\":1.5}\n{\"type\":\"e\",\"bytes\":3.0}\n{\"type\":\"f\",\"bytes\":true}\n" +
                "{\"bytes\":2,\"type\":\"g\"}\nok{\"type\":\"h\"}\n"
        )
        val got = TestUtil.readAll(data, 1)
        assertEquals(listOf("a", "b", "c", "d", "e", "f", "g", "h"), got.map { it.type })
        for (i in 0..5) assertNull("frame $i", got[i].payload)
        assertArrayEquals(bytes("ok"), got[6].payload)
        expectProtocolError(bytes("{\"type\":\"neg\",\"bytes\":-1}\n"))
        expectProtocolError(bytes("{\"type\":\"neg\",\"bytes\":-0.5}\n"))
    }

    @Test
    fun oversizedPayloadIsRejected() {
        expectProtocolError(bytes("{\"type\":\"file_chunk\",\"bytes\":1048577}\n"))
        // Exactly 1 MiB is allowed.
        val ok = ByteArray(Limits.MAX_PAYLOAD)
        val data = FrameWriter.encode(Msg.fileChunk("max", 0), ok)
        assertEquals(Limits.MAX_PAYLOAD, TestUtil.readAll(data, 65536)[0].payload!!.size)
        // The writer refuses to build an oversized frame and writes nothing.
        val bos = ByteArrayOutputStream()
        try {
            FrameWriter(bos).write(Msg.fileChunk("too big", 0), ByteArray(Limits.MAX_PAYLOAD + 1))
            fail("writer accepted an oversized payload")
        } catch (e: ProtocolException) {
            assertEquals(0, bos.size())
        }
    }

    @Test
    fun oversizedLineIsRejected() {
        // A line of exactly 65,536 bytes (plus an optional \r) is allowed.
        val head = "{\"type\":\"t\",\"text\":\""
        val tail = "\"}"
        val fill = "a".repeat(Limits.MAX_LINE - head.length - tail.length)
        val exact = head + fill + tail
        assertEquals(Limits.MAX_LINE, exact.length)
        assertEquals("t", TestUtil.readAll(bytes(exact + "\n"), 4096)[0].type)
        assertEquals("t", TestUtil.readAll(bytes(exact + "\r\n"), 4096)[0].type)
        expectProtocolError(bytes(head + fill + "a" + tail + "\n"))
        // A line that never ends is cut off at the limit rather than read forever.
        expectProtocolError(ByteArray(200_000) { 'x'.code.toByte() })
        // The writer won't produce one either.
        try {
            FrameWriter.encode(JSONObject().put("type", "t").put("text", "b".repeat(Limits.MAX_LINE)))
            fail("writer accepted an oversized line")
        } catch (e: ProtocolException) {
            // expected
        }
    }

    @Test
    fun badLinesAreProtocolErrors() {
        expectProtocolError(bytes("[1,2,3]\n"))
        expectProtocolError(bytes("{\"x\":1}\n"))
        expectProtocolError(bytes("{\"type\":5}\n"))
        expectProtocolError(bytes("{\"type\":null}\n"))
        expectProtocolError(bytes("hello there\n"))
        expectProtocolError(bytes("{\"type\":\"a\"\n"))
        expectProtocolError(byteArrayOf('{'.code.toByte(), '"'.code.toByte(), 0xC3.toByte(), 0x28, '"'.code.toByte(), '}'.code.toByte(), '\n'.code.toByte()))
        // Deep nesting inside the line limit: a parse error or a caught stack overflow, never a crash.
        expectProtocolError(bytes("{\"a\":".repeat(13000) + "\n"))
    }

    @Test
    fun endOfStream() {
        assertNull(FrameReader(ChunkedInputStream(ByteArray(0), 1)).read())
        assertNull(FrameReader(ChunkedInputStream(bytes("\n\r\n"), 1)).read())
        expectEof(bytes("{\"type\":\"a\""))
        expectEof(bytes("{\"type\":\"a\",\"bytes\":10}\n12345"))
        val r = FrameReader(ChunkedInputStream(bytes("{\"type\":\"a\"}\n"), 3))
        assertEquals("a", r.read()!!.type)
        assertNull(r.read())
    }

    @Test
    fun writerKeepsHeaderAndPayloadTogetherAcrossThreads() {
        val bos = ByteArrayOutputStream()
        val writer = FrameWriter(bos)
        val threads = (0 until 8).map { t ->
            Thread {
                val rnd = Random(t.toLong())
                for (i in 0 until 50) {
                    val p = ByteArray(1 + rnd.nextInt(20_000)) { (t * 31 + i).toByte() }
                    writer.write(Msg.fileChunk("t$t", i.toLong()), p)
                    writer.write(Msg.ping())
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        val got = TestUtil.readAll(bos.toByteArray(), 4096)
        assertEquals(8 * 50 * 2, got.size)
        val seen = Collections.synchronizedSet(HashSet<String>())
        for (f in got) {
            if (f.type == "ping") continue
            val t = f.str("id")!!.substring(1).toInt()
            val i = f.long("offset")!!.toInt()
            val expectedByte = (t * 31 + i).toByte()
            assertTrue("payload of t$t/$i intact", f.payload!!.all { it == expectedByte })
            assertEquals(f.payload!!.size, f.int("bytes"))
            seen.add("$t/$i")
        }
        assertEquals(400, seen.size)
    }

    @Test
    fun writerSetsBytesAndRefusesBytesWithoutPayload() {
        val obj = Msg.frame(640, 360)
        val data = FrameWriter.encode(obj, byteArrayOf(9, 9, 9, 9), 3)
        val f = TestUtil.readAll(data, 1).single()
        assertEquals(3, f.int("bytes"))
        assertArrayEquals(byteArrayOf(9, 9, 9), f.payload)
        try {
            FrameWriter.encode(JSONObject().put("type", "x").put("bytes", 4))
            fail("accepted bytes without a payload")
        } catch (e: IllegalArgumentException) {
            // expected
        }
        try {
            FrameWriter.encode(JSONObject().put("kind", "x"))
            fail("accepted a frame without type")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun readerFieldAccessors() {
        val f = TestUtil.readAll(
            bytes("{\"type\":\"card\",\"id\":\"c\",\"time\":1793491200123,\"n\":2.6,\"b\":true,\"s\":\"x\",\"nul\":null}\n"), 1
        ).single()
        assertEquals(1793491200123L, f.long("time"))
        assertEquals(3, f.int("n"))
        assertEquals(2.6, f.double("n")!!, 1e-9)
        assertEquals(true, f.bool("b"))
        assertEquals("x", f.str("s"))
        assertNull(f.str("nul"))
        assertNull(f.str("time"))
        assertEquals("dflt", f.str("missing", "dflt"))
    }

    @Test
    fun formatDistanceBands() {
        val cases = linkedMapOf(
            0.0 to "0 m", 2.0 to "0 m", 3.0 to "5 m", 27.0 to "25 m", 28.0 to "30 m", 47.4 to "45 m",
            49.0 to "50 m", 50.0 to "50 m", 54.0 to "50 m", 55.0 to "60 m", 123.0 to "120 m",
            994.0 to "990 m", 996.0 to "1.0 km", 1000.0 to "1.0 km", 1049.0 to "1.0 km",
            1050.0 to "1.1 km", 2345.0 to "2.3 km", 9949.0 to "9.9 km", 9960.0 to "10 km",
            10000.0 to "10 km", 12345.0 to "12 km", 12500.0 to "13 km", 150000.0 to "150 km",
            -5.0 to "0 m", Double.NaN to "0 m"
        )
        for ((m, want) in cases) assertEquals("formatDistance($m)", want, formatDistance(m))
    }

    private fun expectProtocolError(data: ByteArray) {
        for (size in intArrayOf(1, 4096)) {
            try {
                TestUtil.readAll(data, size)
                fail("expected a ProtocolException for ${String(data.copyOf(minOf(60, data.size)), Charsets.UTF_8)}")
            } catch (e: ProtocolException) {
                // expected
            }
        }
    }

    private fun expectEof(data: ByteArray) {
        try {
            TestUtil.readAll(data, 1)
            fail("expected EOFException")
        } catch (e: EOFException) {
            // expected
        }
    }
}

package au.interstellr.glassbridge.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit

/**
 * Cross-language check: Kotlin FrameReader/FrameWriter against the tricky stream written by
 * `tools/make_test_stream.py` (the same stream the Swift core is checked with).
 *
 * 1. Python writes stream.bin and expected.json.
 * 2. Kotlin decodes stream.bin with every read size listed in expected.json and compares
 *    each frame (object and payload) with the expected one.
 * 3. Kotlin re-encodes the frames with FrameWriter and Python verifies the result.
 *
 * Skipped when python3 or the tools directory isn't available.
 */
class StreamCompatTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun repoRoot(): File? {
        val prop = System.getProperty("glassbridge.repoRoot")
        val candidates = listOfNotNull(prop?.let { File(it) }, File("../.."), File(".."), File("."))
        return candidates.firstOrNull { File(it, "tools/make_test_stream.py").isFile }
    }

    private fun run(dir: File, vararg cmd: String): Pair<Int, String> {
        val p = ProcessBuilder(*cmd).directory(dir).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        if (!p.waitFor(120, TimeUnit.SECONDS)) {
            p.destroy()
            return -1 to out
        }
        return p.exitValue() to out
    }

    private fun pythonAvailable(): Boolean = try {
        run(File("."), "python3", "--version").first == 0
    } catch (e: Exception) {
        false
    }

    @Test
    fun kotlinDecodesAndReencodesThePythonTestStream() {
        val root = repoRoot()
        assumeTrue("tools/make_test_stream.py not found", root != null)
        assumeTrue("python3 not available", pythonAvailable())
        val stream = File(tmp.root, "stream.bin")
        val expectedFile = File(tmp.root, "expected.json")
        val (code, out) = run(root!!, "python3", "tools/make_test_stream.py", "write", stream.path, expectedFile.path)
        assertEquals("make_test_stream.py write failed:\n$out", 0, code)

        val expected = JSONObject(expectedFile.readText())
        val data = stream.readBytes()
        assertEquals(expected.getLong("stream_bytes"), data.size.toLong())
        val want = expected.getJSONArray("frames")
        val sizes = expected.getJSONArray("read_sizes")
        assertEquals(expected.getInt("frame_count"), want.length())

        var decoded: List<Frame> = emptyList()
        for (s in 0 until sizes.length()) {
            val size = sizes.getInt(s)
            decoded = TestUtil.readAll(data, size)
            assertEquals("frame count at read size $size", want.length(), decoded.size)
            for (i in 0 until want.length()) {
                val w = want.getJSONObject(i)
                val got = decoded[i]
                val note = "frame $i (${w.optString("note")}) at read size $size"
                assertTrue("$note: object\n got  ${got.obj}\n want ${w.getJSONObject("obj")}",
                    TestUtil.jsonEquals(w.getJSONObject("obj"), got.obj))
                if (w.isNull("payload_b64")) {
                    assertNull("$note: unexpected payload", got.payload)
                } else {
                    val p = java.util.Base64.getDecoder().decode(w.getString("payload_b64"))
                    assertArrayEquals("$note: payload", p, got.payload)
                    assertEquals("$note: payload sha256", w.getString("payload_sha256"), TestUtil.sha256Hex(got.payload!!))
                }
            }
        }

        // Re-encode with the Kotlin writer and let Python verify it.
        val reencoded = File(tmp.root, "kotlin.bin")
        FileOutputStream(reencoded).use { fos ->
            val w = FrameWriter(fos)
            for (f in decoded) w.write(JSONObject(f.obj.toString()), f.payload)
        }
        val (vcode, vout) = run(root, "python3", "tools/make_test_stream.py", "verify", reencoded.path, expectedFile.path)
        assertEquals("make_test_stream.py verify rejected the Kotlin encoding:\n$vout", 0, vcode)
        assertTrue(vout, vout.contains("OK:"))
        println("StreamCompatTest: ${want.length()} frames decoded at ${sizes.length()} read sizes; verify said: ${vout.trim()}")
    }
}

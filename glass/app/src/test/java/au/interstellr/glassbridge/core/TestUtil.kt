package au.interstellr.glassbridge.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.math.BigDecimal
import java.security.MessageDigest

/** An InputStream over [data] that returns at most [maxRead] bytes per read call. */
class ChunkedInputStream(private val data: ByteArray, private val maxRead: Int) : InputStream() {
    private var pos = 0

    override fun read(): Int = if (pos < data.size) data[pos++].toInt() and 0xFF else -1

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= data.size) return -1
        val n = minOf(len, maxRead, data.size - pos)
        System.arraycopy(data, pos, b, off, n)
        pos += n
        return n
    }

    override fun available(): Int = 0
}

object TestUtil {
    fun sha256Hex(data: ByteArray, len: Int = data.size): String {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(data, 0, len)
        return Uploader.toHex(md.digest())
    }

    fun readAll(data: ByteArray, maxRead: Int): List<Frame> {
        val reader = FrameReader(ChunkedInputStream(data, maxRead))
        val out = ArrayList<Frame>()
        while (true) {
            val f = reader.read() ?: break
            out.add(f)
        }
        return out
    }

    /** JSON value equality: numbers by value (3 == 3.0), strings/booleans exact, recursive. */
    fun jsonEquals(a: Any?, b: Any?): Boolean {
        val x = if (a == null) JSONObject.NULL else a
        val y = if (b == null) JSONObject.NULL else b
        if (x is Boolean || y is Boolean) return x == y
        if (x is Number && y is Number) {
            return BigDecimal(x.toString()).compareTo(BigDecimal(y.toString())) == 0
        }
        if (x is String && y is String) return x == y
        if (x is JSONObject && y is JSONObject) {
            if (x.length() != y.length()) return false
            val it = x.keys()
            while (it.hasNext()) {
                val k = it.next()
                if (!y.has(k) || !jsonEquals(x.opt(k), y.opt(k))) return false
            }
            return true
        }
        if (x is JSONArray && y is JSONArray) {
            if (x.length() != y.length()) return false
            for (i in 0 until x.length()) if (!jsonEquals(x.opt(i), y.opt(i))) return false
            return true
        }
        return x == y
    }
}

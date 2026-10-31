package au.interstellr.glassbridge.core

import org.json.JSONException
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** Wire limits and constants from PROTOCOL.md sections 1 and 3. */
object Limits {
    /** Bytes in one JSON line, excluding the "\n" (and one trailing "\r"). */
    const val MAX_LINE = 65536

    /** Bytes in one binary payload. */
    const val MAX_PAYLOAD = 1048576

    /** Largest file chunk Glass sends (256 KiB), so pings and cards never wait long. */
    const val CHUNK = 262144

    const val PROTOCOL_VERSION = 2

    /** The iPhone listens on this TCP port. */
    const val DEFAULT_PORT = 9090
}

/**
 * The peer broke the framing rules (PROTOCOL.md section 3): drop the connection.
 *
 * It is an IOException so a connection loop can treat it like any other link failure.
 * [FrameWriter] also throws it, before writing anything, for a frame that would break
 * the limits.
 */
class ProtocolException(message: String) : IOException(message)

/**
 * Something that can send one frame. [BridgeConnection] implements it; tests can stub it.
 */
interface FrameSender {
    /**
     * Sends [obj] with the first [length] bytes of [payload] (if any) as one frame.
     * Returns false when the frame was not sent. When this returns, the payload array is
     * no longer used and may be reused by the caller.
     */
    fun send(obj: JSONObject, payload: ByteArray? = null, length: Int = payload?.size ?: 0): Boolean
}

/**
 * One decoded frame: the JSON object exactly as received (including "bytes" when present)
 * and the payload, or null when the frame has none.
 */
class Frame(val obj: JSONObject, val payload: ByteArray?) {

    /** The frame's "type" (always a string for frames from [FrameReader]). */
    val type: String get() = Json.str(obj, "type") ?: ""

    fun has(key: String): Boolean = Json.has(obj, key)
    fun str(key: String): String? = Json.str(obj, key)
    fun str(key: String, default: String): String = Json.str(obj, key) ?: default
    fun int(key: String): Int? = Json.int(obj, key)
    fun int(key: String, default: Int): Int = Json.int(obj, key) ?: default
    fun long(key: String): Long? = Json.long(obj, key)
    fun long(key: String, default: Long): Long = Json.long(obj, key) ?: default
    fun double(key: String): Double? = Json.double(obj, key)
    fun bool(key: String): Boolean? = Json.bool(obj, key)
    fun bool(key: String, default: Boolean): Boolean = Json.bool(obj, key) ?: default

    override fun toString(): String = describe(obj, payload)

    companion object {
        /**
         * How many payload bytes follow a header (0 = none). "bytes" that is absent, not a
         * number, or not an integer (3.0, 1e2, a string, a boolean) means no payload.
         * Throws [ProtocolException] for a negative number. Does not apply the size limit.
         */
        @JvmStatic
        @Throws(ProtocolException::class)
        fun payloadLength(obj: JSONObject): Long {
            val v = Json.raw(obj, "bytes") as? Number ?: return 0L
            if (v.toDouble() < 0) throw ProtocolException("negative bytes: $v")
            if (!Json.isInteger(v)) return 0L
            if (v is BigInteger) return if (v.bitLength() > 62) Long.MAX_VALUE else v.toLong()
            return v.toLong()
        }

        /** Short one-line text for logs. */
        @JvmStatic
        fun describe(obj: JSONObject, payload: ByteArray? = null, limit: Int = 300): String {
            var text = obj.toString()
            if (text.length > limit) text = text.substring(0, limit) + "...(" + text.length + " chars)"
            if (payload != null) text += " +" + payload.size + " bytes"
            return text
        }
    }
}

/**
 * Blocking frame reader (PROTOCOL.md section 3). Reads each line byte by byte, then exactly
 * the payload length, so it handles any split of the stream.
 *
 * - strips one trailing "\r"; skips blank lines;
 * - a line over [maxLine] bytes or a payload over [maxPayload] bytes, a line that is not
 *   UTF-8 JSON, not an object, or has no string "type", or a negative "bytes" throws
 *   [ProtocolException] (drop the connection);
 * - the stream ending inside a frame throws [EOFException].
 *
 * Not thread-safe: use it from one reader thread.
 */
class FrameReader @JvmOverloads constructor(
    input: InputStream,
    private val maxLine: Int = Limits.MAX_LINE,
    private val maxPayload: Int = Limits.MAX_PAYLOAD
) {
    private val input: InputStream =
        if (input is BufferedInputStream) input else BufferedInputStream(input, 65536)
    private var line = ByteArray(1024)
    private var lineLen = 0

    /** The next frame, or null at a clean end of stream (between frames). */
    @Throws(IOException::class)
    fun read(): Frame? {
        while (true) {
            lineLen = 0
            while (true) {
                val b = input.read()
                if (b < 0) {
                    if (lineLen == 0) return null
                    throw EOFException("stream ended inside a line ($lineLen bytes)")
                }
                if (b == NL) break
                if (lineLen >= maxLine + 1) { // +1 leaves room for one "\r"
                    throw ProtocolException("line exceeds the $maxLine byte limit")
                }
                append(b)
            }
            var len = lineLen
            if (len > 0 && line[len - 1] == CR) len--
            if (len > maxLine) throw ProtocolException("line of $len bytes exceeds the $maxLine byte limit")
            if (len == 0) continue // blank line
            val obj = parseLine(line, len)
            val n = Frame.payloadLength(obj)
            if (n > maxPayload) {
                throw ProtocolException("payload of $n bytes exceeds the $maxPayload byte limit")
            }
            if (n == 0L) return Frame(obj, null)
            val payload = ByteArray(n.toInt())
            readFully(payload)
            return Frame(obj, payload)
        }
    }

    private fun append(b: Int) {
        if (lineLen == line.size) {
            line = line.copyOf(Math.min(line.size * 2, maxLine + 1))
        }
        line[lineLen++] = b.toByte()
    }

    private fun readFully(buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) throw EOFException("stream ended inside a payload ($off of ${buf.size} bytes)")
            off += n
        }
    }

    companion object {
        private const val NL = '\n'.code
        private const val CR = '\r'.code.toByte()

        /** Parses one header line (without its line ending). */
        @JvmStatic
        @Throws(ProtocolException::class)
        fun parseLine(bytes: ByteArray, len: Int): JSONObject {
            val text = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes, 0, len))
                    .toString()
            } catch (e: CharacterCodingException) {
                throw ProtocolException("line is not valid UTF-8")
            }
            val obj = try {
                JSONObject(text)
            } catch (e: JSONException) {
                throw ProtocolException("line is not a JSON object: " + e.message)
            } catch (e: StackOverflowError) {
                throw ProtocolException("line is nested too deeply")
            } catch (e: RuntimeException) {
                throw ProtocolException("line is not valid JSON: $e")
            }
            if (Json.raw(obj, "type") !is String) throw ProtocolException("frame has no string 'type'")
            return obj
        }
    }
}

/**
 * Frame writer. [write] is synchronized, so a header and its payload always go out
 * together with no other frame between them, whichever threads are sending.
 *
 * A write blocks until the bytes are handed to the socket. If the peer stops reading, it
 * can block until the socket is closed ([BridgeConnection]'s watchdog does that).
 */
class FrameWriter(out: OutputStream) {
    private val out = BufferedOutputStream(out, 65536)

    /**
     * Writes one frame: [obj] as a JSON line, then the first [length] bytes of [payload].
     * With a payload, "bytes" is set on [obj] (it is modified). Throws [ProtocolException]
     * before writing anything if the line or payload is over the limit, and
     * IllegalArgumentException if [obj] has no string "type" or has a positive "bytes"
     * without a payload. Other IOExceptions come from the stream.
     */
    @Synchronized
    @Throws(IOException::class)
    fun write(obj: JSONObject, payload: ByteArray? = null, length: Int = payload?.size ?: 0) {
        val header = encodeHeader(obj, payload, length)
        out.write(header)
        out.write(NL)
        if (payload != null && length > 0) out.write(payload, 0, length)
        out.flush()
    }

    companion object {
        /** File chunk size (256 KiB). */
        const val CHUNK = Limits.CHUNK
        private const val NL = '\n'.code

        /** The JSON line for a frame, without the "\n". Sets "bytes" when there's a payload. */
        @JvmStatic
        @Throws(ProtocolException::class)
        fun encodeHeader(obj: JSONObject, payload: ByteArray?, length: Int = payload?.size ?: 0): ByteArray {
            require(Json.raw(obj, "type") is String) { "a frame needs a string 'type'" }
            if (payload != null) {
                require(length >= 0 && length <= payload.size) { "length $length outside the payload" }
                if (length > Limits.MAX_PAYLOAD) {
                    throw ProtocolException("payload of $length bytes exceeds the ${Limits.MAX_PAYLOAD} byte limit")
                }
                obj.put("bytes", length)
            } else {
                require(Frame.payloadLength(obj) == 0L) { "'bytes' is set but there is no payload" }
            }
            val bytes = obj.toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > Limits.MAX_LINE) {
                throw ProtocolException("line of ${bytes.size} bytes exceeds the ${Limits.MAX_LINE} byte limit")
            }
            return bytes
        }

        /** One whole frame as bytes (JSON line, "\n", payload). Mainly for tests. */
        @JvmStatic
        @Throws(ProtocolException::class)
        fun encode(obj: JSONObject, payload: ByteArray? = null, length: Int = payload?.size ?: 0): ByteArray {
            val header = encodeHeader(obj, payload, length)
            val n = if (payload != null) length else 0
            val out = ByteArray(header.size + 1 + n)
            System.arraycopy(header, 0, out, 0, header.size)
            out[header.size] = '\n'.code.toByte()
            if (n > 0) System.arraycopy(payload!!, 0, out, header.size + 1, n)
            return out
        }
    }
}

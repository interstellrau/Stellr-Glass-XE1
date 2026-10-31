package au.interstellr.glassbridge.core

import org.json.JSONObject
import java.io.File

/**
 * Glass `config.json` (PROTOCOL.md section 8), in the app's external files dir
 * (`/sdcard/Android/data/au.interstellr.glassbridge/files/config.json`). Every key is
 * optional; the file is read on every reconnect and every time the card screen opens, and
 * never deleted.
 *
 * - `host` (string): dial this host instead of discovering the iPhone. Without it (or with
 *   an empty one) discovery runs as normal.
 * - `port` (integer, default 9090): used with `host`.
 * - `invert_swipe` (boolean, default false): flip the touchpad swipe direction.
 *
 * Parsing never throws: a missing, unreadable or invalid file gives [DEFAULT] (and a log
 * line), and a bad value for one key falls back to that key's default.
 */
class GlassConfig(val host: String?, val port: Int, val invertSwipe: Boolean) {

    /** The override endpoint, or null when there's no `host`. */
    fun endpoint(): Endpoint? = host?.let { Endpoint(it, port, Endpoint.VIA_CONFIG) }

    override fun toString(): String = "GlassConfig(host=$host, port=$port, invertSwipe=$invertSwipe)"

    companion object {
        const val FILE_NAME = "config.json"

        /** Larger files are ignored. */
        const val MAX_BYTES = 64 * 1024

        @JvmField
        val DEFAULT = GlassConfig(null, Limits.DEFAULT_PORT, false)

        @JvmStatic
        fun parse(text: String?): GlassConfig {
            if (text == null || text.trim().isEmpty()) return DEFAULT
            val obj = try {
                JSONObject(text.trim())
            } catch (e: Exception) {
                BridgeLog.w("config.json isn't a JSON object; ignoring it ($e)")
                return DEFAULT
            }
            return from(obj)
        }

        @JvmStatic
        fun from(obj: JSONObject): GlassConfig {
            val host = Json.str(obj, "host")?.trim()?.takeIf { it.isNotEmpty() }
            var port = Limits.DEFAULT_PORT
            val rawPort = Json.raw(obj, "port")
            val p: Long? = when (rawPort) {
                null -> null
                is String -> rawPort.trim().toLongOrNull()
                else -> Json.long(obj, "port")
            }
            if (p != null && p in 1..65535) {
                port = p.toInt()
            } else if (rawPort != null) {
                BridgeLog.w("config.json port $rawPort isn't 1-65535; using ${Limits.DEFAULT_PORT}")
            }
            val invert = Json.bool(obj, "invert_swipe") ?: when (Json.long(obj, "invert_swipe")) {
                1L -> true
                else -> false
            }
            return GlassConfig(host, port, invert)
        }

        /** Reads [file]; [DEFAULT] when it doesn't exist or can't be read. */
        @JvmStatic
        fun load(file: File): GlassConfig {
            if (!file.isFile) return DEFAULT
            return try {
                if (file.length() > MAX_BYTES) {
                    BridgeLog.w("config.json is over $MAX_BYTES bytes; ignoring it")
                    DEFAULT
                } else {
                    parse(String(file.readBytes(), Charsets.UTF_8))
                }
            } catch (e: Exception) {
                BridgeLog.w("Couldn't read ${file.path}: $e")
                DEFAULT
            }
        }
    }
}

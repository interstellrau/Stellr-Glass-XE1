package au.interstellr.glassbridge.core

import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * Apple Notification Center Service over Bluetooth LE (PROTOCOL.md section 10, a spike).
 *
 * Platform-free: UUIDs, packet builders and parsers, and the notification-to-card rule.
 * AncsClient (outside core) does the Bluetooth work. Byte layouts follow Apple's ANCS
 * specification; every multi-byte integer is little-endian.
 */
object Ancs {
    /** Advertised by the iPhone app so Glass can find the iPhone (PROTOCOL.md section 10). */
    @JvmField val GLASSBRIDGE_SERVICE: UUID = UUID.fromString("cd23bfcc-905c-457f-b5e7-180599d5dfd2")

    @JvmField val SERVICE: UUID = UUID.fromString("7905f431-b5ce-4e99-a40f-4b1e122d00d0")
    @JvmField val NOTIFICATION_SOURCE: UUID = UUID.fromString("9fbf120d-6301-42d9-8c58-25e699a21dbd")
    @JvmField val CONTROL_POINT: UUID = UUID.fromString("69d1d8f3-45e1-49a8-9821-9bbdfdaad9d9")
    @JvmField val DATA_SOURCE: UUID = UUID.fromString("22eac6e9-24d6-4bb5-be44-b36ace7c7bfb")

    /** Client Characteristic Configuration descriptor (enables notifications). */
    @JvmField val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val EVENT_ADDED = 0
    const val EVENT_MODIFIED = 1
    const val EVENT_REMOVED = 2

    const val FLAG_SILENT = 1
    const val FLAG_IMPORTANT = 2
    const val FLAG_PRE_EXISTING = 4

    const val CMD_GET_NOTIFICATION_ATTRIBUTES = 0
    const val CMD_GET_APP_ATTRIBUTES = 1

    const val ATTR_APP_IDENTIFIER = 0
    const val ATTR_TITLE = 1
    const val ATTR_SUBTITLE = 2
    const val ATTR_MESSAGE = 3

    const val APP_ATTR_DISPLAY_NAME = 0

    const val TITLE_MAX = 64
    const val SUBTITLE_MAX = 64
    const val MESSAGE_MAX = 256

    const val CARD_PREFIX = "ancs-"

    private val CATEGORIES = arrayOf(
        "Other", "Incoming call", "Missed call", "Voicemail", "Social", "Schedule", "Email",
        "News", "Health and fitness", "Business and finance", "Location", "Entertainment"
    )

    @JvmStatic
    fun categoryName(id: Int): String = if (id in CATEGORIES.indices) CATEGORIES[id] else "Other"

    @JvmStatic
    fun cardId(uid: Long): String = CARD_PREFIX + uid

    /** The request section 10 step 5 sends for an added or modified notification. */
    @JvmStatic
    fun notificationRequest(uid: Long): AncsRequest = AncsRequest.notification(
        uid,
        listOf(
            AncsAttr(ATTR_APP_IDENTIFIER, null),
            AncsAttr(ATTR_TITLE, TITLE_MAX),
            AncsAttr(ATTR_SUBTITLE, SUBTITLE_MAX),
            AncsAttr(ATTR_MESSAGE, MESSAGE_MAX)
        )
    )

    @JvmStatic
    fun appNameRequest(appId: String): AncsRequest =
        AncsRequest.app(appId, listOf(AncsAttr(APP_ATTR_DISPLAY_NAME, null)))

    /**
     * True if [record] (advertising data followed by the scan response, as KitKat's
     * LeScanCallback delivers it) lists [uuid] as a 128-bit service UUID (AD type 0x06 or
     * 0x07). Malformed or truncated records return false.
     */
    @JvmStatic
    fun advertises(record: ByteArray?, uuid: UUID): Boolean {
        if (record == null) return false
        val want = uuidLittleEndian(uuid)
        var i = 0
        while (i < record.size) {
            val len = record[i].toInt() and 0xFF
            if (len == 0) break
            val end = i + 1 + len
            if (end > record.size) return false
            val type = record[i + 1].toInt() and 0xFF
            if (type == 0x06 || type == 0x07) {
                var p = i + 2
                while (p + 16 <= end) {
                    if (regionEquals(record, p, want)) return true
                    p += 16
                }
            }
            i = end
        }
        return false
    }

    /**
     * The card for a notification. Chime and wake only for a new event that isn't
     * pre-existing or silent. With no title the app name stands in; with no subtitle or
     * message the category does (an incoming call has just the caller as its title).
     */
    @JvmStatic
    fun card(event: AncsEvent, attrs: Map<Int, String>, appName: String?, now: Long): Card {
        val title = attrs[ATTR_TITLE]?.trim().orEmpty()
        val subtitle = attrs[ATTR_SUBTITLE]?.trim().orEmpty()
        val message = attrs[ATTR_MESSAGE]?.trim().orEmpty()
        val app = appName?.trim()?.takeIf { it.isNotEmpty() }
            ?: attrs[ATTR_APP_IDENTIFIER]?.trim()?.takeIf { it.isNotEmpty() }
            ?: categoryName(event.categoryId)
        var text = listOf(subtitle, message).filter { it.isNotEmpty() }.joinToString("\n")
        if (text.isEmpty()) text = categoryName(event.categoryId)
        val alert = event.eventId == EVENT_ADDED && !event.isPreExisting && !event.isSilent
        return Card(
            id = cardId(event.uid),
            title = if (title.isNotEmpty()) title else app,
            text = text,
            source = app,
            time = now,
            style = Card.STYLE_NOTIFICATION,
            chime = alert,
            wake = alert,
            ttlS = null,
            expiresAt = null
        )
    }

    internal fun uuidLittleEndian(uuid: UUID): ByteArray {
        val out = ByteArray(16)
        var msb = uuid.mostSignificantBits
        var lsb = uuid.leastSignificantBits
        // Big-endian is msb then lsb; little-endian reverses all 16 bytes.
        for (k in 0 until 8) {
            out[k] = (lsb and 0xFF).toByte()
            lsb = lsb ushr 8
        }
        for (k in 8 until 16) {
            out[k] = (msb and 0xFF).toByte()
            msb = msb ushr 8
        }
        return out
    }

    private fun regionEquals(a: ByteArray, offset: Int, b: ByteArray): Boolean {
        for (k in b.indices) if (a[offset + k] != b[k]) return false
        return true
    }

    internal fun u16(b: ByteArray, i: Int): Int = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)

    internal fun u32(b: ByteArray, i: Int): Long =
        (b[i].toLong() and 0xFF) or
            ((b[i + 1].toLong() and 0xFF) shl 8) or
            ((b[i + 2].toLong() and 0xFF) shl 16) or
            ((b[i + 3].toLong() and 0xFF) shl 24)
}

/** One Notification Source packet (8 bytes). */
class AncsEvent(
    val eventId: Int,
    val flags: Int,
    val categoryId: Int,
    val categoryCount: Int,
    val uid: Long
) {
    val isRemoved: Boolean get() = eventId == Ancs.EVENT_REMOVED
    val isSilent: Boolean get() = flags and Ancs.FLAG_SILENT != 0
    val isPreExisting: Boolean get() = flags and Ancs.FLAG_PRE_EXISTING != 0

    override fun toString(): String =
        "AncsEvent(uid=$uid, event=$eventId, flags=$flags, category=${Ancs.categoryName(categoryId)})"

    companion object {
        /** Null unless [b] is at least 8 bytes. */
        @JvmStatic
        fun parse(b: ByteArray?): AncsEvent? {
            if (b == null || b.size < 8) return null
            return AncsEvent(
                eventId = b[0].toInt() and 0xFF,
                flags = b[1].toInt() and 0xFF,
                categoryId = b[2].toInt() and 0xFF,
                categoryCount = b[3].toInt() and 0xFF,
                uid = Ancs.u32(b, 4)
            )
        }
    }
}

/** A requested attribute; [maxLen] is sent for the ones ANCS needs it for (title, message). */
class AncsAttr(val id: Int, val maxLen: Int?)

/** A Control Point command: GetNotificationAttributes or GetAppAttributes. */
class AncsRequest private constructor(
    val command: Int,
    val uid: Long,
    val appId: String?,
    val attrs: List<AncsAttr>
) {
    /** The bytes written to Control Point. */
    fun bytes(): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(command)
        if (command == Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES) {
            for (k in 0 until 4) out.write(((uid ushr (8 * k)) and 0xFF).toInt())
        } else {
            val id = appId.orEmpty().toByteArray(Charsets.UTF_8)
            out.write(id, 0, id.size)
            out.write(0)
        }
        for (a in attrs) {
            out.write(a.id)
            val max = a.maxLen
            if (max != null) {
                out.write(max and 0xFF)
                out.write((max shr 8) and 0xFF)
            }
        }
        return out.toByteArray()
    }

    override fun toString(): String =
        if (command == Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES) "GetNotificationAttributes($uid)"
        else "GetAppAttributes($appId)"

    companion object {
        @JvmStatic
        fun notification(uid: Long, attrs: List<AncsAttr>) =
            AncsRequest(Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES, uid, null, attrs)

        @JvmStatic
        fun app(appId: String, attrs: List<AncsAttr>) =
            AncsRequest(Ancs.CMD_GET_APP_ATTRIBUTES, 0L, appId, attrs)
    }
}

/** A complete Data Source response. [attrs] maps attribute id to its UTF-8 value. */
class AncsResponse(val request: AncsRequest, val attrs: Map<Int, String>)

/**
 * Reassembles the Data Source response to one [request]. ANCS splits a response across as
 * many notifications as the ATT MTU needs (20-byte payloads on KitKat), and answers with
 * every requested attribute in order, an empty one with length 0.
 */
class AncsResponseReader(val request: AncsRequest) {
    private val buf = ByteArrayOutputStream()

    /** Set once the bytes can't be the response to [request]; feed then returns null. */
    var error: String? = null
        private set

    /** Adds a Data Source chunk. Returns the response once it's complete, otherwise null. */
    fun feed(chunk: ByteArray): AncsResponse? {
        if (error != null) return null
        buf.write(chunk, 0, chunk.size)
        return tryParse(buf.toByteArray())
    }

    private fun tryParse(b: ByteArray): AncsResponse? {
        if (b.isEmpty()) return null
        if ((b[0].toInt() and 0xFF) != request.command) {
            error = "command ${b[0].toInt() and 0xFF}, expected ${request.command}"
            return null
        }
        var p: Int
        if (request.command == Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES) {
            if (b.size < 5) return null
            val uid = Ancs.u32(b, 1)
            if (uid != request.uid) {
                error = "uid $uid, expected ${request.uid}"
                return null
            }
            p = 5
        } else {
            var z = 1
            while (z < b.size && b[z].toInt() != 0) z++
            if (z >= b.size) return null
            val appId = String(b, 1, z - 1, Charsets.UTF_8)
            if (appId != request.appId) {
                error = "app $appId, expected ${request.appId}"
                return null
            }
            p = z + 1
        }
        val attrs = LinkedHashMap<Int, String>()
        for (want in request.attrs) {
            if (p + 3 > b.size) return null
            val id = b[p].toInt() and 0xFF
            val len = Ancs.u16(b, p + 1)
            if (p + 3 + len > b.size) return null
            if (id != want.id) {
                error = "attribute $id, expected ${want.id}"
                return null
            }
            attrs[id] = String(b, p + 3, len, Charsets.UTF_8)
            p += 3 + len
        }
        return AncsResponse(request, attrs)
    }
}

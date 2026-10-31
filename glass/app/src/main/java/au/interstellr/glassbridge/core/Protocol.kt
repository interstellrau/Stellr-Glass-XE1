package au.interstellr.glassbridge.core

import org.json.JSONObject

/** Every message type in PROTOCOL.md section 5. */
object MsgType {
    const val HELLO = "hello"
    const val WELCOME = "welcome"
    const val REJECTED = "rejected"
    const val PING = "ping"
    const val PONG = "pong"
    const val STATUS = "status"
    const val REQUEST_STATUS = "request_status"
    const val CARD = "card"
    const val DISMISS = "dismiss"
    const val SPEAK = "speak"
    const val ACK = "ack"
    const val NAV = "nav"
    const val NAV_END = "nav_end"
    const val LOCATION = "location"
    const val SYNC = "sync"
    const val FILE_BEGIN = "file_begin"
    const val FILE_CHUNK = "file_chunk"
    const val FILE_END = "file_end"
    const val FILE_ACK = "file_ack"
    const val SCREENCAST = "screencast"
    const val FRAME = "frame"
    const val WIFI_ADD = "wifi_add"
    const val WIFI_RESULT = "wifi_result"
}

/**
 * Builders for every Glass to iPhone message (PROTOCOL.md section 5). Each call returns a
 * new JSONObject with "type" first. Payload frames (file_chunk, frame) get "bytes" from
 * [FrameWriter] when they are sent with their payload.
 */
object Msg {
    const val DEVICE = "glass-explorer"

    const val EVENT_SHOWN = "shown"
    const val EVENT_DISMISSED = "dismissed"
    const val EVENT_TAPPED = "tapped"

    /** A bare message of [type]. */
    @JvmStatic
    fun of(type: String): JSONObject = JSONObject().put("type", type)

    /** First frame on every connection. [token] is left out when null or empty (PROTOCOL.md section 6). */
    @JvmStatic
    @JvmOverloads
    fun hello(model: String, firmware: String, appVersion: String, token: String? = null): JSONObject {
        val o = of(MsgType.HELLO)
            .put("device", DEVICE)
            .put("version", Limits.PROTOCOL_VERSION)
            .put("model", model)
            .put("firmware", firmware)
            .put("app_version", appVersion)
        if (!token.isNullOrEmpty()) o.put("token", token)
        return o
    }

    /** Device status. [wifiSsid] and [wifiRssi] are left out when null. */
    @JvmStatic
    fun status(
        battery: Int,
        charging: Boolean,
        storageFreeMb: Long,
        storageTotalMb: Long,
        wifiSsid: String?,
        wifiRssi: Int?,
        mockLocation: Boolean,
        screenOn: Boolean,
        uptimeS: Long
    ): JSONObject {
        val o = of(MsgType.STATUS)
            .put("battery", Math.max(0, Math.min(100, battery)))
            .put("charging", charging)
            .put("storage_free_mb", storageFreeMb)
            .put("storage_total_mb", storageTotalMb)
        if (wifiSsid != null) o.put("wifi_ssid", wifiSsid)
        if (wifiRssi != null) o.put("wifi_rssi", wifiRssi)
        return o.put("mock_location", mockLocation)
            .put("screen_on", screenOn)
            .put("uptime_s", uptimeS)
    }

    /** Card acknowledgement; [event] is [EVENT_SHOWN], [EVENT_DISMISSED] or [EVENT_TAPPED]. */
    @JvmStatic
    fun ack(id: String, event: String): JSONObject = of(MsgType.ACK).put("id", id).put("event", event)

    @JvmStatic
    fun fileBegin(id: String, name: String, size: Long, mime: String, taken: Long): JSONObject =
        of(MsgType.FILE_BEGIN).put("id", id).put("name", name).put("size", size).put("mime", mime).put("taken", taken)

    /** Send with the chunk as payload; "bytes" is added by the writer. */
    @JvmStatic
    fun fileChunk(id: String, offset: Long): JSONObject = of(MsgType.FILE_CHUNK).put("id", id).put("offset", offset)

    @JvmStatic
    fun fileEnd(id: String): JSONObject = of(MsgType.FILE_END).put("id", id)

    /** Screencast frame header; send with the JPEG as payload. */
    @JvmStatic
    fun frame(w: Int, h: Int): JSONObject = of(MsgType.FRAME).put("w", w).put("h", h)

    /** Result of a wifi_add. [error] is left out when null. */
    @JvmStatic
    @JvmOverloads
    fun wifiResult(ssid: String, ok: Boolean, error: String? = null): JSONObject {
        val o = of(MsgType.WIFI_RESULT).put("ssid", ssid).put("ok", ok)
        if (error != null) o.put("error", error)
        return o
    }

    @JvmStatic
    fun ping(): JSONObject = of(MsgType.PING)

    @JvmStatic
    fun pong(): JSONObject = of(MsgType.PONG)
}

/**
 * A card from the iPhone (or made on Glass, such as the "Paired" card).
 *
 * [time] is epoch ms (the card's own time, shown in the footer). [expiresAt] is epoch ms on
 * Glass's clock, set from `ttl_s` relative to when the card arrived; null means it never
 * expires.
 */
class Card(
    val id: String,
    val title: String,
    val text: String,
    val source: String?,
    val time: Long,
    val style: String,
    val chime: Boolean,
    val wake: Boolean,
    val ttlS: Long?,
    val expiresAt: Long?
) {
    val isNotification: Boolean get() = style == STYLE_NOTIFICATION

    fun isExpired(now: Long): Boolean = expiresAt != null && now >= expiresAt

    override fun toString(): String = "Card($id, \"$title\", style=$style)"

    companion object {
        const val STYLE_INFO = "info"
        const val STYLE_NOTIFICATION = "notification"

        /**
         * Reads a `card` message. Defaults: style "info" (anything but "notification" is
         * info), time now, chime and wake false, no expiry. A positive `ttl_s` sets
         * expiresAt = now + ttl_s. A missing id becomes "card-<now>"; missing title and text
         * become "".
         */
        @JvmStatic
        @JvmOverloads
        fun from(obj: JSONObject, now: Long = System.currentTimeMillis()): Card {
            val id = Json.text(obj, "id")?.takeIf { it.isNotEmpty() } ?: "card-$now"
            val ttl = Json.long(obj, "ttl_s")
            val style = if (Json.str(obj, "style") == STYLE_NOTIFICATION) STYLE_NOTIFICATION else STYLE_INFO
            return Card(
                id = id,
                title = Json.text(obj, "title") ?: "",
                text = Json.text(obj, "text") ?: "",
                source = Json.str(obj, "source")?.takeIf { it.isNotEmpty() },
                time = Json.long(obj, "time") ?: now,
                style = style,
                chime = Json.bool(obj, "chime") ?: false,
                wake = Json.bool(obj, "wake") ?: false,
                ttlS = ttl,
                expiresAt = if (ttl != null && ttl > 0) now + ttl * 1000L else null
            )
        }
    }
}

/** The pinned navigation card, from a `nav` message. Distances are metres. */
class NavState(
    val instruction: String,
    val maneuver: String,
    val distanceM: Double,
    val street: String?,
    val step: Int,
    val stepsTotal: Int,
    val etaMin: Int?,
    val remainingM: Double?,
    val destination: String?,
    val arrived: Boolean,
    val announce: Boolean
) {
    /** Distance to the next maneuver, formatted with [formatDistance]. */
    val distanceText: String get() = formatDistance(distanceM)

    /** Footer: "12 min · 1.2 km", either part left out when unknown; "" when both are. */
    val footerText: String
        get() {
            val parts = ArrayList<String>(2)
            if (etaMin != null) parts.add("$etaMin min")
            if (remainingM != null) parts.add(formatDistance(remainingM))
            return parts.joinToString(" · ")
        }

    /** True when this update starts a new step compared with [previous] (Glass wakes and chimes). */
    fun isNewStep(previous: NavState?): Boolean = previous == null || previous.step != step

    override fun toString(): String = "NavState(step $step/$stepsTotal $maneuver ${distanceText}: $instruction)"

    companion object {
        /** Valid maneuvers (PROTOCOL.md section 5). */
        @JvmField
        val MANEUVERS: List<String> = listOf(
            "depart", "straight", "left", "right", "slight_left", "slight_right",
            "sharp_left", "sharp_right", "uturn", "arrive"
        )

        /** [raw] if it's a known maneuver, otherwise "straight". */
        @JvmStatic
        fun maneuverOf(raw: String?): String = if (raw != null && raw in MANEUVERS) raw else "straight"

        @JvmStatic
        fun from(obj: JSONObject): NavState = NavState(
            instruction = Json.text(obj, "instruction") ?: "",
            maneuver = maneuverOf(Json.str(obj, "maneuver")),
            distanceM = Math.max(0.0, Json.double(obj, "distance_m") ?: 0.0),
            street = Json.str(obj, "street")?.takeIf { it.isNotEmpty() },
            step = Json.int(obj, "step") ?: 0,
            stepsTotal = Json.int(obj, "steps_total") ?: 0,
            etaMin = Json.int(obj, "eta_min"),
            remainingM = Json.double(obj, "remaining_m"),
            destination = Json.str(obj, "destination")?.takeIf { it.isNotEmpty() },
            arrived = Json.bool(obj, "arrived") ?: false,
            announce = Json.bool(obj, "announce") ?: false
        )
    }
}

/**
 * Distance for the nav card: rounded to 5 m under 50 m, to 10 m under 1 km, "x.x km" under
 * 10 km and whole km above. 27 m shows as "25 m". A value that rounds up to the next band's
 * threshold uses that band (999 m is "1.0 km", 9,960 m is "10 km"). Negative or NaN is "0 m".
 * Locale-independent (always a "." decimal point).
 */
fun formatDistance(meters: Double): String {
    val m = if (meters.isNaN() || meters < 0) 0.0 else meters
    if (m < 50) {
        val r = Math.round(m / 5.0) * 5
        if (r < 50) return "$r m"
    }
    if (m < 1000) {
        val r = Math.round(m / 10.0) * 10
        if (r < 1000) return "$r m"
    }
    if (m < 10000) {
        val tenths = Math.round(m / 100.0)
        if (tenths < 100) return "${tenths / 10}.${tenths % 10} km"
    }
    return "${Math.round(m / 1000.0)} km"
}

/**
 * A phone GPS fix from a `location` message. [accM] is never null: Android 4.2+ refuses a
 * mock Location without an accuracy, so a missing, negative or NaN `acc_m` becomes
 * [DEFAULT_ACCURACY_M]. [time] is the phone's epoch ms (MockGps stamps fixes with Glass's
 * own clock anyway, because KitKat rejects stale fixes).
 */
class LocationFix(
    val lat: Double,
    val lon: Double,
    val accM: Double,
    val altM: Double?,
    val speedMps: Double?,
    val bearing: Double?,
    val time: Long
) {
    override fun toString(): String = "LocationFix($lat, $lon ±$accM m)"

    companion object {
        const val DEFAULT_ACCURACY_M = 10.0

        /** Null when lat/lon are missing, NaN or out of range (skip the fix). */
        @JvmStatic
        @JvmOverloads
        fun from(obj: JSONObject, now: Long = System.currentTimeMillis()): LocationFix? {
            val lat = Json.double(obj, "lat") ?: return null
            val lon = Json.double(obj, "lon") ?: return null
            if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) return null
            val acc = Json.double(obj, "acc_m")
            return LocationFix(
                lat = lat,
                lon = lon,
                accM = if (acc == null || acc < 0) DEFAULT_ACCURACY_M else acc,
                altM = Json.double(obj, "alt_m"),
                speedMps = Json.double(obj, "speed_mps")?.takeIf { it >= 0 },
                bearing = Json.double(obj, "bearing")?.takeIf { it >= 0 },
                time = Json.long(obj, "time") ?: now
            )
        }
    }
}

/** A `screencast` command: [fps] is clamped to 1..5 (default 2). */
class ScreencastCmd(val on: Boolean, val fps: Int) {
    /** Milliseconds between frames. */
    val intervalMs: Long get() = 1000L / fps

    companion object {
        const val DEFAULT_FPS = 2
        const val MIN_FPS = 1
        const val MAX_FPS = 5

        @JvmStatic
        fun from(obj: JSONObject): ScreencastCmd {
            val fps = Json.int(obj, "fps") ?: DEFAULT_FPS
            return ScreencastCmd(Json.bool(obj, "on") ?: false, Math.max(MIN_FPS, Math.min(MAX_FPS, fps)))
        }
    }
}

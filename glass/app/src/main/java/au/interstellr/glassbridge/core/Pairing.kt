package au.interstellr.glassbridge.core

import org.json.JSONObject

/**
 * Pairing token handling on Glass (PROTOCOL.md section 6).
 *
 * Glass keeps the token in SharedPreferences [PREFS] / [KEY_TOKEN], sends it in every
 * `hello` ([Msg.hello]), replaces it when `welcome` carries `pair_token`
 * ([Welcome.pairToken]), and on `rejected` shows [REJECTED_HINT] in place of the empty-state
 * text while BridgeConnection retries every 5 s.
 */
object Pairing {
    const val PREFS = "link"
    const val KEY_TOKEN = "token"

    /** Id of the local card shown after a new pairing (re-pairing replaces it in place). */
    const val CARD_ID = "glassbridge-paired"
    const val CARD_TITLE = "Paired"
    const val CARD_SOURCE = "GlassBridge"

    /** Shown in place of the empty-state text after `rejected`. */
    const val REJECTED_HINT = "Pair on your iPhone: GlassBridge › Glass › Pair Glass"

    /** The short form for the one-line footer of a card or nav page after `rejected`. */
    const val REJECTED_FOOTER = "Not paired: pair on your iPhone"

    /** Longest token Glass will store (the protocol's are 32 characters). */
    const val MAX_TOKEN_LENGTH = 256

    private val WELL_FORMED = Regex("^[0-9a-f]{32}$")

    /** True for a token exactly as the protocol specifies: 32 lowercase hex characters. */
    @JvmStatic
    fun isWellFormed(token: String?): Boolean = token != null && WELL_FORMED.matches(token)

    /**
     * The token to store, or null if [raw] is unusable (null, blank, too long, or has
     * control characters). Surrounding whitespace is trimmed. A token that isn't 32
     * lowercase hex is still accepted (and logged), so a slightly different iPhone build
     * can't lock Glass out; the iPhone compares it as an opaque string.
     */
    @JvmStatic
    fun normalizeToken(raw: String?): String? {
        val t = raw?.trim() ?: return null
        if (t.isEmpty() || t.length > MAX_TOKEN_LENGTH) return null
        for (c in t) if (c < ' ' || c == '\u007F') return null
        if (!isWellFormed(t)) BridgeLog.w("Pairing token isn't 32 lowercase hex characters; storing it anyway")
        return t
    }

    /** Card text after a new pairing: the phone's name, then "Code NNNN". */
    @JvmStatic
    fun pairedText(phoneName: String, code: String?): String =
        if (code.isNullOrEmpty()) phoneName else phoneName + "\n" + "Code " + code

    /** The "Paired" card (wake and chime) for a welcome that carried pair fields. */
    @JvmStatic
    @JvmOverloads
    fun pairedCard(welcome: Welcome, now: Long = System.currentTimeMillis()): Card = Card(
        id = CARD_ID,
        title = CARD_TITLE,
        text = pairedText(welcome.phoneName, welcome.pairCode),
        source = CARD_SOURCE,
        time = now,
        style = Card.STYLE_INFO,
        chime = true,
        wake = true,
        ttlS = null,
        expiresAt = null
    )
}

/**
 * A `welcome` message. [pairToken] is non-null only when this hello was just paired
 * (already normalized with [Pairing.normalizeToken]); then [pairCode] is the 4-digit code to
 * show. [phoneName] defaults to "iPhone".
 */
class Welcome(
    val server: String?,
    val version: Int?,
    val phoneName: String,
    val pairToken: String?,
    val pairCode: String?
) {
    val isNewPairing: Boolean get() = pairToken != null

    companion object {
        const val DEFAULT_PHONE_NAME = "iPhone"

        @JvmStatic
        fun from(obj: JSONObject): Welcome {
            val token = Pairing.normalizeToken(Json.str(obj, "pair_token"))
            var code = Json.text(obj, "pair_code")?.trim()?.takeIf { it.isNotEmpty() }
            // The code is a string such as "0042"; if a number arrives, restore the zeros.
            if (code != null && Json.str(obj, "pair_code") == null && code.length < 4 && code.all { it in '0'..'9' }) {
                code = "0000".substring(code.length) + code
            }
            return Welcome(
                server = Json.str(obj, "server"),
                version = Json.int(obj, "version"),
                phoneName = Json.text(obj, "phone_name")?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_PHONE_NAME,
                pairToken = token,
                pairCode = if (token != null) code else null
            )
        }
    }
}

/** A `rejected` message: [reason] is [PAIRING_REQUIRED], [BAD_TOKEN] or something newer. */
class Rejected(val reason: String, val message: String?) {
    companion object {
        const val PAIRING_REQUIRED = "pairing_required"
        const val BAD_TOKEN = "bad_token"

        @JvmStatic
        fun from(obj: JSONObject): Rejected =
            Rejected(Json.str(obj, "reason") ?: PAIRING_REQUIRED, Json.str(obj, "message"))
    }
}

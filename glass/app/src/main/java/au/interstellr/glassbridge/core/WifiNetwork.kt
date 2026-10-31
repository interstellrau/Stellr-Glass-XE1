package au.interstellr.glassbridge.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * A Wi-Fi network to save on Glass, from `wifi_add` or `wifi.json` (PROTOCOL.md sections 5
 * and 7). [security] is always [WPA], [WEP] or [OPEN].
 *
 * The Android side (WifiProvisioner) builds a WifiConfiguration from it: SSID quoted with
 * [quoted]; WPA as KeyMgmt.WPA_PSK with preSharedKey = [pskValue]; WEP with
 * wepKeys[0] = [wepKeyValue]; then removes networks with the same SSID (the one Glass is on
 * is updated in place instead, so the link doesn't drop), enableNetwork(id, false) and
 * saveConfiguration().
 */
class WifiNetwork(val ssid: String, val password: String?, val security: String) {

    /** Why this network can't be saved, or null if it looks valid. */
    fun problem(): String? = when (security) {
        WPA -> {
            val p = password
            when {
                p == null || p.isEmpty() -> "a WPA network needs a password"
                p.length == 64 && isHex(p) -> null
                p.length < 8 || p.length > 63 -> "a WPA password must be 8 to 63 characters"
                else -> null
            }
        }
        WEP -> if (password.isNullOrEmpty()) "a WEP network needs a key" else null
        else -> null
    }

    override fun toString(): String = "WifiNetwork(\"$ssid\", $security)" // never the password

    companion object {
        const val WPA = "WPA"
        const val WEP = "WEP"
        const val OPEN = "OPEN"

        /** File pushed over adb into the app's external files dir. */
        const val FILE_NAME = "wifi.json"

        /** One network from a JSON object; null when `ssid` is missing or empty. */
        @JvmStatic
        fun from(obj: JSONObject): WifiNetwork? {
            val ssid = Json.text(obj, "ssid")?.takeIf { it.isNotEmpty() } ?: return null
            val password = Json.text(obj, "password")?.takeIf { it.isNotEmpty() }
            return WifiNetwork(ssid, password, normalizeSecurity(Json.str(obj, "security"), password))
        }

        /**
         * Networks in a `wifi.json`: one object or an array of objects. Entries without an
         * SSID are skipped; text that isn't JSON gives an empty list (logged).
         */
        @JvmStatic
        fun parseFile(text: String?): List<WifiNetwork> {
            val t = text?.trim() ?: return emptyList()
            if (t.isEmpty()) return emptyList()
            val out = ArrayList<WifiNetwork>()
            try {
                if (t.startsWith("[")) {
                    val arr = JSONArray(t)
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        from(o)?.let { out.add(it) }
                    }
                } else {
                    from(JSONObject(t))?.let { out.add(it) }
                }
            } catch (e: Exception) {
                BridgeLog.w("wifi.json isn't valid JSON; ignoring it ($e)")
            }
            return out
        }

        /**
         * WPA, WPA2, WPA3, WPA-PSK, WPA2-PSK and PSK are [WPA]; WEP is [WEP]; OPEN, NONE,
         * NOPASS and "" are [OPEN]. Anything else (or none) is WPA with a password, OPEN
         * without one. Case-insensitive.
         */
        @JvmStatic
        fun normalizeSecurity(raw: String?, password: String?): String {
            val s = raw?.trim()?.uppercase()
            return when {
                s == null -> if (password.isNullOrEmpty()) OPEN else WPA
                s == "WEP" -> WEP
                s == "OPEN" || s == "NONE" || s == "NOPASS" || s.isEmpty() -> OPEN
                s.startsWith("WPA") || s == "PSK" -> WPA
                else -> if (password.isNullOrEmpty()) OPEN else WPA
            }
        }

        /** "\"text\"", as WifiConfiguration wants for SSIDs, PSKs and ASCII WEP keys. */
        @JvmStatic
        fun quoted(s: String): String = "\"" + s + "\""

        /** WPA preSharedKey: a 64-hex-digit raw key as is, otherwise the quoted passphrase. */
        @JvmStatic
        fun pskValue(password: String): String = if (password.length == 64 && isHex(password)) password else quoted(password)

        /** True for a hex WEP key (10, 26 or 58 hex digits), which goes in unquoted. */
        @JvmStatic
        fun isHexWepKey(key: String): Boolean = (key.length == 10 || key.length == 26 || key.length == 58) && isHex(key)

        /** WEP key value: hex keys as is, anything else quoted. */
        @JvmStatic
        fun wepKeyValue(key: String): String = if (isHexWepKey(key)) key else quoted(key)

        private fun isHex(s: String): Boolean = s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }
}

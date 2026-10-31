package au.interstellr.glassbridge.core

/**
 * Network helpers for discovery and status (PROTOCOL.md section 2).
 */
object NetUtil {
    /** iOS Personal Hotspot subnet 172.20.10.0/28, as a big-endian int and mask. */
    private const val HOTSPOT_NET = (172 shl 24) or (20 shl 16) or (10 shl 8)
    private const val HOTSPOT_MASK = -16 // 0xFFFFFFF0

    /**
     * Dotted IPv4 text for an address stored as a little-endian int, the way
     * `WifiManager.getDhcpInfo().gateway` and `WifiInfo.getIpAddress()` store it
     * (0x010A14AC is "172.20.10.1"). Converted byte by byte.
     */
    @JvmStatic
    fun ipv4FromLittleEndian(addr: Int): String =
        (addr and 0xFF).toString() + "." + ((addr ushr 8) and 0xFF) + "." +
            ((addr ushr 16) and 0xFF) + "." + ((addr ushr 24) and 0xFF)

    /** The address as a big-endian int, or null if [ip] isn't a dotted IPv4 address. */
    @JvmStatic
    fun parseIpv4(ip: String?): Int? {
        if (ip == null) return null
        val parts = ip.trim().split('.')
        if (parts.size != 4) return null
        var v = 0
        for (p in parts) {
            if (p.isEmpty() || p.length > 3 || !p.all { it in '0'..'9' }) return null
            val n = p.toInt()
            if (n > 255) return null
            v = (v shl 8) or n
        }
        return v
    }

    /** True if [ip] is in 172.20.10.0/28, the iOS Personal Hotspot range. */
    @JvmStatic
    fun isHotspotAddress(ip: String?): Boolean {
        val v = parseIpv4(ip) ?: return false
        return (v and HOTSPOT_MASK) == HOTSPOT_NET
    }

    /**
     * The iPhone's endpoint when the Wi-Fi DHCP gateway (little-endian int, as in DhcpInfo)
     * is in the hotspot range, otherwise null (also for 0, "no gateway").
     */
    @JvmStatic
    @JvmOverloads
    fun hotspotEndpoint(dhcpGatewayLittleEndian: Int, port: Int = Limits.DEFAULT_PORT): Endpoint? {
        if (dhcpGatewayLittleEndian == 0) return null
        val ip = ipv4FromLittleEndian(dhcpGatewayLittleEndian)
        return if (isHotspotAddress(ip)) Endpoint(ip, port, Endpoint.VIA_HOTSPOT) else null
    }

    /**
     * The SSID from `WifiInfo.getSSID()` for `status`, or null when there isn't a usable one.
     * Strips the quotes KitKat adds and ignores "<unknown ssid>", "0x" and empty values.
     */
    @JvmStatic
    fun cleanSsid(raw: String?): String? {
        var s = raw?.trim() ?: return null
        if (s.length >= 2 && s.startsWith("\"") && s.endsWith("\"")) s = s.substring(1, s.length - 1)
        if (s.isEmpty() || s == "<unknown ssid>" || s == "0x" || s == "0x0") return null
        return s
    }
}

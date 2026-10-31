@file:Suppress("DEPRECATION") // WifiConfiguration and friends are the right API on Glass (API 19).

package au.interstellr.glassbridge

import android.content.Context
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.WifiNetwork
import java.io.File

/**
 * Saves Wi-Fi networks from `wifi_add` or `wifi.json` (brief "Wi-Fi provisioning",
 * PROTOCOL.md section 7).
 *
 * WifiConfiguration with a quoted SSID; WPA/WPA2/WPA3 as KeyMgmt.WPA_PSK with a quoted PSK
 * (or a raw 64-hex key); WEP keys hex (10, 26 or 58 characters) or quoted; open networks as
 * KeyMgmt.NONE. Saved networks with the same SSID are removed first, then
 * `enableNetwork(id, false)` (other saved networks stay enabled) and `saveConfiguration()`.
 *
 * Except the network Glass is on right now: removing it would make wpa_supplicant
 * deauthenticate, which drops the iPhone link (and the `wifi_result` with it). That entry is
 * updated in place with `updateNetwork` instead, which leaves the current association alone;
 * new settings take effect the next time Glass joins it.
 *
 * Blocking (it may wait for Wi-Fi to turn on): call it from a worker thread. Passwords are
 * never logged.
 */
class WifiProvisioner(context: Context) {
    private val app = context.applicationContext
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    /** Saves [n]; returns null on success or the error for `wifi_result`. */
    fun save(n: WifiNetwork): String? {
        n.problem()?.let {
            BridgeLog.w("Not saving $n: $it")
            return it
        }
        try {
            if (!ensureWifiEnabled()) return "Wi-Fi is off and couldn't be turned on"

            val quotedSsid = WifiNetwork.quoted(n.ssid)
            val cfg = WifiConfiguration()
            cfg.SSID = quotedSsid
            val pw = n.password
            when (n.security) {
                WifiNetwork.WPA -> {
                    cfg.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
                    cfg.preSharedKey = WifiNetwork.pskValue(pw ?: "")
                }
                WifiNetwork.WEP -> {
                    cfg.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
                    cfg.allowedAuthAlgorithms.set(WifiConfiguration.AuthAlgorithm.OPEN)
                    cfg.allowedAuthAlgorithms.set(WifiConfiguration.AuthAlgorithm.SHARED)
                    cfg.allowedGroupCiphers.set(WifiConfiguration.GroupCipher.WEP40)
                    cfg.allowedGroupCiphers.set(WifiConfiguration.GroupCipher.WEP104)
                    cfg.wepKeys[0] = WifiNetwork.wepKeyValue(pw ?: "")
                    cfg.wepTxKeyIndex = 0
                }
                else -> cfg.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            }

            val activeId = wifi.connectionInfo?.networkId ?: -1
            var keepId = -1
            val existing = wifi.configuredNetworks
            if (existing != null) {
                for (c in existing) {
                    if (c.SSID == quotedSsid || c.SSID == n.ssid) {
                        if (activeId != -1 && c.networkId == activeId) {
                            keepId = c.networkId
                            continue
                        }
                        val removed = wifi.removeNetwork(c.networkId)
                        BridgeLog.i("Removed saved network ${c.networkId} with the same SSID (${if (removed) "ok" else "refused"})")
                    }
                }
            }

            val id: Int
            if (keepId != -1) {
                // Glass is on this network now: update it in place, never remove it.
                cfg.networkId = keepId
                id = wifi.updateNetwork(cfg)
                if (id < 0) {
                    BridgeLog.w("updateNetwork refused $n (network $keepId, the one Glass is on); left as it was")
                    return "Glass refused the network settings (it's the network Glass is on now)"
                }
                BridgeLog.i("Updated network $keepId in place: Glass is on it now, so it stays connected")
            } else {
                id = wifi.addNetwork(cfg)
                if (id < 0) {
                    BridgeLog.w("addNetwork refused $n")
                    return "Glass refused the network settings"
                }
            }
            wifi.enableNetwork(id, false)
            if (!wifi.saveConfiguration()) BridgeLog.w("saveConfiguration returned false for $n")

            // Nudge an association if Glass isn't on any network right now; never disturb a live one.
            val info = wifi.connectionInfo
            if (info == null || info.networkId == -1) wifi.reconnect()

            BridgeLog.i("Saved $n as network $id")
            return null
        } catch (e: SecurityException) {
            BridgeLog.w("Saving $n not allowed: ${e.message}")
            return "not allowed: ${e.message}"
        } catch (e: RuntimeException) {
            BridgeLog.w("Saving $n failed: $e")
            return "failed: $e"
        }
    }

    /**
     * Reads `wifi.json` from the app's external files dir if it's there, deletes it straight
     * away (so the password doesn't sit on the SD card) and saves every network in it.
     * Returns how many were saved.
     */
    fun applyWifiJson(): Int {
        val dir = app.getExternalFilesDir(null) ?: return 0
        val file = File(dir, WifiNetwork.FILE_NAME)
        if (!file.isFile) return 0
        val text = try {
            if (file.length() > MAX_FILE_BYTES) {
                BridgeLog.w("wifi.json is over $MAX_FILE_BYTES bytes; ignoring it")
                null
            } else {
                String(file.readBytes(), Charsets.UTF_8)
            }
        } catch (e: Exception) {
            BridgeLog.w("Couldn't read wifi.json: $e")
            null
        }
        if (!file.delete()) BridgeLog.w("Couldn't delete ${file.path}; delete it with adb")
        val networks = WifiNetwork.parseFile(text)
        if (networks.isEmpty()) {
            BridgeLog.w("wifi.json held no usable network")
            return 0
        }
        var saved = 0
        for (n in networks) {
            val err = save(n)
            if (err == null) saved++ else BridgeLog.w("wifi.json: $n not saved: $err")
        }
        BridgeLog.i("wifi.json: saved $saved of ${networks.size} network(s)")
        return saved
    }

    private fun ensureWifiEnabled(): Boolean {
        if (wifi.isWifiEnabled) return true
        BridgeLog.i("Turning Wi-Fi on to save a network")
        if (!wifi.setWifiEnabled(true)) return false
        val deadline = System.currentTimeMillis() + WIFI_ON_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            if (wifi.wifiState == WifiManager.WIFI_STATE_ENABLED) return true
            try {
                Thread.sleep(250)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return wifi.wifiState == WifiManager.WIFI_STATE_ENABLED
    }

    companion object {
        const val WIFI_ON_TIMEOUT_MS = 10_000L
        const val MAX_FILE_BYTES = 64 * 1024
    }
}

@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import au.interstellr.glassbridge.core.BatteryMath
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Msg
import au.interstellr.glassbridge.core.NetUtil
import org.json.JSONObject

/**
 * Builds `status` (PROTOCOL.md section 5): battery from the sticky ACTION_BATTERY_CHANGED,
 * storage from StatFs on external storage, SSID and RSSI from WifiInfo (ignoring
 * "<unknown ssid>" and "0x"), the screen state and elapsedRealtime.
 *
 * Use a Service or Activity context (a receiver context can't read the sticky broadcast).
 */
class DeviceStatus(private val context: Context) {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val power = context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager

    fun build(mockLocation: Boolean): JSONObject {
        val battery = batteryIntent()
        val pct = batteryPercent(battery)

        var freeMb = 0L
        var totalMb = 0L
        try {
            val fs = StatFs(Environment.getExternalStorageDirectory().path)
            freeMb = fs.availableBlocksLong * fs.blockSizeLong / MB
            totalMb = fs.blockCountLong * fs.blockSizeLong / MB
        } catch (e: RuntimeException) {
            BridgeLog.w("StatFs failed: $e")
        }

        var ssid: String? = null
        var rssi: Int? = null
        try {
            val info = wifi.connectionInfo
            ssid = NetUtil.cleanSsid(info?.ssid)
            if (ssid != null && info != null) rssi = info.rssi
        } catch (e: RuntimeException) {
            BridgeLog.w("WifiInfo failed: $e")
        }

        @Suppress("DEPRECATION")
        val screenOn = power.isScreenOn

        return Msg.status(
            battery = Math.max(0, pct),
            charging = isCharging(battery),
            storageFreeMb = freeMb,
            storageTotalMb = totalMb,
            wifiSsid = ssid,
            wifiRssi = rssi,
            mockLocation = mockLocation,
            screenOn = screenOn,
            uptimeS = SystemClock.elapsedRealtime() / 1000L
        )
    }

    fun batteryIntent(): Intent? = try {
        context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    } catch (e: RuntimeException) {
        BridgeLog.w("Battery state unavailable: $e")
        null
    }

    companion object {
        private const val MB = 1024L * 1024L

        /** Battery percent from an ACTION_BATTERY_CHANGED intent; -1 when unknown. */
        @JvmStatic
        fun batteryPercent(i: Intent?): Int {
            if (i == null) return -1
            return BatteryMath.percent(i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), i.getIntExtra(BatteryManager.EXTRA_SCALE, 100))
        }

        @JvmStatic
        fun isCharging(i: Intent?): Boolean {
            if (i == null) return false
            val status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            return status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL || plugged != 0
        }
    }
}

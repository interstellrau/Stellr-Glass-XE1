@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.content.Context
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.os.SystemClock
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.LocationFix

/**
 * Feeds the phone's GPS into Android's `gps` provider as a test provider (brief "Mock GPS").
 *
 * [start] removes any existing test provider, then calls
 * `addTestProvider(GPS_PROVIDER, false, false, false, false, true, true, true, POWER_LOW,
 * ACCURACY_FINE)` and `setTestProviderEnabled(true)`. A SecurityException means mock
 * locations are off: the user runs `adb shell settings put secure mock_location 1` once
 * (Glass has no UI for it). [isActive] goes into `status.mock_location`.
 *
 * Fixes are stamped with Glass's own currentTimeMillis and elapsedRealtimeNanos, because
 * KitKat rejects fixes that look stale. NaN coordinates are skipped. Main thread only.
 */
class MockGps(context: Context) {
    private val lm = context.applicationContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var lastStartAttempt = 0L

    @Volatile
    var isActive = false
        private set

    /** Sets up the test provider. Returns [isActive]. */
    fun start(): Boolean {
        lastStartAttempt = SystemClock.elapsedRealtime()
        try {
            try {
                lm.removeTestProvider(LocationManager.GPS_PROVIDER)
            } catch (e: IllegalArgumentException) {
                // No test provider yet.
            }
            lm.addTestProvider(
                LocationManager.GPS_PROVIDER, false, false, false, false, true, true, true,
                Criteria.POWER_LOW, Criteria.ACCURACY_FINE
            )
            lm.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
            if (!isActive) BridgeLog.i("Mock GPS on: phone fixes go into the gps provider")
            isActive = true
            warnedOff = false
        } catch (e: SecurityException) {
            // Logged once per "off" period, not on every 10 s retry.
            if (!warnedOff) BridgeLog.w("Mock GPS off: run `adb shell settings put secure mock_location 1` once (${e.message})")
            warnedOff = true
            isActive = false
        } catch (e: RuntimeException) {
            BridgeLog.w("Mock GPS setup failed: $e")
            isActive = false
        }
        return isActive
    }

    private var warnedOff = false

    /** Retries [start] at most every [RETRY_MS] while mock locations are off. */
    fun retryIfInactive(): Boolean {
        if (!isActive && SystemClock.elapsedRealtime() - lastStartAttempt >= RETRY_MS) start()
        return isActive
    }

    fun inject(fix: LocationFix) {
        if (fix.lat.isNaN() || fix.lon.isNaN()) {
            BridgeLog.d("Skipping a NaN fix")
            return
        }
        if (!retryIfInactive()) return
        val loc = Location(LocationManager.GPS_PROVIDER)
        loc.latitude = fix.lat
        loc.longitude = fix.lon
        loc.accuracy = fix.accM.toFloat()
        fix.altM?.takeIf { !it.isNaN() }?.let { loc.altitude = it }
        fix.speedMps?.takeIf { !it.isNaN() }?.let { loc.speed = it.toFloat() }
        fix.bearing?.takeIf { !it.isNaN() }?.let { loc.bearing = it.toFloat() }
        loc.time = System.currentTimeMillis()
        loc.elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        try {
            lm.setTestProviderLocation(LocationManager.GPS_PROVIDER, loc)
            BridgeLog.v("Mock fix $fix")
        } catch (e: SecurityException) {
            BridgeLog.w("Mock GPS refused the fix (mock locations turned off?): ${e.message}")
            isActive = false
        } catch (e: IllegalArgumentException) {
            // No test provider any more (another app removed it) or an incomplete Location.
            BridgeLog.w("Mock fix rejected: ${e.message}")
            isActive = false
        }
    }

    fun stop() {
        if (!isActive) return
        try {
            lm.setTestProviderEnabled(LocationManager.GPS_PROVIDER, false)
            lm.removeTestProvider(LocationManager.GPS_PROVIDER)
        } catch (e: RuntimeException) {
            // Mock locations turned off in the meantime, or already removed.
        }
        isActive = false
    }

    companion object {
        const val RETRY_MS = 10_000L
    }
}

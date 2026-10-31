@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Endpoint
import au.interstellr.glassbridge.core.GlassConfig
import au.interstellr.glassbridge.core.NetUtil
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Finds the iPhone (PROTOCOL.md section 2), in order, on every reconnect:
 *
 * 1. `config.json` with a `host` (read fresh every time);
 * 2. the Wi-Fi DHCP gateway, if it's in the iOS Personal Hotspot range 172.20.10.0/28
 *    (`dhcpInfo.gateway` is a little-endian int, converted by [NetUtil]);
 * 3. Bonjour `_glassbridge._tcp` through NsdManager for up to [BONJOUR_TIMEOUT_MS], holding a
 *    Wi-Fi multicast lock while browsing. KitKat's NSD resolves one service at a time, so an
 *    AtomicBoolean lets only one resolve run.
 *
 * [resolve] blocks (up to 8 s for Bonjour); BridgeConnection calls it on its link thread.
 */
class Discovery(context: Context) {
    private val app = context.applicationContext
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    fun configFile(): File? = app.getExternalFilesDir(null)?.let { File(it, GlassConfig.FILE_NAME) }

    fun resolve(): Endpoint? {
        val file = configFile()
        val config = if (file != null) GlassConfig.load(file) else GlassConfig.DEFAULT
        config.endpoint()?.let {
            BridgeLog.i("Using config.json: $it")
            return it
        }

        val gateway = try {
            wifi.dhcpInfo?.gateway ?: 0
        } catch (e: RuntimeException) {
            BridgeLog.w("Couldn't read the DHCP gateway: $e")
            0
        }
        NetUtil.hotspotEndpoint(gateway)?.let {
            BridgeLog.i("Wi-Fi gateway is a Personal Hotspot: $it")
            return it
        }
        if (gateway != 0) BridgeLog.d("Gateway ${NetUtil.ipv4FromLittleEndian(gateway)} isn't a hotspot; trying Bonjour")

        return bonjour(BONJOUR_TIMEOUT_MS)
    }

    private fun bonjour(timeoutMs: Long): Endpoint? {
        val nsd = app.getSystemService(Context.NSD_SERVICE) as? NsdManager
        if (nsd == null) {
            BridgeLog.w("NsdManager isn't available")
            return null
        }
        val lock = try {
            wifi.createMulticastLock("GlassBridge-bonjour").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: RuntimeException) {
            BridgeLog.w("No multicast lock: $e")
            null
        }

        val found = AtomicReference<Endpoint?>(null)
        val done = CountDownLatch(1)
        val resolving = AtomicBoolean(false)
        val queue = ArrayDeque<NsdServiceInfo>() // guarded by itself
        val finished = AtomicBoolean(false)

        lateinit var resolveNext: () -> Unit

        val resolveListener = object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress
                if (host != null && info.port > 0) {
                    found.compareAndSet(null, Endpoint(host, info.port, Endpoint.VIA_BONJOUR))
                    BridgeLog.i("Bonjour resolved \"${info.serviceName}\" to $host:${info.port}")
                    done.countDown()
                } else {
                    resolving.set(false)
                    resolveNext()
                }
            }

            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                BridgeLog.w("Bonjour resolve of \"${info.serviceName}\" failed ($errorCode)")
                resolving.set(false)
                resolveNext()
            }
        }

        resolveNext = next@{
            if (finished.get() || found.get() != null) return@next
            if (!resolving.compareAndSet(false, true)) return@next
            val info = synchronized(queue) { queue.pollFirst() }
            if (info == null) {
                resolving.set(false)
                return@next
            }
            try {
                nsd.resolveService(info, resolveListener)
            } catch (e: RuntimeException) {
                BridgeLog.w("Bonjour resolveService failed: $e")
                resolving.set(false)
            }
        }

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                BridgeLog.d("Bonjour browsing $serviceType")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                val type = info.serviceType ?: ""
                if (!type.contains("_glassbridge._tcp")) return
                BridgeLog.i("Bonjour found \"${info.serviceName}\"")
                synchronized(queue) { queue.addLast(info) }
                resolveNext()
            }

            override fun onServiceLost(info: NsdServiceInfo) {}

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                BridgeLog.w("Bonjour browse failed to start ($errorCode)")
                done.countDown()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        var started = false
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            started = true
            done.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (e: RuntimeException) {
            BridgeLog.w("Bonjour browse failed: $e")
        } finally {
            finished.set(true)
            if (started) {
                try {
                    nsd.stopServiceDiscovery(discoveryListener)
                } catch (e: RuntimeException) {
                    // Already stopped, or never started.
                }
            }
            try {
                lock?.release()
            } catch (e: RuntimeException) {
            }
        }
        val ep = found.get()
        if (ep == null) BridgeLog.i("Bonjour found no iPhone in ${timeoutMs / 1000} s")
        return ep
    }

    companion object {
        const val SERVICE_TYPE = "_glassbridge._tcp"
        const val BONJOUR_TIMEOUT_MS = 8_000L
    }
}

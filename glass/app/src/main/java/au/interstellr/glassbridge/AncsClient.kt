// The value/write/getParcelableExtra calls were deprecated in API 33; they're the only ones
// KitKat (API 19) has.
@file:Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")

package au.interstellr.glassbridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import au.interstellr.glassbridge.core.Ancs
import au.interstellr.glassbridge.core.AncsEvent
import au.interstellr.glassbridge.core.AncsRequest
import au.interstellr.glassbridge.core.AncsResponse
import au.interstellr.glassbridge.core.AncsResponseReader
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Card
import java.util.LinkedList

/**
 * iPhone notifications through ANCS over Bluetooth LE (PROTOCOL.md section 10, a spike).
 *
 * While the TCP link is up, scans for the GlassBridge service the iPhone app advertises,
 * connects as the LE central, bonds, subscribes to ANCS, and turns each notification into a
 * local card through [Sink]. Once connected it stays connected whatever the TCP link does.
 *
 * Everything here runs on the main thread: GATT callbacks arrive on a binder thread and are
 * posted. One GATT operation is in flight at a time (KitKat drops overlapping ones).
 * Logs say what happened at each step but never notification text.
 *
 * MissingPermission is lint asking for BLUETOOTH_SCAN / BLUETOOTH_CONNECT, which are
 * Android 12 permissions; on API 19 BLUETOOTH and BLUETOOTH_ADMIN (in the manifest) cover it.
 */
@SuppressLint("MissingPermission")
class AncsClient(private val context: Context, private val sink: Sink) {

    interface Sink {
        fun onAncsCard(card: Card)
        fun onAncsRemoved(id: String)
    }

    private enum class Phase { IDLE, SCANNING, CONNECTING, DISCOVERING, BONDING, SUBSCRIBING, READY }

    companion object {
        const val SCAN_MS = 12_000L
        const val SCAN_GAP_MS = 30_000L
        const val RETRY_AFTER_LOSS_MS = 5_000L
        const val CONNECT_TIMEOUT_MS = 15_000L
        const val DISCOVER_DELAY_MS = 600L
        const val BOND_TIMEOUT_MS = 60_000L
        const val REQUEST_TIMEOUT_MS = 5_000L

        // ATT errors that mean "pair first".
        const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        const val GATT_INSUFFICIENT_ENCRYPTION = 15
    }

    private val main = Handler(Looper.getMainLooper())
    private val adapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var running = false
    private var phoneLinked = false
    private var phase = Phase.IDLE
    private var gatt: BluetoothGatt? = null
    private var device: BluetoothDevice? = null
    private var controlPoint: BluetoothGattCharacteristic? = null
    private val toSubscribe = LinkedList<BluetoothGattCharacteristic>()
    private var bondedForAncs = false

    private val requests = LinkedList<AncsRequest>()
    private var inFlight: AncsResponseReader? = null
    private val events = HashMap<Long, AncsEvent>()
    private val appNames = HashMap<String, String>()
    /** Notifications whose attributes arrived, waiting for their app's display name. */
    private val waitingForApp = HashMap<Long, Map<Int, String>>()

    private val scanTimeout = Runnable { onScanTimeout() }
    private val nextScan = Runnable { startScan() }
    private val connectTimeout = Runnable { lose("connect timed out") }
    private val bondTimeout = Runnable { lose("bonding timed out") }
    private val requestTimeout = Runnable {
        val r = inFlight ?: return@Runnable
        BridgeLog.w("ANCS: no answer to ${r.request}")
        finishRequest()
    }

    // ----- lifecycle (main thread) -------------------------------------------------------

    fun start() {
        if (running) return
        running = true
        if (adapter == null) {
            BridgeLog.w("ANCS: no Bluetooth adapter")
            return
        }
        val filter = IntentFilter()
        filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        filter.addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
        context.registerReceiver(receiver, filter)
        BridgeLog.i("ANCS: started (Bluetooth ${if (adapter.isEnabled) "on" else "off"})")
    }

    fun stop() {
        if (!running) return
        running = false
        try {
            context.unregisterReceiver(receiver)
        } catch (e: RuntimeException) {
        }
        main.removeCallbacks(nextScan)
        stopScan()
        closeGatt()
        phase = Phase.IDLE
    }

    /** From GlassState: scan only while the TCP link is up (the iPhone app is running). */
    fun setPhoneLinked(linked: Boolean) {
        if (linked == phoneLinked) return
        phoneLinked = linked
        if (!running || adapter == null) return
        if (linked && phase == Phase.IDLE) {
            main.removeCallbacks(nextScan)
            main.post(nextScan)
        } else if (!linked && phase == Phase.SCANNING) {
            stopScan()
            phase = Phase.IDLE
        }
    }

    // ----- scanning ----------------------------------------------------------------------

    @Suppress("DEPRECATION") // startLeScan is the only scan API on KitKat
    private val scanCallback = BluetoothAdapter.LeScanCallback { dev, rssi, record ->
        if (Ancs.advertises(record, Ancs.GLASSBRIDGE_SERVICE)) {
            main.post { onFound(dev, rssi) }
        }
    }

    private fun startScan() {
        val a = adapter ?: return
        if (!running || !phoneLinked || phase != Phase.IDLE) return
        if (!a.isEnabled) {
            BridgeLog.i("ANCS: Bluetooth is off; not scanning")
            return
        }
        phase = Phase.SCANNING
        @Suppress("DEPRECATION")
        val ok = a.startLeScan(scanCallback)
        if (!ok) {
            BridgeLog.w("ANCS: startLeScan refused")
            phase = Phase.IDLE
            scheduleScan(SCAN_GAP_MS)
            return
        }
        BridgeLog.d("ANCS: scanning for the iPhone")
        main.postDelayed(scanTimeout, SCAN_MS)
    }

    @Suppress("DEPRECATION")
    private fun stopScan() {
        main.removeCallbacks(scanTimeout)
        try {
            adapter?.stopLeScan(scanCallback)
        } catch (e: RuntimeException) {
        }
    }

    private fun onScanTimeout() {
        if (phase != Phase.SCANNING) return
        stopScan()
        phase = Phase.IDLE
        BridgeLog.d("ANCS: iPhone not advertising GlassBridge (is the app open?)")
        scheduleScan(SCAN_GAP_MS)
    }

    private fun scheduleScan(delayMs: Long) {
        main.removeCallbacks(nextScan)
        if (running && phoneLinked) main.postDelayed(nextScan, delayMs)
    }

    private fun onFound(dev: BluetoothDevice, rssi: Int) {
        if (phase != Phase.SCANNING) return
        stopScan()
        BridgeLog.i("ANCS: found the iPhone at ${dev.address} (rssi $rssi, ${bondName(dev.bondState)}); connecting")
        phase = Phase.CONNECTING
        device = dev
        // KitKat: connect from the main thread with autoConnect false.
        val g = dev.connectGatt(context, false, gattCallback)
        if (g == null) {
            lose("connectGatt returned null")
            return
        }
        gatt = g
        main.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)
    }

    // ----- GATT --------------------------------------------------------------------------

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post { onConnectionState(g, status, newState) }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post { onDiscovered(g, status) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            main.post { onSubscribed(g, d.characteristic, status) }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            main.post { onControlPointWritten(g, status) }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            // Copy now: the stack reuses the characteristic's value buffer.
            val value = c.value?.copyOf() ?: return
            val uuid = c.uuid
            main.post { onNotified(g, uuid, value) }
        }
    }

    private fun onConnectionState(g: BluetoothGatt, status: Int, newState: Int) {
        if (g != gatt) return
        if (newState == BluetoothProfile.STATE_CONNECTED) {
            main.removeCallbacks(connectTimeout)
            BridgeLog.i("ANCS: connected; discovering services")
            phase = Phase.DISCOVERING
            main.postDelayed({ if (gatt == g && !g.discoverServices()) lose("discoverServices refused") }, DISCOVER_DELAY_MS)
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            lose("disconnected (status $status)")
        }
    }

    private fun onDiscovered(g: BluetoothGatt, status: Int) {
        if (g != gatt || phase != Phase.DISCOVERING) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            lose("service discovery failed (status $status)")
            return
        }
        val uuids = g.services.joinToString { it.uuid.toString().substring(0, 8) }
        BridgeLog.i("ANCS: iPhone services: $uuids")
        val dev = device ?: return
        val ancs = g.getService(Ancs.SERVICE)
        if (ancs == null) {
            if (dev.bondState != BluetoothDevice.BOND_BONDED) {
                BridgeLog.i("ANCS: not offered before bonding; bonding first")
                bond(dev)
            } else {
                BridgeLog.w("ANCS: not offered by the iPhone even though bonded")
                lose("no ANCS service")
            }
            return
        }
        val ns = ancs.getCharacteristic(Ancs.NOTIFICATION_SOURCE)
        val cp = ancs.getCharacteristic(Ancs.CONTROL_POINT)
        val ds = ancs.getCharacteristic(Ancs.DATA_SOURCE)
        if (ns == null || cp == null || ds == null) {
            lose("ANCS characteristics missing (ns=${ns != null} cp=${cp != null} ds=${ds != null})")
            return
        }
        controlPoint = cp
        if (dev.bondState != BluetoothDevice.BOND_BONDED) {
            bond(dev)
            return
        }
        subscribe(g, ds, ns)
    }

    private fun bond(dev: BluetoothDevice) {
        phase = Phase.BONDING
        if (dev.bondState == BluetoothDevice.BOND_BONDING) {
            BridgeLog.i("ANCS: bonding already in progress")
        } else if (!dev.createBond()) {
            lose("createBond refused")
            return
        } else {
            BridgeLog.i("ANCS: bonding; accept the pairing request on the iPhone")
        }
        main.postDelayed(bondTimeout, BOND_TIMEOUT_MS)
    }

    private fun onBondState(dev: BluetoothDevice, state: Int, previous: Int) {
        // Logged for every device: after bonding the iPhone may appear under its identity
        // address rather than the one it advertised from.
        BridgeLog.i("ANCS: bond ${dev.address} ${bondName(previous)} -> ${bondName(state)}" + if (dev == device) "" else " (not the connecting device)")
        if (dev != device || phase != Phase.BONDING) return
        val g = gatt ?: return
        when (state) {
            BluetoothDevice.BOND_BONDED -> {
                main.removeCallbacks(bondTimeout)
                bondedForAncs = true
                // ANCS may only appear once the link is encrypted: discover again.
                phase = Phase.DISCOVERING
                main.postDelayed({ if (gatt == g && !g.discoverServices()) lose("discoverServices refused") }, DISCOVER_DELAY_MS)
            }
            BluetoothDevice.BOND_NONE -> {
                main.removeCallbacks(bondTimeout)
                lose("bonding failed or was declined")
            }
        }
    }

    private fun subscribe(g: BluetoothGatt, ds: BluetoothGattCharacteristic, ns: BluetoothGattCharacteristic) {
        phase = Phase.SUBSCRIBING
        toSubscribe.clear()
        // Data Source first, so attribute responses have somewhere to go.
        toSubscribe.add(ds)
        toSubscribe.add(ns)
        subscribeNext(g)
    }

    private fun subscribeNext(g: BluetoothGatt) {
        val c = toSubscribe.peek()
        if (c == null) {
            phase = Phase.READY
            BridgeLog.i("ANCS: ready; iPhone notifications will show on Glass")
            pump()
            return
        }
        val d = c.getDescriptor(Ancs.CCCD)
        if (d == null || !g.setCharacteristicNotification(c, true)) {
            lose("can't enable notifications on ${c.uuid}")
            return
        }
        d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (!g.writeDescriptor(d)) lose("writeDescriptor refused for ${c.uuid}")
    }

    private fun onSubscribed(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
        if (g != gatt || phase != Phase.SUBSCRIBING) return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            BridgeLog.d("ANCS: subscribed to ${c.uuid.toString().substring(0, 8)}")
            toSubscribe.poll()
            subscribeNext(g)
            return
        }
        val dev = device
        if ((status == GATT_INSUFFICIENT_AUTHENTICATION || status == GATT_INSUFFICIENT_ENCRYPTION) &&
            dev != null && !bondedForAncs
        ) {
            BridgeLog.i("ANCS: iPhone wants encryption (status $status); bonding")
            bond(dev)
            return
        }
        lose("subscribing to ${c.uuid} failed (status $status)")
    }

    // ----- notifications -----------------------------------------------------------------

    private fun onNotified(g: BluetoothGatt, uuid: java.util.UUID, value: ByteArray) {
        if (g != gatt) return
        when (uuid) {
            Ancs.NOTIFICATION_SOURCE -> onEvent(AncsEvent.parse(value))
            Ancs.DATA_SOURCE -> onData(value)
        }
    }

    private fun onEvent(e: AncsEvent?) {
        if (e == null) return
        BridgeLog.d("ANCS: $e")
        if (e.isRemoved) {
            events.remove(e.uid)
            waitingForApp.remove(e.uid)
            sink.onAncsRemoved(Ancs.cardId(e.uid))
            return
        }
        events[e.uid] = e
        requests.add(Ancs.notificationRequest(e.uid))
        pump()
    }

    private fun onData(chunk: ByteArray) {
        val reader = inFlight
        if (reader == null) {
            BridgeLog.d("ANCS: ${chunk.size} Data Source bytes with no request waiting")
            return
        }
        val response = reader.feed(chunk)
        val error = reader.error
        if (error != null) {
            BridgeLog.w("ANCS: bad response to ${reader.request}: $error")
            finishRequest()
        } else if (response != null) {
            finishRequest()
            onResponse(response)
        }
    }

    private fun onResponse(r: AncsResponse) {
        if (r.request.command == Ancs.CMD_GET_APP_ATTRIBUTES) {
            val appId = r.request.appId ?: return
            val name = r.attrs[Ancs.APP_ATTR_DISPLAY_NAME]?.takeIf { it.isNotBlank() } ?: appId
            appNames[appId] = name
            BridgeLog.d("ANCS: app $appId is \"$name\"")
            releaseWaiting(appId)
            return
        }
        val uid = r.request.uid
        val appId = r.attrs[Ancs.ATTR_APP_IDENTIFIER].orEmpty()
        BridgeLog.d(
            "ANCS: notification $uid from $appId " +
                "(title ${r.attrs[Ancs.ATTR_TITLE]?.length ?: 0}, message ${r.attrs[Ancs.ATTR_MESSAGE]?.length ?: 0} chars)"
        )
        if (appId.isEmpty() || appNames.containsKey(appId)) {
            show(uid, r.attrs)
            return
        }
        val alreadyAsked = waitingForApp.values.any { it[Ancs.ATTR_APP_IDENTIFIER] == appId } ||
            requests.any { it.appId == appId }
        waitingForApp[uid] = r.attrs
        if (!alreadyAsked) requests.add(Ancs.appNameRequest(appId))
    }

    private fun releaseWaiting(appId: String) {
        val ready = waitingForApp.filter { it.value[Ancs.ATTR_APP_IDENTIFIER] == appId }
        for ((uid, attrs) in ready) {
            waitingForApp.remove(uid)
            show(uid, attrs)
        }
    }

    private fun show(uid: Long, attrs: Map<Int, String>) {
        val e = events[uid] ?: return // removed meanwhile
        val appId = attrs[Ancs.ATTR_APP_IDENTIFIER]
        sink.onAncsCard(Ancs.card(e, attrs, appId?.let { appNames[it] }, System.currentTimeMillis()))
    }

    // ----- Control Point requests, one at a time -----------------------------------------

    private fun pump() {
        if (phase != Phase.READY || inFlight != null) return
        val g = gatt ?: return
        val cp = controlPoint ?: return
        val req = requests.poll() ?: return
        if (req.command == Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES && !events.containsKey(req.uid)) {
            main.post { pump() } // removed before we asked
            return
        }
        if (req.command == Ancs.CMD_GET_APP_ATTRIBUTES && appNames.containsKey(req.appId)) {
            releaseWaiting(req.appId.orEmpty())
            main.post { pump() }
            return
        }
        inFlight = AncsResponseReader(req)
        cp.value = req.bytes()
        cp.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        if (!g.writeCharacteristic(cp)) {
            BridgeLog.w("ANCS: writeCharacteristic refused for $req")
            inFlight = null
            main.postDelayed({ pump() }, 200)
            return
        }
        main.postDelayed(requestTimeout, REQUEST_TIMEOUT_MS)
    }

    private fun onControlPointWritten(g: BluetoothGatt, status: Int) {
        if (g != gatt) return
        val reader = inFlight ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            // 0xA0..0xA3: unknown command, invalid command, invalid parameter, action failed
            // (for example the notification went away first).
            BridgeLog.w("ANCS: ${reader.request} failed (status 0x${Integer.toHexString(status)})")
            val appId = reader.request.appId
            finishRequest()
            if (appId != null) {
                appNames[appId] = appId
                releaseWaiting(appId)
            }
        }
    }

    private fun finishRequest() {
        main.removeCallbacks(requestTimeout)
        inFlight = null
        main.post { pump() }
    }

    // ----- loss and cleanup --------------------------------------------------------------

    private fun lose(reason: String) {
        BridgeLog.i("ANCS: $reason")
        closeGatt()
        phase = Phase.IDLE
        scheduleScan(RETRY_AFTER_LOSS_MS)
    }

    private fun closeGatt() {
        main.removeCallbacks(connectTimeout)
        main.removeCallbacks(bondTimeout)
        main.removeCallbacks(requestTimeout)
        val g = gatt
        gatt = null
        device = null
        controlPoint = null
        toSubscribe.clear()
        requests.clear()
        inFlight = null
        events.clear()
        waitingForApp.clear()
        bondedForAncs = false
        if (g != null) {
            try {
                g.disconnect()
                g.close()
            } catch (e: RuntimeException) {
            }
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val dev = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
                    onBondState(
                        dev,
                        intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR),
                        intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
                    )
                }
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                        BluetoothAdapter.STATE_ON -> {
                            BridgeLog.i("ANCS: Bluetooth on")
                            if (phase == Phase.IDLE) scheduleScan(0)
                        }
                        BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                            if (phase != Phase.IDLE) {
                                stopScan()
                                lose("Bluetooth turned off")
                                main.removeCallbacks(nextScan)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun bondName(state: Int): String = when (state) {
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_NONE -> "not bonded"
        else -> "bond $state"
    }
}

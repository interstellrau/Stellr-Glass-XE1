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
 * iPhone notifications through ANCS over Bluetooth LE (PROTOCOL.md section 10).
 *
 * While the TCP link is up, scans for the StellrGlass service the iPhone app advertises,
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
        /** Show (and speak) the passkey the iPhone asks for; removed with onAncsRemoved. */
        fun onAncsPasskey(passkey: Int)
        /** True once subscribed to ANCS, false when that ends. */
        fun onAncsListening(listening: Boolean)
    }

    private enum class Phase { IDLE, SCANNING, CONNECTING, DISCOVERING, BONDING, SUBSCRIBING, READY }

    companion object {
        const val SCAN_MS = 12_000L
        const val SCAN_GAP_MS = 30_000L
        const val RETRY_AFTER_LOSS_MS = 5_000L
        const val RETRY_AFTER_BOND_FAILURE_MS = 60_000L
        const val RECONNECT_AFTER_BOND_MS = 1_000L
        /** How long to wait for the iPhone's security request before starting pairing. */
        const val BOND_KICK_MS = 3_000L
        /** Above default receivers, so XE24's pairing screen doesn't cover the passkey card. */
        const val PAIRING_RECEIVER_PRIORITY = 999
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
    /** The device whose passkey card is showing, if any. */
    private var passkeyDevice: BluetoothDevice? = null
    /**
     * The iPhone most recently connected to. Kept after a loss: iOS can drop the LE link while
     * pairing carries on, and that pairing still needs its passkey shown.
     */
    private var lastDevice: BluetoothDevice? = null
    /** A refused bond is being removed; pairing starts when it's gone. */
    private var replacingBond = false
    private var listening = false
    /** Pre-existing events ignored since the last one shown (logged as one line). */
    private var preExistingSkipped = 0

    private val requests = LinkedList<AncsRequest>()
    private var inFlight: AncsResponseReader? = null
    private val events = HashMap<Long, AncsEvent>()
    private val appNames = HashMap<String, String>()
    /** Notifications whose attributes arrived, waiting for their app's display name. */
    private val waitingForApp = HashMap<Long, Map<Int, String>>()

    private val scanTimeout = Runnable { onScanTimeout() }
    private val nextScan = Runnable { startScan() }
    private val connectTimeout = Runnable { lose("connect timed out") }
    private val bondTimeout = Runnable { lose("bonding timed out", RETRY_AFTER_BOND_FAILURE_MS) }
    private val bondKick = Runnable {
        val d = device
        if (d != null && phase == Phase.BONDING) kickBond(d)
    }
    private val logSkipped = Runnable {
        BridgeLog.i("ANCS: skipped $preExistingSkipped notifications already on the iPhone")
        preExistingSkipped = 0
    }
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
        val pairing = IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST)
        pairing.priority = PAIRING_RECEIVER_PRIORITY
        context.registerReceiver(pairingReceiver, pairing)
        BridgeLog.i("ANCS: started (Bluetooth ${if (adapter.isEnabled) "on" else "off"})")
    }

    fun stop() {
        if (!running) return
        running = false
        for (r in listOf(receiver, pairingReceiver)) {
            try {
                context.unregisterReceiver(r)
            } catch (e: RuntimeException) {
            }
        }
        clearPasskey()
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
        BridgeLog.d("ANCS: iPhone not advertising StellrGlass (is the app open?)")
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
        lastDevice = dev
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
        // Subscribe whether or not Android lists this address as bonded (PROTOCOL.md section
        // 10 step 3); an unencrypted link makes the write fail, and pairAgain takes over.
        subscribeToAncs(g)
    }

    /**
     * Subscribes with the ANCS service from the last discovery. False if ANCS wasn't found;
     * true otherwise (including when its characteristics are missing, which loses the link).
     */
    private fun subscribeToAncs(g: BluetoothGatt): Boolean {
        val ancs = g.getService(Ancs.SERVICE) ?: return false
        val ns = ancs.getCharacteristic(Ancs.NOTIFICATION_SOURCE)
        val cp = ancs.getCharacteristic(Ancs.CONTROL_POINT)
        val ds = ancs.getCharacteristic(Ancs.DATA_SOURCE)
        if (ns == null || cp == null || ds == null) {
            lose("ANCS characteristics missing (ns=${ns != null} cp=${cp != null} ds=${ds != null})")
            return true
        }
        controlPoint = cp
        subscribe(g, ds, ns)
        return true
    }

    /** Bonds before subscribing: only when ANCS isn't offered until the link is encrypted. */
    private fun bond(dev: BluetoothDevice) {
        phase = Phase.BONDING
        main.postDelayed(bondTimeout, BOND_TIMEOUT_MS)
        startBond(dev)
    }

    private fun startBond(dev: BluetoothDevice) {
        when {
            dev.bondState == BluetoothDevice.BOND_BONDING -> BridgeLog.i("ANCS: pairing already in progress")
            !dev.createBond() -> lose("createBond refused", RETRY_AFTER_BOND_FAILURE_MS)
            else -> BridgeLog.i("ANCS: pairing; enter the code from Glass on the iPhone")
        }
    }

    /**
     * The iPhone wants an encrypted link (PROTOCOL.md section 10 step 3). Seen on XE24 on 21
     * November 2026: the iPhone's address rotates, KitKat can't resolve it, and even at the same
     * address the iPhone usually refused the stored key, so pairing again is the normal path.
     */
    private fun pairAgain(dev: BluetoothDevice) {
        phase = Phase.BONDING
        main.postDelayed(bondTimeout, BOND_TIMEOUT_MS)
        if (dev.bondState == BluetoothDevice.BOND_BONDING) {
            BridgeLog.i("ANCS: pairing already in progress")
            return
        }
        // The iPhone's security request usually makes the stack pair by itself within a
        // moment, even over a bond Android still lists; starting pairing here as well collides
        // with it. Only if nothing has started does bondKick step in.
        BridgeLog.i("ANCS: waiting for the iPhone to start pairing")
        main.postDelayed(bondKick, BOND_KICK_MS)
    }

    /** Nothing started pairing after the iPhone asked for encryption: start it from Glass. */
    private fun kickBond(d: BluetoothDevice) {
        when (d.bondState) {
            BluetoothDevice.BOND_NONE -> startBond(d)
            BluetoothDevice.BOND_BONDED -> {
                // Neither side pairs over a bond Android still lists: remove it, and pairing
                // starts when it's gone (onBondState).
                BridgeLog.i("ANCS: the iPhone refused the stored key; removing it to pair again")
                replacingBond = true
                if (!removeBond(d)) {
                    replacingBond = false
                    lose("couldn't remove the refused bond", RETRY_AFTER_BOND_FAILURE_MS)
                }
            }
        }
    }

    private fun onBondState(dev: BluetoothDevice, state: Int, previous: Int) {
        // Logged for every device: after bonding the iPhone may appear under its identity
        // address rather than the one it advertised from.
        BridgeLog.i("ANCS: bond ${dev.address} ${bondName(previous)} -> ${bondName(state)}" + if (dev == device) "" else " (not the connecting device)")
        // The passkey card goes when bonding ends, even if the LE link dropped meanwhile (iOS
        // can disconnect a moment before the bond completes).
        if (dev == passkeyDevice && state != BluetoothDevice.BOND_BONDING) clearPasskey()
        if (state == BluetoothDevice.BOND_BONDED && dev == lastDevice) {
            forgetOtherIphoneBonds(dev)
            // Bonded after the LE link was lost: reconnect now, not after the retry gap.
            if (phase == Phase.IDLE) scheduleScan(RECONNECT_AFTER_BOND_MS)
        }
        if (dev != device) return
        val g = gatt ?: return
        when (state) {
            BluetoothDevice.BOND_BONDED -> {
                if (phase != Phase.BONDING) return
                main.removeCallbacks(bondTimeout)
                main.removeCallbacks(bondKick)
                bondedForAncs = true
                // Subscribe again on this connection. If ANCS wasn't offered before bonding,
                // discover again: it can appear only once the link is encrypted.
                if (!subscribeToAncs(g)) {
                    phase = Phase.DISCOVERING
                    main.postDelayed({ if (gatt == g && !g.discoverServices()) lose("discoverServices refused") }, DISCOVER_DELAY_MS)
                }
            }
            BluetoothDevice.BOND_NONE -> {
                if (replacingBond) {
                    replacingBond = false
                    startBond(dev)
                    return
                }
                if (phase != Phase.BONDING && phase != Phase.SUBSCRIBING) return
                main.removeCallbacks(bondTimeout)
                lose("bonding failed or was declined", RETRY_AFTER_BOND_FAILURE_MS)
            }
        }
    }

    /**
     * Removes Glass's LE bonds left from the iPhone's earlier addresses: every reconnect can
     * bond a new address, and they'd pile up otherwise.
     */
    private fun forgetOtherIphoneBonds(current: BluetoothDevice) {
        val bonded = adapter?.bondedDevices ?: return
        for (d in bonded) {
            if (d == current || d.type != BluetoothDevice.DEVICE_TYPE_LE || d.name != Ancs.IPHONE_ADVERT_NAME) continue
            BridgeLog.i("ANCS: removing the old bond with ${d.address}")
            removeBond(d)
        }
    }

    /** BluetoothDevice.removeBond is hidden on API 19 (it's what Settings › Forget uses). */
    private fun removeBond(d: BluetoothDevice): Boolean = try {
        d.javaClass.getMethod("removeBond").invoke(d) as Boolean
    } catch (e: Exception) {
        BridgeLog.w("ANCS: removeBond failed for ${d.address}: $e")
        false
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
            setListening(true)
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
            BridgeLog.i("ANCS: iPhone wants encryption (status $status)")
            pairAgain(dev)
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
        if (!Ancs.shouldShow(e)) {
            if (preExistingSkipped++ == 0) main.postDelayed(logSkipped, 2_000L)
            return
        }
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

    private fun lose(reason: String, retryMs: Long = RETRY_AFTER_LOSS_MS) {
        BridgeLog.i("ANCS: $reason")
        closeGatt()
        phase = Phase.IDLE
        scheduleScan(retryMs)
    }

    private fun setListening(value: Boolean) {
        if (value == listening) return
        listening = value
        sink.onAncsListening(value)
    }

    private fun clearPasskey() {
        if (passkeyDevice == null) return
        passkeyDevice = null
        sink.onAncsRemoved(Ancs.PAIRING_CARD_ID)
    }

    private fun closeGatt() {
        main.removeCallbacks(connectTimeout)
        main.removeCallbacks(bondTimeout)
        main.removeCallbacks(bondKick)
        main.removeCallbacks(requestTimeout)
        replacingBond = false
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
        setListening(false)
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

    /**
     * Passkey entry (PROTOCOL.md section 10 step 3). Glass is KeyboardDisplay, so it makes the
     * passkey and the iPhone asks for it, but XE24's own pairing screen can't show one. Only
     * the iPhone this client is (or was last) connected to is handled; anything else goes on to
     * the system.
     * Pairing requests are ordered broadcasts, so aborting keeps XE24's "unsupported" screen
     * from covering the card.
     */
    private val pairingReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val dev = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            val variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, BluetoothDevice.ERROR)
            val ours = dev == device || dev == lastDevice
            BridgeLog.i("ANCS: pairing request from ${dev.address}, variant $variant" + if (ours) "" else " (not the iPhone)")
            if (!ours || variant != Ancs.PAIRING_VARIANT_DISPLAY_PASSKEY) return
            val passkey = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_KEY, BluetoothDevice.ERROR)
            if (passkey < 0) return
            passkeyDevice = dev
            sink.onAncsPasskey(passkey)
            if (isOrderedBroadcast) abortBroadcast()
        }
    }

    private fun bondName(state: Int): String = when (state) {
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_NONE -> "not bonded"
        else -> "bond $state"
    }
}

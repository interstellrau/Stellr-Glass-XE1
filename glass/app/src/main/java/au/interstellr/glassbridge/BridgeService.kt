@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import au.interstellr.glassbridge.core.BridgeConnection
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Card
import au.interstellr.glassbridge.core.Endpoint
import au.interstellr.glassbridge.core.Frame
import au.interstellr.glassbridge.core.GlassHandler
import au.interstellr.glassbridge.core.LocationFix
import au.interstellr.glassbridge.core.MessageRouter
import au.interstellr.glassbridge.core.Msg
import au.interstellr.glassbridge.core.NavSpeech
import au.interstellr.glassbridge.core.NavState
import au.interstellr.glassbridge.core.Pairing
import au.interstellr.glassbridge.core.Rejected
import au.interstellr.glassbridge.core.ScreencastCmd
import au.interstellr.glassbridge.core.Uploader
import au.interstellr.glassbridge.core.Welcome
import au.interstellr.glassbridge.core.WifiNetwork
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The foreground service that owns the iPhone link and everything that runs with the screen
 * off (brief "Components › BridgeService").
 *
 * - START_STICKY with an ongoing notification (Notification.Builder.build()).
 * - [BridgeConnection] with [Discovery] as resolve() and a `hello` carrying the pairing token
 *   from SharedPreferences `link` / `token` (PROTOCOL.md section 6).
 * - Dispatches every message type through [MessageRouter] (this class is the [GlassHandler]).
 * - `status` after `welcome`, every 60 s, on a battery % change and on `request_status`.
 * - TTS with QUEUE_ADD (dropped until TTS is ready), a ToneGenerator TONE_PROP_ACK chime for
 *   150 ms, and a 6 s SCREEN_BRIGHT_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP that also brings the card
 *   screen to the front if it isn't there (wake cards and new nav steps).
 * - `onStartCommand` re-applies `wifi.json`.
 *
 * Link callbacks and [GlassHandler] methods run on the "GlassBridge-link" thread and hop to the
 * main thread (GlassState, UI, TTS, mock GPS) or to the worker thread (Wi-Fi).
 */
class BridgeService : Service(), BridgeConnection.Listener, GlassHandler, GlassState.Listener {

    companion object {
        const val NOTIFICATION_ID = 1
        const val STATUS_INTERVAL_MS = 60_000L
        const val WAKE_MS = 6_000L
        const val CHIME_MS = 150

        /** The running service, for the card screen's acks. Set on the main thread. */
        @Volatile
        @JvmStatic
        var current: BridgeService? = null
            private set

        @JvmStatic
        fun start(context: Context) {
            try {
                context.startService(Intent(context, BridgeService::class.java))
            } catch (e: RuntimeException) {
                BridgeLog.e("Couldn't start BridgeService", e)
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "GlassBridge-worker").apply { isDaemon = true }
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var discovery: Discovery
    private lateinit var deviceStatus: DeviceStatus
    private lateinit var wifi: WifiProvisioner
    private lateinit var mockGps: MockGps
    private lateinit var mediaSync: MediaSync
    private lateinit var uploader: Uploader
    lateinit var connection: BridgeConnection
        private set

    private var tts: TextToSpeech? = null
    @Volatile private var ttsReady = false
    private var tone: ToneGenerator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastBattery = -1
    private var lastNotificationText: String? = null
    private var receiversRegistered = false

    private val statusTick = object : Runnable {
        override fun run() {
            sendStatus("every 60 s")
            mediaSync.rescan()
            main.postDelayed(this, STATUS_INTERVAL_MS)
        }
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val pct = DeviceStatus.batteryPercent(intent)
            if (pct < 0) return
            val changed = lastBattery >= 0 && pct != lastBattery
            lastBattery = pct
            if (changed) sendStatus("battery $pct%")
        }
    }

    private val connectivityReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            val info = cm.activeNetworkInfo
            if (info != null && info.isConnected && info.type == ConnectivityManager.TYPE_WIFI && !connection.isConnected) {
                BridgeLog.i("Wi-Fi connected; looking for the iPhone now")
                connection.retryNow()
            }
        }
    }

    // ----- lifecycle --------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        Logs.install()
        BridgeLog.i("BridgeService starting (GlassBridge ${BuildConfig.VERSION_NAME}, ${Build.MODEL}, ${Build.DISPLAY})")
        current = this

        prefs = getSharedPreferences(Pairing.PREFS, Context.MODE_PRIVATE)
        discovery = Discovery(this)
        deviceStatus = DeviceStatus(this)
        wifi = WifiProvisioner(this)
        mockGps = MockGps(this)

        startForeground(NOTIFICATION_ID, buildNotification(GlassState.link.notificationText))
        lastNotificationText = GlassState.link.notificationText
        GlassState.addListener(this)

        connection = BridgeConnection(
            resolve = {
                val ep = discovery.resolve()
                main.post { GlassState.onSearching(ep) }
                ep
            },
            hello = { Msg.hello(Build.MODEL ?: "Glass", firmware(), BuildConfig.VERSION_NAME, prefs.getString(Pairing.KEY_TOKEN, null)) },
            listener = this
        )
        uploader = Uploader(connection)
        mediaSync = MediaSync(this, uploader)
        Screencast.sender = connection

        mockGps.start()
        mediaSync.start()
        initAudio()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "GlassBridge:wake").apply {
                setReferenceCounted(false)
            }
        } catch (e: RuntimeException) {
            BridgeLog.w("No wake lock: $e")
        }

        lastBattery = DeviceStatus.batteryPercent(deviceStatus.batteryIntent())
        try {
            registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            @Suppress("DEPRECATION")
            registerReceiver(connectivityReceiver, IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION))
            receiversRegistered = true
        } catch (e: RuntimeException) {
            BridgeLog.w("Receivers not registered: $e")
        }

        main.postDelayed(statusTick, STATUS_INTERVAL_MS)
        connection.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        BridgeLog.d("onStartCommand" + if (intent == null) " (restarted)" else "")
        runOnWorker { wifi.applyWifiJson() }
        // `glass_adb.py mock` then `start`: pick up the new mock_location setting straight away.
        if (!mockGps.isActive && mockGps.start()) sendStatus("mock GPS now on")
        if (!connection.isConnected) connection.retryNow()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        BridgeLog.i("BridgeService stopping")
        current = null
        main.removeCallbacks(statusTick)
        GlassState.removeListener(this)
        if (receiversRegistered) {
            try {
                unregisterReceiver(batteryReceiver)
                unregisterReceiver(connectivityReceiver)
            } catch (e: RuntimeException) {
            }
        }
        connection.stop()
        mediaSync.stop()
        mockGps.stop()
        Screencast.configure(false, ScreencastCmd.DEFAULT_FPS)
        Screencast.sender = null
        tts?.shutdown()
        tts = null
        ttsReady = false
        tone?.release()
        tone = null
        worker.shutdownNow()
        stopForeground(true)
        super.onDestroy()
    }

    // ----- BridgeConnection.Listener (link thread) ---------------------------------------

    override fun onConnecting() {
        // GlassState is updated when resolve() returns (see onCreate).
    }

    override fun onConnected(endpoint: Endpoint) {
        main.post { GlassState.onConnected(endpoint) }
    }

    override fun onFrame(frame: Frame) {
        MessageRouter.route(frame, this)
    }

    override fun onDisconnected(reason: String) {
        uploader.cancelAll()
        mediaSync.setEnabled(false)
        main.post {
            Screencast.configure(false, ScreencastCmd.DEFAULT_FPS)
            GlassState.onDisconnected(reason)
        }
    }

    // ----- GlassHandler (link thread; must not block) ------------------------------------

    @SuppressLint("ApplySharedPref")
    override fun onWelcome(welcome: Welcome) {
        if (welcome.isNewPairing) {
            // commit(), on the link thread, on purpose: the new token must be on disk before
            // anything else happens, or a crash now would leave Glass needing to pair again.
            prefs.edit().putString(Pairing.KEY_TOKEN, welcome.pairToken).commit()
            BridgeLog.i("Paired with ${welcome.phoneName}, code ${welcome.pairCode}; token saved")
        } else {
            BridgeLog.i("Welcome from ${welcome.phoneName} (${welcome.server ?: "?"}): token accepted")
        }
        main.post {
            GlassState.onWelcome(welcome.phoneName)
            if (welcome.isNewPairing) {
                val card = Pairing.pairedCard(welcome)
                GlassState.putCard(card)
                alert(card.chime, card.wake)
            }
            sendStatus("after welcome")
        }
    }

    override fun onRejected(rejected: Rejected) {
        BridgeLog.w("Rejected by the iPhone: ${rejected.reason}" + (rejected.message?.let { " ($it)" } ?: "") +
            ". " + Pairing.REJECTED_HINT)
        main.post { GlassState.onRejected(rejected.reason) }
    }

    override fun onPong() {
        BridgeLog.v("pong")
    }

    override fun onRequestStatus() {
        main.post { sendStatus("requested") }
    }

    override fun onCard(card: Card) {
        main.post {
            GlassState.putCard(card)
            alert(card.chime, card.wake)
        }
    }

    override fun onDismiss(id: String) {
        main.post { GlassState.dismiss(id) }
    }

    override fun onSpeak(text: String) {
        main.post { speak(text) }
    }

    override fun onNav(nav: NavState) {
        main.post {
            val newStep = GlassState.setNav(nav)
            if (newStep) alert(chime = true, wake = true)
            if (nav.announce) speak(NavSpeech.text(nav))
        }
    }

    override fun onNavEnd() {
        main.post { GlassState.endNav() }
    }

    override fun onLocation(fix: LocationFix) {
        main.post { mockGps.inject(fix) }
    }

    override fun onSync(enabled: Boolean) {
        mediaSync.setEnabled(enabled)
    }

    override fun onFileAck(frame: Frame) {
        if (!uploader.handleFrame(frame)) BridgeLog.d("file_ack for no upload in progress: ${frame.str("id")}")
    }

    override fun onScreencast(cmd: ScreencastCmd) {
        main.post { Screencast.configure(cmd.on, cmd.fps) }
    }

    override fun onWifiAdd(network: WifiNetwork?, ssid: String) {
        runOnWorker {
            val error = if (network == null) "missing ssid" else wifi.save(network)
            val ok = error == null
            BridgeLog.i("wifi_add \"$ssid\": " + if (ok) "saved" else "failed ($error)")
            connection.send(Msg.wifiResult(ssid, ok, error))
        }
    }

    override fun onIgnored(frame: Frame, why: String) {
        BridgeLog.d("Ignored ${frame.type}: $why")
    }

    // ----- GlassState.Listener (main thread) ---------------------------------------------

    override fun onGlassStateChanged() {
        val text = GlassState.link.notificationText
        if (text != lastNotificationText) {
            lastNotificationText = text
            try {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, buildNotification(text))
            } catch (e: RuntimeException) {
                BridgeLog.w("Notification update failed: $e")
            }
        }
    }

    // ----- actions used by the card screen (main thread) ---------------------------------

    /** Sends `ack` for a card (shown, dismissed, tapped). */
    fun sendAck(id: String, event: String) {
        if (!connection.isConnected) {
            BridgeLog.d("ack $id $event not sent: not connected")
            return
        }
        connection.sendAsync(Msg.ack(id, event)) { ok ->
            BridgeLog.d("ack $id $event " + if (ok) "sent" else "not sent")
        }
    }

    // ----- internals --------------------------------------------------------------------

    /** Builds and sends `status` (main thread). Only once the iPhone has accepted this Glass. */
    private fun sendStatus(why: String) {
        if (!connection.isAccepted) return
        mockGps.retryIfInactive()
        val status = try {
            deviceStatus.build(mockGps.isActive)
        } catch (t: Throwable) {
            BridgeLog.e("Building status failed", t)
            return
        }
        BridgeLog.d("status ($why): $status")
        connection.sendAsync(status)
    }

    private fun alert(chime: Boolean, wake: Boolean) {
        if (chime) chime()
        if (wake) wake()
    }

    private fun chime() {
        try {
            tone?.startTone(ToneGenerator.TONE_PROP_ACK, CHIME_MS)
        } catch (e: RuntimeException) {
            BridgeLog.w("Chime failed: $e")
        }
    }

    /** Turns the display on for 6 s and brings the card screen to the front if it isn't there. */
    private fun wake() {
        try {
            wakeLock?.acquire(WAKE_MS)
        } catch (e: RuntimeException) {
            BridgeLog.w("Wake lock failed: $e")
        }
        if (!MainActivity.visible) {
            try {
                startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e: RuntimeException) {
                BridgeLog.w("Couldn't open the card screen: $e")
            }
        }
    }

    private fun speak(text: String) {
        if (text.isBlank()) return
        val t = tts
        if (t == null || !ttsReady) {
            BridgeLog.i("Speech dropped (TTS not ready): $text")
            return
        }
        @Suppress("DEPRECATION")
        val r = t.speak(text, TextToSpeech.QUEUE_ADD, null)
        if (r != TextToSpeech.SUCCESS) BridgeLog.w("TTS refused: $text")
        else BridgeLog.d("Speaking: $text")
    }

    private fun initAudio() {
        try {
            tone = ToneGenerator(AudioManager.STREAM_MUSIC, ToneGenerator.MAX_VOLUME)
        } catch (e: RuntimeException) {
            BridgeLog.w("No ToneGenerator: $e")
        }
        try {
            tts = TextToSpeech(applicationContext) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (ttsReady) BridgeLog.i("TTS ready") else BridgeLog.w("TTS failed to start ($status)")
            }
        } catch (e: RuntimeException) {
            BridgeLog.w("No TextToSpeech: $e")
        }
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), 0)
        @Suppress("DEPRECATION")
        return Notification.Builder(this)
            .setSmallIcon(R.drawable.ic_stat_glassbridge)
            .setContentTitle("GlassBridge")
            .setContentText(text)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun firmware(): String {
        val d = Build.DISPLAY
        return if (d.isNullOrBlank()) "XE24" else d
    }

    private fun runOnWorker(block: () -> Unit) {
        try {
            worker.execute {
                try {
                    block()
                } catch (t: Throwable) {
                    BridgeLog.e("Worker task failed", t)
                }
            }
        } catch (e: RejectedExecutionException) {
            BridgeLog.w("Worker stopped; task dropped")
        }
    }
}

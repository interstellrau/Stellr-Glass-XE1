@file:Suppress("DEPRECATION") // Deprecated after API 19, but the right API on Glass (API 19 only).

package au.interstellr.glassbridge

import android.annotation.SuppressLint
import android.app.AlarmManager
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
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import au.interstellr.glassbridge.core.BridgeConnection
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.Card
import au.interstellr.glassbridge.core.Endpoint
import au.interstellr.glassbridge.core.Frame
import au.interstellr.glassbridge.core.GlassHandler
import au.interstellr.glassbridge.core.LocationFix
import au.interstellr.glassbridge.core.MediaRules
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
 * - The 60 s tick (status, media re-scan, and a redial if the link is down) comes from an
 *   exact ELAPSED_REALTIME_WAKEUP alarm, because Handler delays, Thread.sleep and the
 *   reconnect backoff all stop while an unplugged Glass is in deep sleep. Each tick holds a
 *   short PARTIAL_WAKE_LOCK so the status write (or the redial) finishes before Glass sleeps
 *   again.
 * - The link's silence is measured on elapsedRealtime (it counts deep sleep), and each tick
 *   runs the silence check itself, so a link that died while Glass slept is closed, and
 *   redialled, at the first tick after 30 s of silence instead of minutes later.
 * - A new pairing (`welcome` with `pair_token`) makes MediaSync forget its synced ids, so the
 *   newly paired phone gets the whole DCIM/Camera backlog.
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

        /** Private broadcast the 60 s alarm sends (setPackage keeps it inside this app). */
        const val ACTION_TICK = "au.interstellr.glassbridge.TICK"

        /** How long a tick keeps the CPU awake while linked: enough to write `status`. */
        const val TICK_WAKE_LINKED_MS = 3_000L

        /**
         * ... and while not linked: discovery (Bonjour up to 8 s), a 5 s connect, hello/welcome.
         * Released early if the attempt fails (onRetryWait).
         */
        const val TICK_WAKE_REDIAL_MS = 20_000L

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
    private lateinit var ancs: AncsClient
    lateinit var connection: BridgeConnection
        private set

    private var tts: TextToSpeech? = null
    @Volatile private var ttsReady = false
    private var tone: ToneGenerator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var tickWakeLock: PowerManager.WakeLock? = null
    private var alarms: AlarmManager? = null
    private var tickIntent: PendingIntent? = null
    private var lastBattery = -1
    private var lastNotificationText: String? = null
    private var receiversRegistered = false

    /** Link thread only: the current (or just ended) link got `welcome`. */
    private var sessionAccepted = false

    /** Fallback for the tick if the alarm can't be set (it doesn't fire during deep sleep). */
    private val statusTick = Runnable { onTick() }

    private val tickReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            onTick()
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

    // UnspecifiedRegisterReceiverFlag: the RECEIVER_(NOT_)EXPORTED flags start at API 26/33;
    // Glass is API 19 only. The tick receiver only triggers status, a re-scan and a redial.
    @SuppressLint("UnspecifiedRegisterReceiverFlag")
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

        // Before the link starts: silence is then measured on a clock that keeps counting while
        // Glass is in deep sleep (System.nanoTime, the default, stops).
        BridgeConnection.clockMs = { SystemClock.elapsedRealtime() }
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
        ancs = AncsClient(this, object : AncsClient.Sink {
            override fun onAncsCard(card: Card) {
                GlassState.putCard(card)
                alert(card.chime, card.wake)
            }

            override fun onAncsRemoved(id: String) {
                GlassState.dismiss(id)
            }
        })
        ancs.start()
        initAudio()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "GlassBridge:wake").apply {
                setReferenceCounted(false)
            }
            tickWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GlassBridge:tick").apply {
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
            registerReceiver(tickReceiver, IntentFilter(ACTION_TICK))
            receiversRegistered = true
        } catch (e: RuntimeException) {
            BridgeLog.w("Receivers not registered: $e")
        }
        if (receiversRegistered) {
            try {
                alarms = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                tickIntent = PendingIntent.getBroadcast(this, 0, Intent(ACTION_TICK).setPackage(packageName), 0)
            } catch (e: RuntimeException) {
                BridgeLog.w("No alarm for the 60 s tick (it will pause while Glass sleeps): $e")
                alarms = null
                tickIntent = null
            }
        }

        scheduleTick()
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
        try {
            tickIntent?.let { alarms?.cancel(it) }
        } catch (e: RuntimeException) {
        }
        GlassState.removeListener(this)
        if (receiversRegistered) {
            try {
                unregisterReceiver(batteryReceiver)
                unregisterReceiver(connectivityReceiver)
                unregisterReceiver(tickReceiver)
            } catch (e: RuntimeException) {
            }
        }
        releaseTickWakeLock()
        connection.stop()
        ancs.stop()
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
        sessionAccepted = false
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

    override fun onRetryWait(ms: Long) {
        // After an accepted link drops, keep the tick's wake lock (it times out by itself): the
        // tick that found the link dead is redialling now (retryNow skips this wait), and
        // releasing would freeze that redial until the next tick.
        if (sessionAccepted) return
        // The redial a tick started is over (it failed); the CPU may sleep until the next tick.
        main.post { releaseTickWakeLock() }
    }

    // ----- GlassHandler (link thread; must not block) ------------------------------------

    @SuppressLint("ApplySharedPref")
    override fun onWelcome(welcome: Welcome) {
        sessionAccepted = true
        if (MediaRules.forgetSyncedOn(welcome, prefs.getString(Pairing.KEY_TOKEN, null))) {
            // Perhaps a different phone (fake_phone first, then the iPhone): it should get the
            // whole backlog. Here, on the link thread, so it's done before this session's `sync`
            // (routed next on this thread) can start a scan; and before the token is saved, so a
            // crash in between means pairing (and forgetting) again, not a lost backlog.
            BridgeLog.i(MediaRules.forgetSyncedMessage(mediaSync.forgetSynced()))
        }
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
        if (::ancs.isInitialized) ancs.setPhoneLinked(GlassState.link.isLinked)
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

    /**
     * The 60 s tick (main thread): `status`, a media re-scan, and a redial straight away if
     * the link is down (the backoff wait doesn't run while Glass sleeps). Holds the CPU awake
     * for a few seconds so this work finishes; uploads hold their own wake lock (MediaSync).
     */
    private fun onTick() {
        scheduleTick()
        // The watchdog thread's sleep stops while Glass is suspended, so check the silence here,
        // inside this wake: a link that died while Glass slept (>= 30 s of silence on
        // elapsedRealtime) is closed now, and this same tick redials.
        connection.checkSilence()
        val connected = connection.isConnected
        try {
            tickWakeLock?.acquire(if (connected) TICK_WAKE_LINKED_MS else TICK_WAKE_REDIAL_MS)
        } catch (e: RuntimeException) {
            BridgeLog.w("Tick wake lock failed: $e")
        }
        sendStatus("every 60 s")
        mediaSync.rescan()
        if (!connected) connection.retryNow()
    }

    private fun releaseTickWakeLock() {
        try {
            tickWakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: RuntimeException) {
            BridgeLog.w("Tick wake lock release failed: $e")
        }
    }

    /** Sets the next tick STATUS_INTERVAL_MS from now: the wakeup alarm, else a Handler delay. */
    private fun scheduleTick() {
        main.removeCallbacks(statusTick)
        val am = alarms
        val pi = tickIntent
        if (am != null && pi != null) {
            try {
                // setExact (API 19): on KitKat set() and setRepeating() are inexact and may be
                // batched up to 75% of the interval late; status is meant to come every 60 s.
                am.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + STATUS_INTERVAL_MS, pi)
                return
            } catch (e: RuntimeException) {
                BridgeLog.w("Alarm not set ($e); the 60 s tick will pause while Glass sleeps")
            }
        }
        main.postDelayed(statusTick, STATUS_INTERVAL_MS)
    }

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

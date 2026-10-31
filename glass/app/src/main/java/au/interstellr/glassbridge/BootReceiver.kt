package au.interstellr.glassbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import au.interstellr.glassbridge.core.BridgeLog

/** Starts [BridgeService] when Glass boots. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        Logs.install()
        BridgeLog.i("Boot completed: starting BridgeService")
        BridgeService.start(context)
    }
}

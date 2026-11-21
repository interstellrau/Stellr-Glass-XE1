package au.interstellr.glassbridge

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import au.interstellr.glassbridge.core.BridgeLog
import au.interstellr.glassbridge.core.TimelineStatus
import java.lang.reflect.Method

/**
 * StellrGlass's live card on Glass's own timeline (next to the clock): what the app is doing,
 * from [TimelineStatus]. Tapping it opens the card screen.
 *
 * It's a GDK LiveCard. The GDK ships on XE24 as the shared library com.google.android.glass
 * (declared in the manifest with required="false"), but there's no compile-time GDK in this
 * build, so LiveCard is reached by reflection. Where the library or the class is missing,
 * this logs once and does nothing. Main thread only.
 */
class TimelineCard(private val context: Context) {

    companion object {
        private const val LIVE_CARD = "com.google.android.glass.timeline.LiveCard"
        private const val TAG = "stellrglass-status"
    }

    private var card: Any? = null
    private var setViews: Method? = null
    private var shown: TimelineStatus? = null
    private var unavailable = false

    fun show(status: TimelineStatus) {
        if (unavailable || status == shown) return
        try {
            val c = card
            if (c == null) {
                publish(status)
            } else {
                setViews!!.invoke(c, views(status))
            }
            shown = status
        } catch (e: Throwable) {
            // ClassNotFoundException off Glass; anything else means the GDK changed under us.
            unavailable = true
            card = null
            BridgeLog.w("Timeline card unavailable: $e")
        }
    }

    fun remove() {
        val c = card ?: return
        card = null
        shown = null
        try {
            c.javaClass.getMethod("unpublish").invoke(c)
        } catch (e: Throwable) {
            BridgeLog.w("Timeline card unpublish failed: $e")
        }
    }

    private fun publish(status: TimelineStatus) {
        val cls = Class.forName(LIVE_CARD)
        val c = cls.getConstructor(Context::class.java, String::class.java).newInstance(context, TAG)
        val open = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        cls.getMethod("setAction", PendingIntent::class.java)
            .invoke(c, PendingIntent.getActivity(context, 0, open, 0))
        val sv = cls.getMethod("setViews", RemoteViews::class.java)
        sv.invoke(c, views(status))
        val mode = Class.forName("$LIVE_CARD\$PublishMode")
        val silent = mode.enumConstants!!.first { (it as Enum<*>).name == "SILENT" }
        cls.getMethod("publish", mode).invoke(c, silent)
        card = c
        setViews = sv
        BridgeLog.i("Timeline card published")
    }

    private fun views(status: TimelineStatus): RemoteViews {
        val v = RemoteViews(context.packageName, R.layout.timeline_card)
        v.setTextViewText(R.id.timeline_headline, status.headline)
        v.setTextViewText(R.id.timeline_detail, status.detail)
        return v
    }
}

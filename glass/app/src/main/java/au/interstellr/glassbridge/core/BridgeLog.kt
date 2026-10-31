package au.interstellr.glassbridge.core

import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Logging for core code, with a pluggable sink.
 *
 * Core can't import android.util.Log, so it logs here. On Glass, BridgeService points
 * [sink] at android.util.Log (tag [TAG]); on the JVM the default sink prints to stdout.
 * Priorities use android.util.Log's values, so a sink can pass them straight through:
 *
 *     BridgeLog.sink = object : BridgeLog.Sink {
 *         override fun log(priority: Int, tag: String, message: String, error: Throwable?) {
 *             Log.println(priority, tag,
 *                 if (error == null) message else message + "\n" + Log.getStackTraceString(error))
 *         }
 *     }
 *
 * Thread-safe. A sink that throws is ignored. The last [RECENT_MAX] lines are kept in
 * memory ([recent]) for on-device diagnostics.
 */
object BridgeLog {
    const val TAG = "GlassBridge"

    const val VERBOSE = 2
    const val DEBUG = 3
    const val INFO = 4
    const val WARN = 5
    const val ERROR = 6

    const val RECENT_MAX = 200

    interface Sink {
        fun log(priority: Int, tag: String, message: String, error: Throwable?)
    }

    /** Prints "HH:mm:ss.SSS I/GlassBridge: message" to stdout (the JVM default). */
    @JvmField
    val STDOUT: Sink = object : Sink {
        override fun log(priority: Int, tag: String, message: String, error: Throwable?) {
            val line = stamp() + " " + letter(priority) + "/" + tag + ": " + message
            synchronized(System.out) {
                println(line)
                error?.printStackTrace(System.out)
            }
        }
    }

    @Volatile
    @JvmStatic
    var sink: Sink = STDOUT

    /** Messages below this priority are dropped. */
    @Volatile
    @JvmStatic
    var minPriority: Int = DEBUG

    private val recentLines = java.util.ArrayDeque<String>()
    private val stampFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @JvmStatic fun v(message: String) = log(VERBOSE, TAG, message, null)
    @JvmStatic fun d(message: String) = log(DEBUG, TAG, message, null)
    @JvmStatic fun i(message: String) = log(INFO, TAG, message, null)
    @JvmStatic @JvmOverloads fun w(message: String, error: Throwable? = null) = log(WARN, TAG, message, error)
    @JvmStatic @JvmOverloads fun e(message: String, error: Throwable? = null) = log(ERROR, TAG, message, error)

    @JvmStatic
    fun log(priority: Int, tag: String, message: String, error: Throwable?) {
        if (priority < minPriority) return
        val entry = stamp() + " " + letter(priority) + "/" + tag + ": " + message +
            (if (error != null) " (" + error + ")" else "")
        synchronized(recentLines) {
            recentLines.addLast(entry)
            while (recentLines.size > RECENT_MAX) recentLines.removeFirst()
        }
        try {
            sink.log(priority, tag, message, error)
        } catch (t: Throwable) {
            // Logging must never break the caller.
        }
    }

    /** The most recent log lines, oldest first. */
    @JvmStatic
    fun recent(): List<String> = synchronized(recentLines) { ArrayList(recentLines) }

    /** A throwable's stack trace as text. */
    @JvmStatic
    fun stackTrace(t: Throwable): String {
        val sw = StringWriter()
        t.printStackTrace(PrintWriter(sw))
        return sw.toString()
    }

    private fun stamp(): String = synchronized(stampFormat) { stampFormat.format(Date()) }

    private fun letter(priority: Int): String = when (priority) {
        VERBOSE -> "V"
        DEBUG -> "D"
        INFO -> "I"
        WARN -> "W"
        ERROR -> "E"
        else -> priority.toString()
    }
}

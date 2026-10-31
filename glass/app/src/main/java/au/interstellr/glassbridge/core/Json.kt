package au.interstellr.glassbridge.core

import org.json.JSONObject
import java.math.BigInteger

/**
 * Typed, lenient reads from org.json objects.
 *
 * Android API 19's org.json and the reference org.json used by the JVM tests differ in
 * ways that matter here: Android's `optString` turns a JSON null into the text "null",
 * and the reference library parses fractions as BigDecimal where Android uses Double.
 * Everything in core therefore reads values through [raw] (`opt` + a NULL check) and
 * type checks, which behave the same on both. Only API-19 org.json calls are used.
 *
 * Numbers: PROTOCOL.md section 5 says receivers accept an integer or a fractional JSON
 * number for any numeric field, so [long] and [int] round fractions.
 */
object Json {

    /** The value for [key], or null when it is absent or JSON null. */
    @JvmStatic
    fun raw(o: JSONObject, key: String): Any? {
        val v = o.opt(key)
        return if (v == null || v == JSONObject.NULL) null else v
    }

    /** True when [key] is present and not JSON null. */
    @JvmStatic
    fun has(o: JSONObject, key: String): Boolean = raw(o, key) != null

    /** A JSON string, or null (numbers and booleans are not converted). */
    @JvmStatic
    fun str(o: JSONObject, key: String): String? = raw(o, key) as? String

    /** A JSON string, or a number written as text (for ids and codes); otherwise null. */
    @JvmStatic
    fun text(o: JSONObject, key: String): String? {
        val v = raw(o, key) ?: return null
        return when {
            v is String -> v
            isInteger(v) -> v.toString()
            v is Number -> {
                val d = v.toDouble()
                if (!d.isNaN() && !d.isInfinite() && d == Math.rint(d) && Math.abs(d) < 1e15) {
                    d.toLong().toString()
                } else {
                    v.toString()
                }
            }
            else -> null
        }
    }

    /** A JSON number, or null. Booleans are not numbers. */
    @JvmStatic
    fun num(o: JSONObject, key: String): Number? = raw(o, key) as? Number

    /** A number as a Long (fractions rounded), or null when absent, not a number, NaN or infinite. */
    @JvmStatic
    fun long(o: JSONObject, key: String): Long? {
        val n = num(o, key) ?: return null
        if (isInteger(n)) {
            return if (n is BigInteger) {
                if (n.bitLength() > 63) null else n.toLong()
            } else {
                n.toLong()
            }
        }
        val d = n.toDouble()
        if (d.isNaN() || d.isInfinite()) return null
        return Math.round(d)
    }

    /** A number as an Int (fractions rounded), or null when absent, not a number or out of range. */
    @JvmStatic
    fun int(o: JSONObject, key: String): Int? {
        val l = long(o, key) ?: return null
        return if (l < Int.MIN_VALUE || l > Int.MAX_VALUE) null else l.toInt()
    }

    /** A number as a Double, or null when absent, not a number, NaN or infinite. */
    @JvmStatic
    fun double(o: JSONObject, key: String): Double? {
        val n = num(o, key) ?: return null
        val d = n.toDouble()
        return if (d.isNaN() || d.isInfinite()) null else d
    }

    /** A JSON boolean (or the strings "true"/"false", like Android's optBoolean), or null. */
    @JvmStatic
    fun bool(o: JSONObject, key: String): Boolean? {
        val v = raw(o, key) ?: return null
        if (v is Boolean) return v
        if (v is String) {
            if (v.equals("true", ignoreCase = true)) return true
            if (v.equals("false", ignoreCase = true)) return false
        }
        return null
    }

    /** True for integral JSON numbers (never for fractions such as 3.0 or 1e2, matching gbproto.py). */
    @JvmStatic
    fun isInteger(v: Any?): Boolean =
        v is Int || v is Long || v is Short || v is Byte || v is BigInteger
}

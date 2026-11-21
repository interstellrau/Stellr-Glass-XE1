package au.interstellr.glassbridge.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.UUID

/** ANCS packets (PROTOCOL.md section 10): parse, build, reassemble, advert match, card rule. */
class AncsTest {

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private fun attr(out: ByteArrayOutputStream, id: Int, value: String) {
        val v = value.toByteArray(Charsets.UTF_8)
        out.write(id)
        out.write(v.size and 0xFF)
        out.write((v.size shr 8) and 0xFF)
        out.write(v, 0, v.size)
    }

    private fun notificationResponse(uid: Long, app: String, title: String, subtitle: String, message: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(Ancs.CMD_GET_NOTIFICATION_ATTRIBUTES)
        for (k in 0 until 4) out.write(((uid ushr (8 * k)) and 0xFF).toInt())
        attr(out, Ancs.ATTR_APP_IDENTIFIER, app)
        attr(out, Ancs.ATTR_TITLE, title)
        attr(out, Ancs.ATTR_SUBTITLE, subtitle)
        attr(out, Ancs.ATTR_MESSAGE, message)
        return out.toByteArray()
    }

    private fun chunks(b: ByteArray, size: Int): List<ByteArray> =
        (b.indices step size).map { b.copyOfRange(it, minOf(it + size, b.size)) }

    @Test
    fun parsesNotificationSourcePacket() {
        val e = AncsEvent.parse(bytes(0, Ancs.FLAG_PRE_EXISTING or Ancs.FLAG_IMPORTANT, 4, 2, 0x78, 0x56, 0x34, 0xF2))
        assertNotNull(e)
        e!!
        assertEquals(Ancs.EVENT_ADDED, e.eventId)
        assertTrue(e.isPreExisting)
        assertFalse(e.isSilent)
        assertEquals("Social", Ancs.categoryName(e.categoryId))
        assertEquals(0xF2345678L, e.uid)
        assertTrue(AncsEvent.parse(bytes(2, 0, 0, 0, 1, 0, 0, 0))!!.isRemoved)
        assertNull(AncsEvent.parse(bytes(0, 0, 0, 0, 1, 0, 0)))
        assertNull(AncsEvent.parse(null))
        assertEquals("Other", Ancs.categoryName(200))
    }

    @Test
    fun buildsControlPointRequests() {
        assertArrayEquals(
            bytes(0, 0x78, 0x56, 0x34, 0x12, 0, 1, 64, 0, 2, 64, 0, 3, 0, 1),
            Ancs.notificationRequest(0x12345678L).bytes()
        )
        assertArrayEquals(
            bytes(1, 'a'.code, '.'.code, 'b'.code, 0, 0),
            Ancs.appNameRequest("a.b").bytes()
        )
    }

    @Test
    fun reassemblesNotificationResponseFromTwentyByteChunks() {
        val req = Ancs.notificationRequest(7L)
        val reader = AncsResponseReader(req)
        val full = notificationResponse(7L, "com.apple.MobileSMS", "Sam", "", "Are you free at 6? ☕")
        val parts = chunks(full, 20)
        assertTrue(parts.size > 2)
        for (k in 0 until parts.size - 1) assertNull(reader.feed(parts[k]))
        val r = reader.feed(parts.last())
        assertNotNull(r)
        assertEquals("com.apple.MobileSMS", r!!.attrs[Ancs.ATTR_APP_IDENTIFIER])
        assertEquals("Sam", r.attrs[Ancs.ATTR_TITLE])
        assertEquals("", r.attrs[Ancs.ATTR_SUBTITLE])
        assertEquals("Are you free at 6? ☕", r.attrs[Ancs.ATTR_MESSAGE])
        assertNull(reader.error)
    }

    @Test
    fun rejectsResponseForAnotherRequest() {
        val wrongUid = AncsResponseReader(Ancs.notificationRequest(7L))
        assertNull(wrongUid.feed(notificationResponse(8L, "a", "b", "", "c")))
        assertNotNull(wrongUid.error)

        val wrongCommand = AncsResponseReader(Ancs.appNameRequest("a"))
        assertNull(wrongCommand.feed(notificationResponse(8L, "a", "b", "", "c")))
        assertNotNull(wrongCommand.error)
        // Once failed, further chunks are ignored.
        assertNull(wrongCommand.feed(bytes(1)))
    }

    @Test
    fun reassemblesAppNameResponse() {
        val out = ByteArrayOutputStream()
        out.write(Ancs.CMD_GET_APP_ATTRIBUTES)
        out.write("com.apple.MobileSMS".toByteArray(Charsets.UTF_8))
        out.write(0)
        attr(out, Ancs.APP_ATTR_DISPLAY_NAME, "Messages")
        val reader = AncsResponseReader(Ancs.appNameRequest("com.apple.MobileSMS"))
        val parts = chunks(out.toByteArray(), 7)
        var r: AncsResponse? = null
        for (p in parts) r = reader.feed(p)
        assertEquals("Messages", r!!.attrs[Ancs.APP_ATTR_DISPLAY_NAME])
    }

    @Test
    fun matchesAdvertisedServiceInScanRecord() {
        val le = Ancs.uuidLittleEndian(Ancs.GLASSBRIDGE_SERVICE)
        // The UUID string's last byte comes first on the air.
        assertEquals(0xD2.toByte(), le[0])
        assertEquals(0xCD.toByte(), le[15])
        val record = ByteArrayOutputStream()
        record.write(bytes(2, 0x01, 0x06), 0, 3)            // flags
        record.write(17); record.write(0x07); record.write(le, 0, 16)
        record.write(bytes(5, 0x09, 'G'.code, 'B'.code, 'x'.code, 'y'.code), 0, 6)
        val withZeros = record.toByteArray() + ByteArray(20) // KitKat pads to 62 bytes
        assertTrue(Ancs.advertises(withZeros, Ancs.GLASSBRIDGE_SERVICE))
        assertFalse(Ancs.advertises(withZeros, UUID.randomUUID()))
        assertFalse(Ancs.advertises(withZeros.copyOf(10), Ancs.GLASSBRIDGE_SERVICE))
        assertFalse(Ancs.advertises(null, Ancs.GLASSBRIDGE_SERVICE))
        // A 16-bit service list (type 0x03) never matches a 128-bit UUID.
        assertFalse(Ancs.advertises(bytes(3, 0x03, 0x0F, 0x18), Ancs.GLASSBRIDGE_SERVICE))
    }

    @Test
    fun cardRule() {
        val attrs = mapOf(
            Ancs.ATTR_APP_IDENTIFIER to "com.apple.MobileSMS",
            Ancs.ATTR_TITLE to "Sam",
            Ancs.ATTR_SUBTITLE to "",
            Ancs.ATTR_MESSAGE to "Are you free?"
        )
        val fresh = Ancs.card(AncsEvent(Ancs.EVENT_ADDED, 0, 4, 1, 42L), attrs, "Messages", 1000L)
        assertEquals("ancs-42", fresh.id)
        assertEquals("Sam", fresh.title)
        assertEquals("Are you free?", fresh.text)
        assertEquals("Messages", fresh.source)
        assertTrue(fresh.isNotification)
        assertTrue(fresh.chime && fresh.wake)

        val old = Ancs.card(AncsEvent(Ancs.EVENT_ADDED, Ancs.FLAG_PRE_EXISTING, 4, 1, 42L), attrs, "Messages", 1000L)
        assertFalse(old.chime || old.wake)
        val silent = Ancs.card(AncsEvent(Ancs.EVENT_ADDED, Ancs.FLAG_SILENT, 4, 1, 42L), attrs, null, 1000L)
        assertFalse(silent.chime)
        assertEquals("com.apple.MobileSMS", silent.source)
        val modified = Ancs.card(AncsEvent(Ancs.EVENT_MODIFIED, 0, 4, 1, 42L), attrs, "Messages", 1000L)
        assertFalse(modified.chime)

        val call = Ancs.card(
            AncsEvent(Ancs.EVENT_ADDED, 0, 1, 1, 9L),
            mapOf(Ancs.ATTR_TITLE to "Mum"),
            "Phone",
            1000L
        )
        assertEquals("Mum", call.title)
        assertEquals("Incoming call", call.text)

        val bare = Ancs.card(AncsEvent(Ancs.EVENT_ADDED, 0, 6, 1, 9L), emptyMap(), "Mail", 1000L)
        assertEquals("Mail", bare.title)
        assertEquals("Email", bare.text)
    }
}

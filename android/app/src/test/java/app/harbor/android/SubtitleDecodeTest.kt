package app.harbor.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.util.zip.GZIPOutputStream

class SubtitleDecodeTest {
    private val arabic = "1\n00:00:01,000 --> 00:00:02,000\nمرحبا بكم في هذا الفيلم الجميل جدا\n\n2\n00:00:03,000 --> 00:00:04,000\nكيف حالك اليوم يا صديقي العزيز\n"

    @Test fun utf8IsKept() {
        assertEquals(arabic, SubtitleStore.decodeText(arabic.toByteArray(Charsets.UTF_8), null))
    }

    @Test fun windows1256WithoutLanguageIsGuessed() {
        val bytes = arabic.toByteArray(Charset.forName("windows-1256"))
        assertEquals("windows-1256", SubtitleStore.guessCodePage(bytes))
        assertEquals(arabic, SubtitleStore.decodeText(bytes, null))
        assertEquals(arabic, SubtitleStore.decodeText(bytes, "und"))
    }

    @Test fun kurdishTagUsesArabicCodePage() {
        val bytes = arabic.toByteArray(Charset.forName("windows-1256"))
        assertEquals(arabic, SubtitleStore.decodeText(bytes, "ku"))
    }

    @Test fun latinLegacyStaysWindows1252() {
        val fr = "1\n00:00:01,000 --> 00:00:02,000\nC'est très bien, merci. Où êtes-vous allé hier soir ?\n"
        val bytes = fr.toByteArray(Charset.forName("windows-1252"))
        assertEquals(fr, SubtitleStore.decodeText(bytes, null))
    }

    @Test fun utf16WithoutBomIsDetected() {
        val text = "1\n00:00:01,000 --> 00:00:02,000\nHello there, this is a subtitle line.\n"
        assertEquals(text, SubtitleStore.decodeText(text.toByteArray(Charsets.UTF_16LE), null))
    }

    @Test fun gzipBombIsRefused() {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { gz -> val zeros = ByteArray(1024 * 1024); repeat(20) { gz.write(zeros) } } // 20 MB of zeros
        val bomb = out.toByteArray()
        assertTrue(bomb.size < 200_000)
        try {
            SubtitleStore.unpack(bomb)
            fail("a 20 MB subtitle must be refused")
        } catch (_: java.io.IOException) {
        }
    }

    @Test fun smallGzipUnpacks() {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(arabic.toByteArray(Charsets.UTF_8)) }
        assertEquals(arabic, String(SubtitleStore.unpack(out.toByteArray()), Charsets.UTF_8))
    }
}

package app.harbor.android

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SubtitleStoreTest {
    private fun store() = SubtitleStore(Files.createTempDirectory("subs").toFile())

    private fun sub(store: SubtitleStore, name: String, mime: String, text: String): SubtitleStore.LocalSub {
        val dir = Files.createTempDirectory("src").toFile()
        val f = File(dir, name).apply { writeText(text) }
        return SubtitleStore.LocalSub("s1", f, mime, "ar", null, "http://x")
    }

    @Test fun shiftsSrtForwardAndClampsAtZero() {
        val st = store()
        val s = sub(st, "s1.srt", MimeTypes.APPLICATION_SUBRIP, "1\n00:00:00,300 --> 00:00:02,000\nمرحبا\n\n2\n01:59:59,500 --> 02:00:01,250\nbye\n")
        assertEquals(
            "1\n00:00:01,800 --> 00:00:03,500\nمرحبا\n\n2\n02:00:01,000 --> 02:00:02,750\nbye\n",
            st.shifted(s, 1500).file.readText(),
        )
        assertEquals(
            "1\n00:00:00,000 --> 00:00:01,500\nمرحبا\n\n2\n01:59:59,000 --> 02:00:00,750\nbye\n",
            st.shifted(s, -500).file.readText(),
        )
    }

    @Test fun shiftsVttShortAndLongTimes() {
        val st = store()
        val s = sub(st, "s1.vtt", MimeTypes.TEXT_VTT, "WEBVTT\n\n01:02.345 --> 00:01:03.000 align:start\nhi\n")
        assertEquals(
            "WEBVTT\n\n00:01:02.845 --> 00:01:03.500 align:start\nhi\n",
            st.shifted(s, 500).file.readText(),
        )
    }

    @Test fun shiftsOnlyAssStartAndEnd() {
        val st = store()
        val s = sub(st, "s1.ass", MimeTypes.TEXT_SSA,
            "[Events]\nDialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,at 0:00:09.00 text\n")
        assertEquals(
            "[Events]\nDialogue: 0,0:00:02.00,0:00:03.50,Default,,0,0,0,,at 0:00:09.00 text\n",
            st.shifted(s, 500).file.readText(),
        )
    }
}

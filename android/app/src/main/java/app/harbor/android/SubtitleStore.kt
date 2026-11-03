package app.harbor.android

import android.content.Context
import androidx.media3.common.MimeTypes
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.GZIPInputStream
import java.util.zip.ZipInputStream

/**
 * Downloads an addon subtitle to a local file (only when it's picked), normalising it on the
 * way: gzip/zip unpacking, legacy encodings (Arabic windows-1256 etc.) re-encoded as UTF-8,
 * and format sniffing (SRT / VTT / ASS) since addon URLs often have no file extension.
 */
class SubtitleStore(private val dir: File) {
    constructor(context: Context) : this(File(context.cacheDir, "subs"))
    init {
        dir.mkdirs()
    }

    data class LocalSub(val id: String, val file: File, val mime: String, val lang: String?, val label: String?, val sourceUrl: String)

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }

    fun fetch(id: String, url: String, lang: String?, label: String?, userAgent: String): LocalSub? = try {
        val raw = unpack(download(url, userAgent))
        val text = decode(raw, lang).trimStart('﻿')
        val head = text.trimStart()
        val (mime, ext) = when {
            head.startsWith("WEBVTT") -> MimeTypes.TEXT_VTT to "vtt"
            head.contains("[Script Info]", ignoreCase = true) || head.contains("[Events]", ignoreCase = true) -> MimeTypes.TEXT_SSA to "ass"
            text.contains("-->") -> MimeTypes.APPLICATION_SUBRIP to "srt"
            else -> null to null
        }
        if (mime == null) {
            null
        } else {
            val f = File(dir, "$id.$ext")
            f.writeText(if (ext == "srt") text.replace("\r\n", "\n") else text, Charsets.UTF_8)
            LocalSub(id, f, mime, lang, label, url)
        }
    } catch (_: Exception) {
        null
    }

    private fun download(url: String, userAgent: String): ByteArray {
        // Offline: subtitles saved next to a downloaded video.
        if (url.startsWith("file:")) return File(java.net.URI(url)).readBytes()
        var u = URL(url)
        repeat(6) {
            val c = u.openConnection() as HttpURLConnection
            c.instanceFollowRedirects = false
            c.connectTimeout = 8_000
            c.readTimeout = 10_000
            c.setRequestProperty("User-Agent", userAgent)
            val code = c.responseCode
            if (code in 300..399) {
                val loc = c.getHeaderField("Location") ?: error("redirect without location")
                u = URL(u, loc)
                c.disconnect()
                return@repeat
            }
            if (code !in 200..299) error("HTTP $code")
            val bytes = c.inputStream.use { s ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(32 * 1024)
                while (true) {
                    val n = s.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > 8 * 1024 * 1024) error("subtitle too large")
                }
                out.toByteArray()
            }
            c.disconnect()
            return bytes
        }
        error("too many redirects")
    }

    private fun unpack(b: ByteArray): ByteArray {
        if (b.size > 2 && b[0] == 0x1f.toByte() && b[1] == 0x8b.toByte()) {
            return GZIPInputStream(ByteArrayInputStream(b)).use { it.readBytes() }
        }
        if (b.size > 4 && b[0] == 'P'.code.toByte() && b[1] == 'K'.code.toByte()) {
            ZipInputStream(ByteArrayInputStream(b)).use { z ->
                while (true) {
                    val e = z.nextEntry ?: break
                    val n = e.name.lowercase()
                    if (!e.isDirectory && (n.endsWith(".srt") || n.endsWith(".vtt") || n.endsWith(".ass") || n.endsWith(".ssa"))) {
                        return z.readBytes()
                    }
                }
            }
        }
        return b
    }

    private fun decode(b: ByteArray, lang: String?): String {
        if (b.size >= 2 && b[0] == 0xFF.toByte() && b[1] == 0xFE.toByte()) return String(b, Charsets.UTF_16LE)
        if (b.size >= 2 && b[0] == 0xFE.toByte() && b[1] == 0xFF.toByte()) return String(b, Charsets.UTF_16BE)
        try {
            return Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(b))
                .toString()
        } catch (_: CharacterCodingException) {
            // Not UTF-8: pick the usual legacy code page for the language.
        }
        val l = (lang ?: "").lowercase()
        val cs = when {
            l.startsWith("ar") || l.startsWith("fa") || l.startsWith("per") || l.startsWith("ur") -> "windows-1256"
            l.startsWith("he") || l.startsWith("heb") -> "windows-1255"
            l.startsWith("ru") || l.startsWith("uk") || l.startsWith("bg") || l.startsWith("sr") -> "windows-1251"
            l.startsWith("el") || l.startsWith("gre") -> "windows-1253"
            l.startsWith("tr") -> "windows-1254"
            l.startsWith("pl") || l.startsWith("cs") || l.startsWith("cz") || l.startsWith("hu") || l.startsWith("ro") || l.startsWith("hr") || l.startsWith("sk") -> "windows-1250"
            else -> "windows-1252"
        }
        return String(b, Charset.forName(cs))
    }
}

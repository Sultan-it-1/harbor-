package app.harbor.android

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.Collections
import kotlin.random.Random

/** Runs HttpTransfer against a small local HTTP server. */
class HttpTransferTest {
    private lateinit var server: MiniServer
    private lateinit var dir: File
    private val body = Random(7).nextBytes(3 * 1024 * 1024 + 123)
    private val ranges = Collections.synchronizedList(ArrayList<String?>())
    private val port get() = server.port

    @Before fun setUp() {
        dir = Files.createTempDirectory("harbor-dl").toFile()
        server = MiniServer { path, headers, out ->
            when (path) {
                "/file" -> serve(headers["range"], out, rangeSupport = true)
                "/norange" -> serve(headers["range"], out, rangeSupport = false)
                "/redirect" -> respond(out, 302, mapOf("Location" to "/file"))
                "/gone" -> respond(out, 404)
                "/busy" -> respond(out, 503)
                "/short" -> {
                    // Promises the whole file, sends half, hangs up.
                    ranges.add(headers["range"])
                    respond(out, 200, mapOf("Content-Length" to "${body.size}"), body, body.size / 2)
                }
                else -> respond(out, 404)
            }
        }
    }

    @After fun tearDown() {
        server.close()
        dir.deleteRecursively()
    }

    private fun serve(range: String?, out: OutputStream, rangeSupport: Boolean) {
        ranges.add(range)
        val m = range?.let { Regex("bytes=(\\d+)-").find(it) }
        if (rangeSupport && m != null) {
            val start = m.groupValues[1].toInt()
            if (start >= body.size) {
                respond(out, 416, mapOf("Content-Range" to "bytes */${body.size}", "Content-Length" to "0"))
                return
            }
            respond(
                out, 206,
                mapOf("Content-Range" to "bytes $start-${body.size - 1}/${body.size}", "Content-Length" to "${body.size - start}"),
                body.copyOfRange(start, body.size),
            )
        } else {
            respond(out, 200, mapOf("Content-Length" to "${body.size}"), body)
        }
    }

    private fun respond(out: OutputStream, code: Int, headers: Map<String, String> = emptyMap(), data: ByteArray? = null, send: Int = data?.size ?: 0) {
        val head = StringBuilder("HTTP/1.1 $code X\r\n")
        headers.forEach { (k, v) -> head.append("$k: $v\r\n") }
        if (data == null && !headers.containsKey("Content-Length")) head.append("Content-Length: 0\r\n")
        head.append("Connection: close\r\n\r\n")
        try {
            out.write(head.toString().toByteArray(Charsets.ISO_8859_1))
            if (data != null) out.write(data, 0, send)
            out.flush()
        } catch (_: IOException) {
            // the client stopped reading (pause test)
        }
    }

    /** Just enough HTTP/1.1 for these tests: one request per connection. */
    private class MiniServer(private val handler: (String, Map<String, String>, OutputStream) -> Unit) {
        private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port: Int get() = socket.localPort

        init {
            Thread {
                while (!socket.isClosed) {
                    val s = try { socket.accept() } catch (_: IOException) { break }
                    Thread { handle(s) }.apply { isDaemon = true }.start()
                }
            }.apply { isDaemon = true }.start()
        }

        private fun handle(s: Socket) {
            s.use {
                val input = BufferedInputStream(s.getInputStream())
                fun line(): String? {
                    val b = StringBuilder()
                    while (true) {
                        val c = input.read()
                        if (c < 0) return if (b.isEmpty()) null else b.toString()
                        if (c == '\n'.code) return b.toString().trimEnd('\r')
                        b.append(c.toChar())
                    }
                }
                val request = line() ?: return
                val path = request.split(" ").getOrNull(1) ?: return
                val headers = HashMap<String, String>()
                while (true) {
                    val h = line() ?: break
                    if (h.isEmpty()) break
                    val i = h.indexOf(':')
                    if (i > 0) headers[h.substring(0, i).trim().lowercase()] = h.substring(i + 1).trim()
                }
                handler(path, headers, s.getOutputStream())
            }
        }

        fun close() = socket.close()
    }

    private class Probe(val stopAfter: Long = Long.MAX_VALUE, val free: Long = Long.MAX_VALUE) : HttpTransfer.Listener {
        var total = -2L
        var received = 0L
        override fun onTotal(total: Long) { this.total = total }
        override fun onProgress(received: Long) { this.received = received }
        override fun shouldStop() = received >= stopAfter
        override fun freeSpace() = free
    }

    private fun transfer(path: String, part: File, probe: Probe = Probe()) =
        HttpTransfer("http://127.0.0.1:$port$path", mapOf("Referer" to "https://example.org/"), "HarborTest", part, probe)

    @Test fun downloadsWholeFile() {
        val part = File(dir, "a.part")
        val probe = Probe()
        assertEquals(HttpTransfer.Result.Done, transfer("/file", part, probe).run())
        assertArrayEquals(body, part.readBytes())
        assertEquals(body.size.toLong(), probe.total)
        assertEquals(body.size.toLong(), probe.received)
        assertEquals(listOf<String?>(null), ranges)
    }

    @Test fun resumesFromPartialFile() {
        val part = File(dir, "b.part")
        part.writeBytes(body.copyOfRange(0, 1_000_000))
        assertEquals(HttpTransfer.Result.Done, transfer("/file", part).run())
        assertArrayEquals(body, part.readBytes())
        assertEquals(listOf<String?>("bytes=1000000-"), ranges)
    }

    @Test fun startsOverWhenServerIgnoresRange() {
        val part = File(dir, "c.part")
        part.writeBytes(body.copyOfRange(0, 500_000))
        assertEquals(HttpTransfer.Result.Done, transfer("/norange", part).run())
        assertArrayEquals(body, part.readBytes()) // not appended twice
    }

    @Test fun alreadyCompleteFileIsDone() {
        val part = File(dir, "d.part")
        part.writeBytes(body)
        val probe = Probe()
        assertEquals(HttpTransfer.Result.Done, transfer("/file", part, probe).run())
        assertArrayEquals(body, part.readBytes())
        assertEquals(body.size.toLong(), probe.total)
    }

    @Test fun followsRedirects() {
        val part = File(dir, "e.part")
        assertEquals(HttpTransfer.Result.Done, transfer("/redirect", part).run())
        assertArrayEquals(body, part.readBytes())
    }

    @Test fun expiredLinkFails() {
        val r = transfer("/gone", File(dir, "f.part")).run()
        assertTrue(r is HttpTransfer.Result.Fail)
        r as HttpTransfer.Result.Fail
        assertEquals(HttpTransfer.Problem.REFUSED, r.problem)
        assertEquals(404, r.httpCode)
    }

    @Test fun busyServerIsRetried() {
        val r = transfer("/busy", File(dir, "g.part")).run()
        assertTrue(r is HttpTransfer.Result.Retry && r.problem == HttpTransfer.Problem.SERVER)
    }

    @Test fun cutConnectionIsRetriedThenResumes() {
        val part = File(dir, "h.part")
        val r = transfer("/short", part).run()
        assertTrue("got $r", r is HttpTransfer.Result.Retry && r.madeProgress)
        val have = part.length()
        assertTrue(have in 1 until body.size)
        // The next attempt (here against the full server) carries on from there.
        assertEquals(HttpTransfer.Result.Done, transfer("/file", part).run())
        assertArrayEquals(body, part.readBytes())
        assertEquals("bytes=$have-", ranges.last())
    }

    @Test fun stopsWhenAsked() {
        val part = File(dir, "i.part")
        val r = transfer("/file", part, Probe(stopAfter = 600_000)).run()
        assertEquals(HttpTransfer.Result.Stopped, r)
        val have = part.length()
        assertTrue(have in 600_000 until body.size)
        assertArrayEquals(body.copyOfRange(0, have.toInt()), part.readBytes())
    }

    @Test fun notEnoughSpaceFails() {
        val r = transfer("/file", File(dir, "j.part"), Probe(free = 1_000_000)).run()
        assertTrue(r is HttpTransfer.Result.Fail && r.problem == HttpTransfer.Problem.SPACE)
    }

    @Test fun noServerIsANetworkRetry() {
        val dead = HttpTransfer("http://127.0.0.1:1/x", emptyMap(), "HarborTest", File(dir, "k.part"), Probe())
        val r = dead.run()
        assertTrue(r is HttpTransfer.Result.Retry && r.problem == HttpTransfer.Problem.NETWORK)
    }

    @Test fun parsesContentRange() {
        assertEquals(HttpTransfer.ContentRange(100, 199, 1000), HttpTransfer.parseContentRange("bytes 100-199/1000"))
        assertEquals(1000L, HttpTransfer.parseContentRange("bytes */1000")?.total)
        assertEquals(-1L, HttpTransfer.parseContentRange("bytes 0-9/*")?.total)
        assertEquals(null, HttpTransfer.parseContentRange(null))
    }
}

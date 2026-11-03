package app.harbor.android

import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * CORS-free HTTP for the web UI. This replaces the /api-proxy route that server.js
 * provides on the hosted web build (addons without CORS headers, debrid REST APIs,
 * Stremio API logins). Response bodies travel back base64-encoded.
 */
class NativeFetch(private val done: (id: String, resultJson: String) -> Unit) {
    private val pool = Executors.newFixedThreadPool(6)
    @Volatile var userAgent: String = "Mozilla/5.0 (Linux; Android) HarborAndroid"

    fun enqueue(id: String, requestJson: String) {
        pool.execute { done(id, run(requestJson)) }
    }

    fun shutdown() = pool.shutdownNow()

    private fun run(requestJson: String): String {
        val out = JSONObject()
        try {
            val req = JSONObject(requestJson)
            val method = req.optString("method", "GET").uppercase()
            val timeout = req.optInt("timeoutMs", 30_000)
            var url = URL(req.getString("url"))
            val headers = req.optJSONObject("headers")
            val body = if (req.has("body") && !req.isNull("body")) req.getString("body") else null

            var conn: HttpURLConnection
            var redirects = 0
            while (true) {
                conn = url.openConnection() as HttpURLConnection
                conn.instanceFollowRedirects = false
                conn.connectTimeout = timeout
                conn.readTimeout = timeout
                conn.requestMethod = method
                conn.setRequestProperty("User-Agent", userAgent)
                headers?.keys()?.forEach { k ->
                    // HttpURLConnection handles gzip itself only when it set the header.
                    if (!k.equals("accept-encoding", true) && !k.equals("host", true) && !k.equals("content-length", true)) {
                        conn.setRequestProperty(k, headers.getString(k))
                    }
                }
                if (body != null && method != "GET" && method != "HEAD") {
                    conn.doOutput = true
                    conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val code = conn.responseCode
                if (code in 300..399 && code != 304 && redirects < 8) {
                    val loc = conn.getHeaderField("Location")
                    if (loc != null) {
                        url = URL(url, loc)
                        conn.disconnect()
                        redirects++
                        continue
                    }
                }
                break
            }

            val status = conn.responseCode
            val stream: InputStream? = if (status >= 400) conn.errorStream else try { conn.inputStream } catch (_: Exception) { conn.errorStream }
            val bytes = stream?.use { readAll(it) } ?: ByteArray(0)
            val hdrs = JSONObject()
            conn.headerFields.forEach { (k, v) ->
                if (k != null && v != null && !k.equals("content-encoding", true) && !k.equals("transfer-encoding", true) && !k.equals("content-length", true)) {
                    hdrs.put(k.lowercase(), v.joinToString(", "))
                }
            }
            conn.disconnect()
            out.put("ok", true)
            out.put("status", status)
            out.put("url", url.toString())
            out.put("headers", hdrs)
            out.put("body", Base64.encodeToString(bytes, Base64.NO_WRAP))
        } catch (e: Exception) {
            out.put("ok", false)
            out.put("error", e.javaClass.simpleName + ": " + (e.message ?: ""))
        }
        return out.toString()
    }

    private fun readAll(s: InputStream): ByteArray {
        val buf = ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        while (true) {
            val n = s.read(chunk)
            if (n < 0) break
            buf.write(chunk, 0, n)
        }
        return buf.toByteArray()
    }
}

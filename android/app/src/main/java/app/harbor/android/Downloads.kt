package app.harbor.android

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * In-app downloads for offline watching, on Android's DownloadManager:
 *  - saved in the app's own storage (Android/data/app.harbor.android/files/Movies/Harbor/<id>/),
 *    no folder picker and no storage permission; removed with the app
 *  - keeps going in the background with the system progress notification
 *  - addon subtitles are saved next to the video (normalised to UTF-8) and deleted with it
 *  - delete removes the video, its subtitles and the folder for good
 */
class Downloads(private val ctx: Context, private val userAgent: () -> String) {
    private val dm = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val prefs = ctx.getSharedPreferences("harbor.downloads", Context.MODE_PRIVATE)
    private val pool = Executors.newFixedThreadPool(2)

    private fun root(): File? = ctx.getExternalFilesDir(Environment.DIRECTORY_MOVIES)?.let { File(it, "Harbor") }

    private fun dirFor(id: String): File? = root()?.let { File(it, safe(id)) }

    private fun safe(s: String) = s.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80)

    private fun record(id: String): JSONObject? = prefs.getString(id, null)?.let { try { JSONObject(it) } catch (_: Exception) { null } }

    /** {id, url, headers, fileName, title, description, subtitles:[{url,lang,label}]} -> {ok, error?} */
    fun start(json: String): String {
        val out = JSONObject()
        try {
            val j = JSONObject(json)
            val id = j.getString("id")
            val dir = dirFor(id) ?: return out.put("ok", false).put("error", "storage unavailable").toString()
            dir.mkdirs()
            val fileName = safe(j.optString("fileName").ifBlank { "video.mp4" })
            val req = DownloadManager.Request(Uri.parse(j.getString("url")))
                .setTitle(j.optString("title").ifBlank { "Harbor" })
                .setDescription(j.optString("description"))
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .setDestinationInExternalFilesDir(ctx, Environment.DIRECTORY_MOVIES, "Harbor/${safe(id)}/$fileName")
            var ua = userAgent()
            j.optJSONObject("headers")?.let { h ->
                h.keys().forEach { k ->
                    if (k.equals("user-agent", true)) ua = h.getString(k) else req.addRequestHeader(k, h.getString(k))
                }
            }
            req.addRequestHeader("User-Agent", ua)
            val dmId = dm.enqueue(req)
            prefs.edit().putString(id, JSONObject().put("dmId", dmId).put("file", fileName).toString()).apply()
            j.optJSONArray("subtitles")?.let { subs -> if (subs.length() > 0) pool.execute { saveSubtitles(dir, subs, ua) } }
            prefs.edit().putString("ua:$id", ua).apply()
            out.put("ok", true)
        } catch (e: Exception) {
            out.put("ok", false).put("error", e.message ?: e.javaClass.simpleName)
        }
        return out.toString()
    }

    /** Adds addon subtitles to a download (found after it started). */
    fun addSubtitles(id: String, json: String): Boolean {
        val dir = dirFor(id) ?: return false
        if (!dir.exists()) return false
        val subs = try { JSONArray(json) } catch (_: Exception) { return false }
        val ua = prefs.getString("ua:$id", null) ?: userAgent()
        pool.execute { saveSubtitles(dir, subs, ua) }
        return true
    }

    private fun readSubs(dir: File): JSONArray =
        File(dir, "subs.json").takeIf { it.exists() }?.let { try { JSONArray(it.readText()) } catch (_: Exception) { null } } ?: JSONArray()

    /** Downloads + normalises each subtitle into <dir>/subs and appends it to subs.json. */
    @Synchronized
    private fun saveSubtitles(dir: File, subs: JSONArray, ua: String) {
        val store = SubtitleStore(File(dir, "subs"))
        val list = readSubs(dir)
        val have = (0 until list.length()).mapNotNull { list.optJSONObject(it)?.optString("url") }.toMutableSet()
        for (i in 0 until subs.length()) {
            val s = subs.optJSONObject(i) ?: continue
            val url = s.optString("url").takeIf { it.isNotBlank() } ?: continue
            if (!have.add(url)) continue
            val lang = s.optString("lang").takeIf { it.isNotBlank() }
            val label = s.optString("label").takeIf { it.isNotBlank() }
            val local = store.fetch("sub${list.length()}", url, lang, label, ua) ?: continue
            list.put(JSONObject().put("file", local.file.absolutePath).put("url", url).put("lang", lang).put("label", label))
            if (!dir.exists()) return // deleted meanwhile
            File(dir, "subs.json").writeText(list.toString())
        }
    }

    /** {<id>: {status, received, total, reason}} for every tracked download. */
    fun status(): String {
        val out = JSONObject()
        val ids = prefs.all.keys.filter { !it.startsWith("ua:") }
        val byDm = HashMap<Long, String>()
        ids.forEach { id -> record(id)?.optLong("dmId", -1)?.takeIf { it >= 0 }?.let { byDm[it] = id } }
        if (byDm.isNotEmpty()) {
            dm.query(DownloadManager.Query().setFilterById(*byDm.keys.toLongArray()))?.use { c ->
                val iId = c.getColumnIndex(DownloadManager.COLUMN_ID)
                val iStatus = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
                val iGot = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val iTotal = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                val iReason = c.getColumnIndex(DownloadManager.COLUMN_REASON)
                while (c.moveToNext()) {
                    val id = byDm[c.getLong(iId)] ?: continue
                    val st = when (c.getInt(iStatus)) {
                        DownloadManager.STATUS_SUCCESSFUL -> "done"
                        DownloadManager.STATUS_FAILED -> "error"
                        DownloadManager.STATUS_PAUSED -> "waiting"
                        DownloadManager.STATUS_PENDING -> "pending"
                        else -> "downloading"
                    }
                    val total = c.getLong(iTotal)
                    out.put(id, JSONObject()
                        .put("subs", dirFor(id)?.let { readSubs(it).length() } ?: 0)
                        .put("status", st)
                        .put("received", c.getLong(iGot))
                        .put("total", if (total > 0) total else JSONObject.NULL)
                        .put("reason", reasonText(c.getInt(iStatus), c.getInt(iReason))))
                    byDm.remove(c.getLong(iId))
                }
            }
        }
        // Removed from the system download list (e.g. cleared from the notification).
        byDm.values.forEach { id -> out.put(id, JSONObject().put("status", "missing")) }
        return out.toString()
    }

    private fun reasonText(status: Int, reason: Int): String = when (status) {
        DownloadManager.STATUS_PAUSED -> when (reason) {
            DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "بانتظار الإنترنت"
            DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "بانتظار الواي فاي"
            DownloadManager.PAUSED_WAITING_TO_RETRY -> "إعادة المحاولة…"
            else -> "متوقف مؤقتاً"
        }
        DownloadManager.STATUS_FAILED -> when (reason) {
            DownloadManager.ERROR_INSUFFICIENT_SPACE -> "المساحة ما تكفي"
            DownloadManager.ERROR_HTTP_DATA_ERROR, DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "الرابط رفض التحميل"
            DownloadManager.ERROR_CANNOT_RESUME -> "انقطع التحميل وما يقدر يكمل"
            DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "تحويلات كثيرة"
            else -> if (reason in 400..599) "الخادم رد بخطأ $reason" else "فشل التحميل"
        }
        else -> ""
    }

    /** Cancel and/or delete for good: the video, its subtitles and the folder. */
    fun delete(id: String): Boolean {
        record(id)?.optLong("dmId", -1)?.takeIf { it >= 0 }?.let { try { dm.remove(it) } catch (_: Exception) {} }
        dirFor(id)?.deleteRecursively()
        prefs.edit().remove(id).remove("ua:$id").apply()
        return true
    }

    /** Local files for offline playback: {video: "file://…", subtitles: [{url, lang, label}]} */
    fun files(id: String): String {
        val out = JSONObject()
        val dir = dirFor(id) ?: return out.toString()
        val file = record(id)?.optString("file")?.let { File(dir, it) }
        val video = file?.takeIf { it.exists() } ?: dir.listFiles()?.filter { it.isFile && it.name != "subs.json" }?.maxByOrNull { it.length() }
        if (video != null) out.put("video", Uri.fromFile(video).toString())
        val subs = JSONArray()
        File(dir, "subs.json").takeIf { it.exists() }?.let { f ->
            val arr = try { JSONArray(f.readText()) } catch (_: Exception) { JSONArray() }
            for (i in 0 until arr.length()) {
                val s = arr.optJSONObject(i) ?: continue
                val sf = File(s.optString("file"))
                if (!sf.exists()) continue
                subs.put(JSONObject().put("url", Uri.fromFile(sf).toString()).put("lang", s.opt("lang")).put("label", s.opt("label")))
            }
        }
        out.put("subtitles", subs)
        return out.toString()
    }

    /** Free space on the downloads volume and how much Harbor's downloads use. */
    fun storage(): String {
        val r = root() ?: return JSONObject().toString()
        r.mkdirs()
        val free = try { StatFs(r.absolutePath).availableBytes } catch (_: Exception) { -1L }
        val used = r.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        return JSONObject().put("free", free).put("used", used).toString()
    }
}

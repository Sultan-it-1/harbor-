package app.harbor.android

import android.content.pm.ActivityInfo
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.annotation.SuppressLint
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.widget.Toast
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Full-screen ExoPlayer overlay on top of the WebView. Audio formats the phone can't
 * decode in hardware (AC3, E-AC3, DTS, TrueHD) go through the bundled FFmpeg decoder.
 * State is streamed to the web UI so resume points, Stremio sync and auto-next keep working.
 */
@OptIn(UnstableApi::class)
class NativePlayer(
    private val activity: MainActivity,
    private val root: FrameLayout,
    private val emit: (String) -> Unit,
) {
    var userAgent: String = "HarborAndroid"
    private var player: ExoPlayer? = null
    private var view: PlayerView? = null
    private var source: JSONObject? = null
    private var droppedSubs = false
    private val handler = Handler(Looper.getMainLooper())
    // Pinch out = fill the screen (crop), pinch in = fit the whole picture. Kept across videos.
    private var resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
    private var pinched = false
    private val ticker = object : Runnable {
        override fun run() {
            sendState()
            handler.postDelayed(this, 1000)
        }
    }

    // Side-loaded subtitles (addon results), downloaded to local files first.
    private val subStore = SubtitleStore(activity)
    private val subPool = Executors.newFixedThreadPool(4)
    private val subs = ArrayList<SubtitleStore.LocalSub>()
    private val knownSubUrls = HashSet<String>()
    private var prefSubLangs: List<String> = emptyList()
    private var generation = 0
    private var subSeq = 0
    private var autoSelectPending = false
    private var keepSelectedSubId: String? = null
    private var subStyle = SubStyle()
    private var subDelayMs = 0L
    private var effectiveSubs: List<SubtitleStore.LocalSub> = emptyList()
    private var overlay: List<View> = emptyList()

    val isShowing: Boolean get() = view?.visibility == View.VISIBLE

    fun play(sourceJson: String) {
        val src = try { JSONObject(sourceJson) } catch (_: Exception) { return }
        generation++
        source = src
        droppedSubs = false
        subs.clear()
        knownSubUrls.clear()
        subStore.clear()
        prefSubLangs = jsonStrings(src.optJSONArray("prefSubLangs"))
        subStyle = SubStyle.load(activity) ?: SubStyle.fromHarbor(src.optJSONObject("subStyle"))
        subDelayMs = 0
        effectiveSubs = emptyList()
        keepSelectedSubId = null
        start(src, src.optLong("startMs", 0))
        // Subtitles that came with the stream itself: fetch them and attach once ready.
        addSubs(src.optJSONArray("subtitles"))
    }

    /** {cmd:"addSubs", subs:[{url,lang,label}], prefLangs:[...]} — batched by the JS bridge. */
    private fun addSubs(arr: JSONArray?) {
        val src = source ?: return
        if (arr == null || arr.length() == 0 || src.optBoolean("isLive")) return
        val gen = generation
        val jobs = ArrayList<java.util.concurrent.Future<SubtitleStore.LocalSub?>>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val url = o.optString("url").takeIf { it.isNotBlank() } ?: continue
            if (!knownSubUrls.add(url)) continue
            val id = "s${++subSeq}"
            val lang = o.optString("lang").takeIf { it.isNotBlank() }
            val label = o.optString("label").takeIf { it.isNotBlank() }
            val ua = userAgent
            jobs.add(subPool.submit<SubtitleStore.LocalSub?> { subStore.fetch(id, url, lang, label, ua) })
        }
        if (jobs.isEmpty()) return
        // Wait on a separate thread: blocking inside subPool could starve the downloads.
        Thread {
            val got = jobs.mapNotNull { f -> try { f.get(20, TimeUnit.SECONDS) } catch (_: Exception) { null } }
            handler.post {
                if (gen != generation) return@post
                if (got.isEmpty()) {
                    toast("تعذّر تحميل الترجمات (${jobs.size})")
                    return@post
                }
                subs.addAll(got)
                effectiveSubs = effectiveSubs + got.map { if (subDelayMs != 0L) subStore.shifted(it, subDelayMs) else it }
                toast("تمت إضافة ${got.size} ترجمة — اضغط CC للاختيار")
                reloadWithSubs()
            }
        }.start()
    }

    /** Re-prepares the current item with the side-loaded subtitles, keeping position and play state. */
    private fun reloadWithSubs() {
        val p = player ?: return
        val src = source ?: return
        if (droppedSubs) return
        val pos = p.currentPosition
        val playing = p.playWhenReady
        keepSelectedSubId = selectedSideSubId(p)
        p.setMediaItem(buildItem(src, withSubs = true), pos)
        p.prepare()
        p.playWhenReady = playing
        applySubPrefs(p)
        autoSelectPending = true
    }

    /** After addon subs are attached: if nothing is showing yet, pick the best one in the
     *  user's preferred language (embedded tracks in that language win via applySubPrefs). */
    private fun maybeAutoSelectSub(tracks: Tracks) {
        if (!autoSelectPending) return
        val p = player ?: return
        val textGroups = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
        if (textGroups.isEmpty()) return
        autoSelectPending = false
        val keep = keepSelectedSubId?.let { id -> subs.firstOrNull { it.id == id } }
        keepSelectedSubId = null
        if (keep == null && textGroups.any { it.isSelected }) return
        val best = keep ?: prefSubLangs.firstNotNullOfOrNull { pref ->
            subs.firstOrNull { s -> s.lang != null && baseLang(s.lang) == baseLang(pref) }
        } ?: return
        for (g in textGroups) {
            for (i in 0 until g.length) {
                val id = g.getTrackFormat(i).id ?: continue
                if (id == best.id || id.endsWith(":${best.id}")) {
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
                        .build()
                    return
                }
            }
        }
    }

    /** Our id ("s12") of the side-loaded subtitle currently shown, if any. */
    private fun selectedSideSubId(p: ExoPlayer): String? {
        for (g in p.currentTracks.groups) {
            if (g.type != C.TRACK_TYPE_TEXT) continue
            for (i in 0 until g.length) {
                if (!g.isTrackSelected(i)) continue
                val id = g.getTrackFormat(i).id ?: continue
                subs.firstOrNull { id == it.id || id.endsWith(":${it.id}") }?.let { return it.id }
            }
        }
        return null
    }

    private fun setSubDelay(ms: Long) {
        if (subs.isEmpty()) {
            toast("ما فيه ترجمات إضافات — التأخير ما يشتغل على الترجمة المدمجة")
            return
        }
        subDelayMs = ms.coerceIn(-600_000, 600_000)
        val delay = subDelayMs
        val gen = generation
        val snapshot = subs.toList()
        Thread {
            val shifted = snapshot.map { subStore.shifted(it, delay) }
            handler.post {
                if (gen != generation || delay != subDelayMs) return@post
                effectiveSubs = shifted
                reloadWithSubs()
            }
        }.start()
    }

    /** Switch the panel to the best refresh rate for this video's frame rate. */
    private fun matchRefreshToVideo() {
        val fps = player?.videoFormat?.frameRate ?: return
        if (fps > 1f) RefreshRate.apply(activity, fps)
    }

    private fun baseLang(l: String) = l.lowercase().substringBefore('-').substringBefore('_')

    private fun toast(msg: String) = Toast.makeText(activity, msg, Toast.LENGTH_SHORT).show()

    private fun applySubPrefs(p: ExoPlayer) {
        if (prefSubLangs.isEmpty()) return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setPreferredTextLanguages(*prefSubLangs.toTypedArray())
            .build()
    }

    private fun buildItem(src: JSONObject, withSubs: Boolean): MediaItem {
        val url = src.getString("url")
        val item = MediaItem.Builder().setUri(url)
        val lower = url.lowercase()
        if (lower.contains(".m3u8") || lower.contains("/hlsv2/")) item.setMimeType(MimeTypes.APPLICATION_M3U8)
        else if (lower.contains(".mpd")) item.setMimeType(MimeTypes.APPLICATION_MPD)
        if (withSubs && effectiveSubs.isNotEmpty()) {
            item.setSubtitleConfigurations(
                effectiveSubs.map { s ->
                    MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(s.file))
                        .setMimeType(s.mime)
                        // No language on purpose: the player menu shows the language *instead of*
                        // the label when both are set, and every addon sub would read just "English".
                        .setLabel(s.label ?: s.lang ?: "Subtitle")
                        .setId(s.id)
                        .build()
                },
            )
        }
        return item.build()
    }

    private fun start(src: JSONObject, startMs: Long) {
        releasePlayer()
        val ctx = activity
        val headers = HashMap<String, String>()
        src.optJSONObject("headers")?.let { h -> h.keys().forEach { k -> headers[k] = h.getString(k) } }
        val ua = headers.remove("User-Agent") ?: headers.remove("user-agent") ?: userAgent
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(ua)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(20_000)
            .setReadTimeoutMs(30_000)
            .setDefaultRequestProperties(headers)
        val dataSource = DefaultDataSource.Factory(ctx, http)
        val renderers = DefaultRenderersFactory(ctx)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            // Hardware MediaCodec decoders first (FFmpeg is only used for audio the phone
            // can't decode); asynchronous queueing keeps high-bitrate 4K/HEVC smooth.
            .setEnableDecoderFallback(true)
            .forceEnableMediaCodecAsynchronousQueueing()
        val p = ExoPlayer.Builder(ctx, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()

        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) emit(JSONObject().put("type", "ended").toString())
                sendState()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                matchRefreshToVideo()
                sendState()
            }
            override fun onTracksChanged(tracks: Tracks) {
                matchRefreshToVideo()
                maybeAutoSelectSub(tracks)
            }

            override fun onPlayerError(error: PlaybackException) {
                // A subtitle ExoPlayer can't parse would fail the whole playback; retry once without them.
                val cur = source
                if (cur != null && !droppedSubs && subs.isNotEmpty()) {
                    droppedSubs = true
                    val pos = player?.currentPosition ?: 0
                    handler.post {
                        player?.let { pl ->
                            pl.setMediaItem(buildItem(cur, withSubs = false), pos)
                            pl.prepare()
                            pl.playWhenReady = true
                        }
                    }
                    return
                }
                emit(
                    JSONObject()
                        .put("type", "error")
                        .put("code", errorCode(error))
                        .put("message", error.errorCodeName + ": " + (error.message ?: ""))
                        .toString(),
                )
            }
        })
        p.setMediaItem(buildItem(src, withSubs = true), startMs.coerceAtLeast(0))
        applySubPrefs(p)
        p.prepare()
        p.playWhenReady = true
        player = p
        show(p)
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    private fun jsonStrings(a: JSONArray?): List<String> {
        if (a == null) return emptyList()
        return (0 until a.length()).mapNotNull { a.optString(it).takeIf { s -> s.isNotBlank() } }
    }

    private fun show(p: ExoPlayer) {
        val v = view ?: PlayerView(activity).also { pv ->
            pv.setBackgroundColor(Color.BLACK)
            pv.setShowSubtitleButton(true)
            pv.setShowNextButton(false)
            pv.setShowPreviousButton(false)
            pv.keepScreenOn = true
            pv.resizeMode = resizeMode
            attachPinch(pv)
            root.addView(pv, FrameLayout.LayoutParams(MainActivity.MATCH, MainActivity.MATCH))
            view = pv
        }
        v.player = p
        v.visibility = View.VISIBLE
        v.bringToFront()
        subStyle.applyTo(v.subtitleView)
        if (overlay.isEmpty()) overlay = buildOverlay(v)
        overlay.forEach { it.bringToFront() }
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        activity.setFullscreenMode(true)
    }

    /** Top-bar buttons over the player: ✕ (close) and Aa (subtitle settings); they follow the controls. */
    private fun buildOverlay(pv: PlayerView): List<View> {
        val dp = activity.resources.displayMetrics.density
        fun chip(text: String, gravity: Int, onClick: () -> Unit) = android.widget.TextView(activity).apply {
            this.text = text
            setTextColor(Color.WHITE)
            textSize = 17f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            this.gravity = android.view.Gravity.CENTER
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = 999f
                setColor(Color.argb(110, 0, 0, 0))
            }
            setOnClickListener { onClick() }
            root.addView(this, FrameLayout.LayoutParams((48 * dp).toInt(), (48 * dp).toInt(), gravity).apply {
                setMargins((16 * dp).toInt(), (16 * dp).toInt(), (16 * dp).toInt(), (16 * dp).toInt())
            })
        }
        val close = chip("✕", android.view.Gravity.TOP or android.view.Gravity.START) { close() }
        val subsBtn = chip("Aa", android.view.Gravity.TOP or android.view.Gravity.END) {
            SubtitleControls(
                activity,
                subStyle,
                onStyle = { subStyle.applyTo(view?.subtitleView) },
                getDelayMs = { subDelayMs },
                onDelay = { setSubDelay(it) },
            ).show()
        }
        val views = listOf(close, subsBtn)
        pv.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { vis ->
            views.forEach { it.visibility = if (view?.visibility == View.VISIBLE) vis else View.GONE }
        })
        return views
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachPinch(pv: PlayerView) {
        var gestureScale = 1f
        val detector = ScaleGestureDetector(activity, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(d: ScaleGestureDetector): Boolean {
                gestureScale = 1f
                pinched = true
                return true
            }

            override fun onScale(d: ScaleGestureDetector): Boolean {
                gestureScale *= d.scaleFactor
                val want = when {
                    gestureScale > 1.08f -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    gestureScale < 0.92f -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                    else -> return true
                }
                if (want != resizeMode) {
                    resizeMode = want
                    pv.resizeMode = want
                    Toast.makeText(
                        activity,
                        if (want == AspectRatioFrameLayout.RESIZE_MODE_ZOOM) "ملء الشاشة" else "الحجم الأصلي",
                        Toast.LENGTH_SHORT,
                    ).show()
                }
                return true
            }
        })
        pv.setOnTouchListener { _, ev ->
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) pinched = false
            detector.onTouchEvent(ev)
            // Swallow the two-finger gesture (and its final lift) so it doesn't toggle the controls.
            pinched || ev.pointerCount > 1
        }
    }

    fun command(json: String) {
        val p = player ?: return
        val c = try { JSONObject(json) } catch (_: Exception) { return }
        when (c.optString("cmd")) {
            "play" -> p.play()
            "pause" -> p.pause()
            "seek" -> p.seekTo(c.optLong("ms", 0).coerceAtLeast(0))
            "rate" -> p.setPlaybackSpeed(c.optDouble("rate", 1.0).toFloat().coerceIn(0.25f, 4f))
            "volume" -> p.volume = c.optDouble("volume", 1.0).toFloat().coerceIn(0f, 1f)
            "subSearch" -> if (c.optInt("count", 0) == 0) toast("ما لقيت ترجمات من الإضافات لهذا الفيديو")
            "addSubs" -> {
                val langs = jsonStrings(c.optJSONArray("prefLangs"))
                if (langs.isNotEmpty()) prefSubLangs = langs
                addSubs(c.optJSONArray("subs"))
            }
        }
        sendState()
    }

    /** User closed the player with the back button: tell the web UI to leave the player view. */
    fun close() = stop(notify = true)

    fun stop(notify: Boolean) {
        val p = player
        if (notify && p != null) {
            sendState()
            emit(
                JSONObject()
                    .put("type", "closed")
                    .put("positionMs", p.currentPosition)
                    .put("durationMs", if (p.duration == C.TIME_UNSET) 0 else p.duration)
                    .toString(),
            )
        }
        releasePlayer()
        source = null
        generation++
        view?.let {
            it.player = null
            it.visibility = View.GONE
        }
        overlay.forEach { it.visibility = View.GONE }
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        activity.setFullscreenMode(false)
        RefreshRate.apply(activity)
    }

    fun onHostPause() {
        player?.pause()
    }

    private fun releasePlayer() {
        handler.removeCallbacks(ticker)
        player?.release()
        player = null
    }

    private fun sendState() {
        val p = player ?: return
        val dur = if (p.duration == C.TIME_UNSET) 0 else p.duration
        val vs = p.videoSize
        emit(
            JSONObject()
                .put("type", "state")
                .put("positionMs", p.currentPosition)
                .put("durationMs", dur)
                .put("bufferedMs", p.bufferedPosition)
                .put("playing", p.isPlaying)
                .put("playWhenReady", p.playWhenReady)
                .put("buffering", p.playbackState == Player.STATE_BUFFERING)
                .put("ended", p.playbackState == Player.STATE_ENDED)
                .put("ready", p.playbackState == Player.STATE_READY)
                .put("rate", p.playbackParameters.speed.toDouble())
                .put("width", vs.width)
                .put("height", vs.height)
                .toString(),
        )
    }

    private fun errorCode(e: PlaybackException): String = when (e.errorCode) {
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> "decode"
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> "codec"
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE -> "network"
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED -> "source"
        else -> "unknown"
    }
}

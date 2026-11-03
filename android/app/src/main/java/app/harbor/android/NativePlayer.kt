package app.harbor.android

import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.DefaultTimeBar
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Full-screen ExoPlayer overlay on top of the WebView. Audio formats the phone can't
 * decode in hardware (AC3, E-AC3, DTS, TrueHD) go through the bundled FFmpeg decoder.
 * State is streamed to the web UI so resume points, Stremio sync and auto-next keep working.
 *
 * On top of Media3's controls it adds: gestures (double-tap seek, brightness/volume/seek
 * swipes, pinch), a top bar (title, streams, subtitles, audio, aspect, lock), a next-episode
 * button, and side panels for streams, subtitles (embedded + addon, grouped by language,
 * own renderer with instant delay) and audio/speed.
 *
 * Subtitles saved with a download are listed on their own and are all that shows offline;
 * online, every addon subtitle shows too, each with a button that saves it with the download.
 */
@OptIn(UnstableApi::class)
class NativePlayer(
    private val activity: MainActivity,
    private val root: FrameLayout,
    private val downloads: Downloads,
    private val emit: (String) -> Unit,
) {
    var userAgent: String = "HarborAndroid"
    private var player: ExoPlayer? = null
    private var view: PlayerView? = null
    private var source: JSONObject? = null
    private val handler = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            sendState()
            handler.postDelayed(this, 1000)
        }
    }

    // ---- what's playing --------------------------------------------------------------------
    private var contentKey = ""
    private var title = ""
    private var subtitleLine = ""
    private var hasNext = false
    private var resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
    private var locked = false

    // ---- subtitles -------------------------------------------------------------------------
    /** A subtitle the user can pick; downloaded only when picked. For one saved with a
     *  download, url is the local file and src the address it was saved from. */
    private data class CatalogSub(val id: String, val url: String, val lang: String?, val label: String, val src: String = url)

    private val subStore = SubtitleStore(activity)
    private val subPool = Executors.newFixedThreadPool(3)
    private val catalog = ArrayList<CatalogSub>()
    private val catalogUrls = HashSet<String>()
    private val parsed = HashMap<String, List<CuesWithTiming>>()
    private val loading = HashSet<String>()
    private var subSeq = 0
    private var prefSubLangs: List<String> = emptyList()
    private var activeExtId: String? = null
    private var subsOff = false
    private var userPickedSub = false
    private var autoSubDone = false
    private var searching = false
    private var subStyle = SubStyle()
    private var shownLangs: MutableSet<String>? = null
    private var extView: SubtitleView? = null
    private var ext: ExternalSubs? = null
    /** The download of what's playing (when there is one): its saved subtitles, and where the
     *  save button puts new ones. */
    private var downloadId: String? = null
    private val saved = ArrayList<CatalogSub>()
    private val saving = HashSet<String>()

    // ---- chrome ----------------------------------------------------------------------------
    private var topBar: LinearLayout? = null
    private var titleView: TextView? = null
    private var subtitleView: TextView? = null
    private var nextButton: View? = null
    private var unlockButton: View? = null
    private var indicator: LinearLayout? = null
    private var indicatorIcon: ImageView? = null
    private var indicatorText: TextView? = null
    private var controllerVisible = false
    private var panel: SidePanel? = null
    private var panelKind = ""
    private var streamsPayload: JSONObject? = null
    private var pickingStream: String? = null
    private var streamQuality = "all"
    private var brightnessTouched = false

    val isShowing: Boolean get() = view?.visibility == View.VISIBLE

    // =========================================================================================
    // Playback
    // =========================================================================================

    fun play(sourceJson: String) {
        val src = try { JSONObject(sourceJson) } catch (_: Exception) { return }
        val key = src.optString("contentKey", "")
        if (key.isNotEmpty() && key != contentKey) {
            // A different title/episode: forget subtitles from the previous one.
            contentKey = key
            catalog.clear(); catalogUrls.clear(); parsed.clear(); loading.clear()
            saved.clear(); saving.clear()
            subStore.clear()
            activeExtId = null; subsOff = false; userPickedSub = false; autoSubDone = false
            ext?.delayMs = 0
            ext?.clear()
            // title / episode line / next-episode come from the "meta" command, which can
            // arrive before this play() — don't wipe them here.
        }
        source = src
        downloadId = src.optString("downloadId").takeIf { it.isNotBlank() }
        loadSaved()
        src.optString("title").takeIf { it.isNotBlank() }?.let { title = it }
        prefSubLangs = jsonStrings(src.optJSONArray("prefSubLangs")).ifEmpty { prefSubLangs }
        subStyle = SubStyle.load(activity) ?: SubStyle.fromHarbor(src.optJSONObject("subStyle"))
        if (pickingStream != null) {
            pickingStream = null
            panel?.dismiss()
            toast("تم تبديل المصدر")
        }
        start(src, src.optLong("startMs", 0))
        addToCatalog(src.optJSONArray("subtitles"))
    }

    private fun buildItem(src: JSONObject): MediaItem {
        val url = src.getString("url")
        val item = MediaItem.Builder().setUri(url)
        val lower = url.lowercase()
        if (lower.contains(".m3u8") || lower.contains("/hlsv2/")) item.setMimeType(MimeTypes.APPLICATION_M3U8)
        else if (lower.contains(".mpd")) item.setMimeType(MimeTypes.APPLICATION_MPD)
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
            .setSeekBackIncrementMs(10_000)
            .setSeekForwardIncrementMs(10_000)
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
                maybeAutoSelectSub()
                if (panel?.isOpen == true && (panelKind == "subs" || panelKind == "audio")) refreshPanel()
            }

            override fun onPlayerError(error: PlaybackException) {
                emit(
                    JSONObject()
                        .put("type", "error")
                        .put("code", errorCode(error))
                        .put("message", error.errorCodeName + ": " + (error.message ?: ""))
                        .toString(),
                )
            }
        })
        p.setMediaItem(buildItem(src), startMs.coerceAtLeast(0))
        applyTextSelection(p)
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

    /** Switch the panel to the best refresh rate for this video's frame rate. */
    private fun matchRefreshToVideo() {
        val fps = player?.videoFormat?.frameRate ?: return
        if (fps > 1f) RefreshRate.apply(activity, fps)
    }

    // =========================================================================================
    // View + chrome
    // =========================================================================================

    private fun show(p: ExoPlayer) {
        val v = view ?: createView()
        v.player = p
        v.visibility = View.VISIBLE
        v.bringToFront()
        subStyle.applyTo(v.subtitleView)
        subStyle.applyTo(extView)
        listOfNotNull(topBar, nextButton, indicator, unlockButton).forEach { it.bringToFront() }
        updateChrome()
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        activity.setFullscreenMode(true)
    }

    private fun createView(): PlayerView {
        val pv = PlayerView(activity)
        pv.setBackgroundColor(Color.BLACK)
        pv.setShowSubtitleButton(false) // our own subtitle panel replaces it
        pv.setShowNextButton(false)
        pv.setShowPreviousButton(false)
        pv.setShowFastForwardButton(true)
        pv.setShowRewindButton(true)
        pv.keepScreenOn = true
        pv.resizeMode = resizeMode
        pv.controllerShowTimeoutMs = 3500
        root.addView(pv, FrameLayout.LayoutParams(MainActivity.MATCH, MainActivity.MATCH))
        view = pv

        // Accent-coloured seek bar, like the rest of the app.
        pv.findViewById<DefaultTimeBar>(androidx.media3.ui.R.id.exo_progress)?.apply {
            setPlayedColor(HarborColors.ACCENT)
            setScrubberColor(HarborColors.ACCENT)
            setBufferedColor(Color.argb(110, 255, 255, 255))
        }

        // Addon subtitles render in their own view above the video, below the controls.
        val sv = SubtitleView(activity)
        (pv.overlayFrameLayout ?: pv).addView(sv, FrameLayout.LayoutParams(MainActivity.MATCH, MainActivity.MATCH))
        extView = sv
        ext = ExternalSubs(sv) { player?.currentPosition }

        pv.setOnTouchListener(PlayerGestures(activity, gestureCallbacks))
        pv.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { vis ->
            controllerVisible = vis == View.VISIBLE
            updateChrome()
        })
        buildTopBar()
        buildNextButton()
        buildIndicator()
        buildUnlockButton()
        return pv
    }

    private fun buildTopBar() {
        val ctx = activity
        val bar = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ctx.dp(20), ctx.dp(14), ctx.dp(20), ctx.dp(28))
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(Color.argb(170, 0, 0, 0), Color.TRANSPARENT))
        }
        bar.addView(ctx.iconButton(R.drawable.ic_arrow_left, "رجوع") { close() }.apply {
            (layoutParams as LinearLayout.LayoutParams).marginStart = 0
        })
        val texts = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ctx.dp(12), 0, ctx.dp(8), 0)
        }
        titleView = ctx.label("", 16f, bold = true, lines = 1).also { texts.addView(it) }
        subtitleView = ctx.label("", 12.5f, HarborColors.MUTED, lines = 1).also { texts.addView(it) }
        bar.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(ctx.iconButton(R.drawable.ic_layers, "المصادر") { openStreams() })
        bar.addView(ctx.iconButton(R.drawable.ic_captions, "الترجمة") { openSubs("tracks") })
        bar.addView(ctx.iconButton(R.drawable.ic_audio_lines, "الصوت والسرعة") { openAudio() })
        bar.addView(ctx.iconButton(R.drawable.ic_scan, "حجم الصورة") { cycleResize() })
        bar.addView(ctx.iconButton(R.drawable.ic_lock, "قفل الشاشة") { setLocked(true) })
        root.addView(bar, FrameLayout.LayoutParams(MainActivity.MATCH, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        topBar = bar
    }

    private fun buildNextButton() {
        val ctx = activity
        val b = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(ctx.dp(16), 0, ctx.dp(18), 0)
            background = rounded(Color.WHITE, 999f)
            isClickable = true
            setOnClickListener { emit(JSONObject().put("type", "next").toString()) }
            addView(ctx.icon(R.drawable.ic_skip_forward, 18, Color.BLACK).apply {
                layoutParams = LinearLayout.LayoutParams(ctx.dp(18), ctx.dp(18)).apply { marginEnd = ctx.dp(8) }
            })
            addView(ctx.label("الحلقة التالية", 14f, Color.BLACK, bold = true))
        }
        root.addView(b, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ctx.dp(42), Gravity.BOTTOM or Gravity.END).apply {
            setMargins(0, 0, ctx.dp(28), ctx.dp(96))
        })
        nextButton = b
    }

    private fun buildIndicator() {
        val ctx = activity
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(ctx.dp(18), ctx.dp(12), ctx.dp(20), ctx.dp(12))
            background = rounded(Color.argb(175, 0, 0, 0), 999f)
            visibility = View.GONE
        }
        indicatorIcon = ctx.icon(R.drawable.ic_sun, 22).also {
            it.layoutParams = LinearLayout.LayoutParams(ctx.dp(22), ctx.dp(22)).apply { marginEnd = ctx.dp(10) }
            box.addView(it)
        }
        indicatorText = ctx.label("", 17f, bold = true).also { box.addView(it) }
        root.addView(box, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        indicator = box
    }

    private fun buildUnlockButton() {
        val ctx = activity
        val b = ctx.iconButton(R.drawable.ic_lock_open, "فتح القفل") { setLocked(false) }.apply {
            background = rounded(Color.argb(150, 0, 0, 0), 999f)
            visibility = View.GONE
        }
        root.addView(b, FrameLayout.LayoutParams(ctx.dp(56), ctx.dp(56), Gravity.CENTER_VERTICAL or Gravity.START).apply {
            marginStart = ctx.dp(32)
        })
        unlockButton = b
    }

    private val hideIndicator = Runnable { indicator?.visibility = View.GONE }
    private val hideUnlock = Runnable { if (locked) unlockButton?.visibility = View.GONE }

    private fun flash(iconRes: Int, text: String, gravity: Int = Gravity.CENTER, holdMs: Long = 700) {
        val box = indicator ?: return
        indicatorIcon?.setImageResource(iconRes)
        indicatorText?.text = text
        (box.layoutParams as FrameLayout.LayoutParams).let { lp ->
            if (lp.gravity != gravity) {
                lp.gravity = gravity
                lp.marginStart = if (gravity and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK == Gravity.START) activity.dp(72) else 0
                lp.marginEnd = if (gravity and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK == Gravity.END) activity.dp(72) else 0
                box.layoutParams = lp
            }
        }
        box.visibility = View.VISIBLE
        box.bringToFront()
        handler.removeCallbacks(hideIndicator)
        handler.postDelayed(hideIndicator, holdMs)
    }

    private fun updateChrome() {
        val showing = isShowing && !locked && controllerVisible && panel?.isOpen != true
        topBar?.visibility = if (showing) View.VISIBLE else View.GONE
        nextButton?.visibility = if (showing && hasNext) View.VISIBLE else View.GONE
        titleView?.text = title
        subtitleView?.text = subtitleLine
        subtitleView?.visibility = if (subtitleLine.isBlank()) View.GONE else View.VISIBLE
    }

    private fun setLocked(on: Boolean) {
        locked = on
        val pv = view ?: return
        pv.useController = !on
        if (on) {
            pv.hideController()
            unlockButton?.visibility = View.VISIBLE
            handler.removeCallbacks(hideUnlock)
            handler.postDelayed(hideUnlock, 2500)
            toast("الشاشة مقفلة")
        } else {
            unlockButton?.visibility = View.GONE
            pv.showController()
        }
        updateChrome()
    }

    private fun cycleResize() {
        resizeMode = when (resizeMode) {
            AspectRatioFrameLayout.RESIZE_MODE_FIT -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_FILL
            else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        }
        view?.resizeMode = resizeMode
        flash(R.drawable.ic_scan, when (resizeMode) {
            AspectRatioFrameLayout.RESIZE_MODE_ZOOM -> "ملء الشاشة"
            AspectRatioFrameLayout.RESIZE_MODE_FILL -> "تمديد"
            else -> "الحجم الأصلي"
        }, holdMs = 900)
    }

    // =========================================================================================
    // Gestures
    // =========================================================================================

    private val audio by lazy { activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager }

    private val gestureCallbacks = object : PlayerGestures.Callbacks {
        override val locked: Boolean get() = this@NativePlayer.locked || panel?.isOpen == true

        override fun onTap() {
            val pv = view ?: return
            if (pv.isControllerFullyVisible) pv.hideController() else pv.showController()
        }

        override fun onLockedTap() {
            if (panel?.isOpen == true) return
            unlockButton?.visibility = View.VISIBLE
            unlockButton?.bringToFront()
            handler.removeCallbacks(hideUnlock)
            handler.postDelayed(hideUnlock, 2500)
        }

        override fun onDoubleTapSeek(forward: Boolean, totalSec: Int) {
            val p = player ?: return
            val target = (p.currentPosition + if (forward) 10_000 else -10_000).coerceIn(0, durationOrMax(p))
            p.seekTo(target)
            flash(
                if (forward) R.drawable.ic_fast_forward else R.drawable.ic_rewind,
                (if (forward) "+" else "−") + "$totalSec ث",
                (if (forward) Gravity.END else Gravity.START) or Gravity.CENTER_VERTICAL,
            )
        }

        override fun onDoubleTapCenter() {
            val p = player ?: return
            if (p.isPlaying) p.pause() else p.play()
            flash(if (p.playWhenReady) R.drawable.ic_play else R.drawable.ic_pause, if (p.playWhenReady) "تشغيل" else "إيقاف مؤقت")
        }

        override fun onBrightnessStart(): Float {
            val cur = activity.window.attributes.screenBrightness
            if (cur >= 0) return cur
            return try {
                Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
            } catch (_: Exception) {
                0.5f
            }
        }

        override fun onBrightness(value: Float) {
            brightnessTouched = true
            val a = activity.window.attributes
            a.screenBrightness = value.coerceIn(0.01f, 1f)
            activity.window.attributes = a
            flash(R.drawable.ic_sun, "${(value * 100).toInt()}%", holdMs = 600)
        }

        override fun onVolumeStart(): Float {
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max
        }

        override fun onVolume(value: Float) {
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * max).toInt().coerceIn(0, max), 0)
            flash(if (value <= 0.001f) R.drawable.ic_volume_x else R.drawable.ic_volume_2, "${(value * 100).toInt()}%", holdMs = 600)
        }

        override fun onSeekPreview(deltaMs: Long) {
            val p = player ?: return
            val target = (p.currentPosition + deltaMs).coerceIn(0, durationOrMax(p))
            flash(
                if (deltaMs >= 0) R.drawable.ic_fast_forward else R.drawable.ic_rewind,
                "${if (deltaMs >= 0) "+" else "−"}${formatTime(kotlin.math.abs(deltaMs))}  ·  ${formatTime(target)}",
                holdMs = 900,
            )
        }

        override fun onSeekCommit(deltaMs: Long) {
            val p = player ?: return
            if (kotlin.math.abs(deltaMs) < 1000) return
            p.seekTo((p.currentPosition + deltaMs).coerceIn(0, durationOrMax(p)))
        }

        override fun onPinch(zoomIn: Boolean) {
            val want = if (zoomIn) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
            if (want == resizeMode) return
            resizeMode = want
            view?.resizeMode = want
            flash(R.drawable.ic_scan, if (zoomIn) "ملء الشاشة" else "الحجم الأصلي", holdMs = 900)
        }

        override fun onGestureEnd() {}
    }

    private fun durationOrMax(p: ExoPlayer) = if (p.duration == C.TIME_UNSET) Long.MAX_VALUE else p.duration

    private fun formatTime(ms: Long): String {
        val s = ms / 1000
        val h = s / 3600
        val m = s / 60 % 60
        val sec = s % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, sec) else String.format(Locale.US, "%d:%02d", m, sec)
    }

    // =========================================================================================
    // Panels
    // =========================================================================================

    private fun openPanel(kind: String, titleText: String): SidePanel {
        panel?.dismiss()
        val p = SidePanel(activity, root, titleText) {
            if (panel?.isOpen != true) {
                panelKind = ""
                updateChrome()
            }
        }
        panel = p
        panelKind = kind
        view?.hideController()
        updateChrome()
        p.show()
        return p
    }

    private fun refreshPanel() {
        when (panelKind) {
            "streams" -> renderStreams()
            "subs" -> renderSubs(subsTab)
            "audio" -> renderAudio()
        }
    }

    /** Back gesture: close a panel / unlock first. Returns true when handled. */
    fun handleBack(): Boolean {
        if (panel?.isOpen == true) { panel?.dismiss(); return true }
        if (locked) { setLocked(false); return true }
        return false
    }

    // ---- streams ---------------------------------------------------------------------------

    private fun openStreams() {
        openPanel("streams", "المصادر")
        streamsPayload = null
        renderStreams()
        emit(JSONObject().put("type", "requestStreams").toString())
    }

    private fun renderStreams() {
        val p = panel ?: return
        p.clear()
        val data = streamsPayload
        if (data == null) {
            p.row("جارٍ جلب المصادر…", null, loading = true, onClick = null)
            return
        }
        val items = data.optJSONArray("items") ?: JSONArray()
        if (items.length() == 0) {
            p.note(data.optString("message").ifBlank { "ما فيه مصادر ثانية لهذا العنوان." })
            return
        }
        val qualities = linkedSetOf<String>()
        for (i in 0 until items.length()) items.optJSONObject(i)?.optString("quality")?.takeIf { it.isNotBlank() }?.let { qualities.add(it) }
        if (qualities.size > 1) {
            p.chips(listOf(Triple("الكل", streamQuality == "all") { streamQuality = "all"; renderStreams() }) +
                qualities.map { q -> Triple(q, streamQuality == q) { streamQuality = q; renderStreams() } })
        }
        var shown = 0
        for (i in 0 until items.length()) {
            val it = items.optJSONObject(i) ?: continue
            if (streamQuality != "all" && it.optString("quality") != streamQuality) continue
            val key = it.optString("key")
            val cached = it.optBoolean("cached")
            val name = (if (cached) "⚡ " else "") + it.optString("name")
            val badges = it.optString("badges")
            p.row(
                name,
                it.optString("desc").takeIf { d -> d.isNotBlank() },
                badges.takeIf { b -> b.isNotBlank() },
                selected = it.optBoolean("current"),
                loading = pickingStream == key,
            ) {
                if (it.optBoolean("current") || pickingStream != null) return@row
                pickingStream = key
                renderStreams()
                emit(JSONObject().put("type", "pickStream").put("key", key).toString())
            }
            shown++
        }
        if (shown == 0) p.note("ما فيه مصادر بهذه الجودة.")
    }

    // ---- subtitles -------------------------------------------------------------------------

    private var subsTab = "tracks"

    private fun openSubs(tab: String) {
        subsTab = tab
        openPanel("subs", "الترجمة")
        renderSubs(tab)
    }

    private fun langName(code: String?): String {
        if (code.isNullOrBlank() || code.equals("und", true)) return "غير محددة"
        val loc = Locale.forLanguageTag(code)
        val name = loc.getDisplayLanguage(Locale.getDefault())
        return if (name.isNullOrBlank() || name.equals(code, true)) code.uppercase() else name.replaceFirstChar { it.titlecase() }
    }

    private fun baseLang(l: String?) = (l ?: "").lowercase().substringBefore('-').substringBefore('_')

    private fun prefRank(lang: String?): Int {
        val b = baseLang(lang)
        val i = prefSubLangs.indexOfFirst { baseLang(it) == b }
        return if (i < 0) 999 else i
    }

    private fun renderSubs(tab: String) {
        val p = panel ?: return
        subsTab = tab
        p.clear()
        p.chips(listOf(
            Triple("الترجمات", tab == "tracks") { renderSubs("tracks") },
            Triple("المظهر والتوقيت", tab == "style") { renderSubs("style") },
        ))
        if (tab == "style") {
            SubtitleControls(activity, subStyle, onStyle = { applySubStyle() }, getDelayMs = { ext?.delayMs ?: 0 }, onDelay = { setSubDelay(it) })
                .build(p, delayWorks = activeExtId != null)
            return
        }
        val pl = player
        val embeddedSelected = pl?.let { selectedEmbedded(it) }
        p.row("بدون ترجمة", selected = activeExtId == null && embeddedSelected == null) {
            userPickedSub = true
            selectOff()
        }

        // Embedded tracks.
        val embedded = pl?.let { textTracks(it) } ?: emptyList()
        if (embedded.isNotEmpty()) {
            p.section("مدمجة في الملف (${embedded.size})")
            embedded.forEach { t ->
                val f = t.group.getTrackFormat(t.index)
                val sel = activeExtId == null && t.group.isTrackSelected(t.index)
                val forced = f.selectionFlags and C.SELECTION_FLAG_FORCED != 0
                p.row(
                    f.label?.takeIf { it.isNotBlank() } ?: langName(f.language),
                    listOfNotNull(f.language?.let { langName(it) }.takeIf { f.label != null }, if (forced) "إجبارية" else null)
                        .joinToString(" · ").ifBlank { null },
                    selected = sel,
                ) {
                    userPickedSub = true
                    selectEmbedded(t)
                }
            }
        }

        // Saved with the download: local files, so they also work offline.
        if (saved.isNotEmpty()) {
            p.section("محفوظة على الجهاز (${saved.size})")
            saved.sortedBy { prefRank(it.lang) }.forEach { s ->
                p.row(
                    s.label,
                    langName(s.lang).takeIf { s.lang != null && !s.label.contains(it) },
                    selected = activeExtId == s.id,
                    loading = s.id in loading,
                ) {
                    userPickedSub = true
                    selectExternal(s)
                }
            }
        }

        // Offline: addon subtitles can't be fetched, so only the saved ones are offered.
        if (!isOnline()) {
            p.section("من الإضافات")
            p.note(
                if (saved.isEmpty()) "أنت بدون إنترنت. ترجمات الإضافات تحتاج إنترنت، وما فيه ترجمات محفوظة مع هذا الفيديو."
                else "أنت بدون إنترنت، فتظهر الترجمات المحفوظة على الجهاز فقط.",
            )
            return
        }

        // Addon subtitles, grouped by language (the saved ones aren't repeated here).
        val online = catalog.filter { !isSaved(it) }
        p.section(if (online.isEmpty()) "من الإضافات" else "من الإضافات (${online.size})")
        if (online.isEmpty()) {
            p.note(if (searching) "جارٍ البحث في الإضافات…" else "ما وصلت ترجمات من الإضافات بعد.")
        } else {
            if (downloadId != null) p.note("زر التحميل جنب كل ترجمة يحفظها مع الفيديو عشان تشتغل بدون إنترنت.")
            val byLang = online.groupBy { baseLang(it.lang).ifBlank { "und" } }
            val order = byLang.keys.sortedWith(compareBy<String>({ prefRank(it) }, { langName(it) }))
            val chosen = shownLangs ?: loadShownLangs(order).also { shownLangs = it }
            p.chips(
                listOf(Triple("الكل", chosen.containsAll(order)) {
                    shownLangs = if (chosen.containsAll(order)) mutableSetOf() else order.toMutableSet()
                    saveShownLangs(); renderSubs("tracks")
                }) + order.map { l ->
                    Triple("${langName(l)} ${byLang[l]?.size ?: 0}", l in chosen) {
                        val set = shownLangs ?: mutableSetOf()
                        if (!set.add(l)) set.remove(l)
                        shownLangs = set
                        saveShownLangs(); renderSubs("tracks")
                    }
                },
            )
            val visible = order.filter { it in chosen }
            if (visible.isEmpty()) p.note("اختر لغة من فوق عشان تظهر ترجماتها.")
            visible.forEach { l ->
                val list = byLang[l] ?: return@forEach
                p.section("${langName(l)} (${list.size})")
                list.forEach { s ->
                    val label = s.label.substringAfter(" · ", s.label)
                    p.row(
                        label,
                        selected = activeExtId == s.id,
                        loading = s.id in loading,
                        actionIcon = if (downloadId != null) R.drawable.ic_download else null,
                        actionDesc = "حفظ الترجمة مع الفيديو",
                        actionBusy = s.id in saving,
                        onAction = { saveSub(s) },
                    ) {
                        userPickedSub = true
                        selectExternal(s)
                    }
                }
            }
        }
        p.action(if (searching) "جارٍ البحث…" else "جلب ترجمات من الإضافات", R.drawable.ic_refresh_cw) {
            if (searching) return@action
            searching = true
            emit(JSONObject().put("type", "subSearch").toString())
            renderSubs("tracks")
        }
    }

    private fun loadShownLangs(order: List<String>): MutableSet<String> {
        val saved = activity.getSharedPreferences("harbor.player", Context.MODE_PRIVATE).getString("subLangs", null)
        if (saved != null) {
            val set = saved.split(',').filter { it.isNotBlank() }.toMutableSet()
            // Keep saved choices, but always show languages that are in the user's preferences.
            order.filter { prefRank(it) < 999 }.forEach { set.add(it) }
            return set
        }
        val pref = order.filter { prefRank(it) < 999 }
        return (pref.ifEmpty { order }).toMutableSet()
    }

    private fun saveShownLangs() {
        activity.getSharedPreferences("harbor.player", Context.MODE_PRIVATE).edit()
            .putString("subLangs", (shownLangs ?: emptySet()).joinToString(","))
            .apply()
    }

    // ---- saved subtitles ---------------------------------------------------------------

    private fun savedId(key: String) = "v" + Integer.toHexString(key.hashCode())

    /** Reads the subtitles saved with the current download; keeps local ones the page handed
     *  over that aren't in it (e.g. a download the page couldn't match). */
    private fun loadSaved() {
        val id = downloadId
        val list = if (id == null) emptyList() else downloads.savedSubtitles(id)
        val fromDownload = list.map { s ->
            val uri = Uri.fromFile(s.file).toString()
            val src = s.src.ifBlank { uri }
            CatalogSub(savedId(src), uri, s.lang, s.label ?: langName(s.lang), src)
        }
        val extra = saved.filter { old -> fromDownload.none { it.url == old.url } }
        saved.clear()
        saved.addAll(fromDownload)
        saved.addAll(extra)
    }

    private fun isSaved(c: CatalogSub) = saved.any { it.src == c.url || it.url == c.url }

    /** The save button on an addon subtitle: store it with the download for offline use. */
    private fun saveSub(s: CatalogSub) {
        val id = downloadId ?: return
        if (!saving.add(s.id)) return
        refreshPanel()
        val gen = contentKey
        downloads.saveSubtitle(id, s.url, s.lang, s.label.substringAfter(" · ", s.label)) { ok ->
            handler.post {
                saving.remove(s.id)
                if (gen != contentKey || downloadId != id) return@post
                if (ok) {
                    loadSaved()
                    // Showing this one right now: carry on with the saved copy.
                    saved.firstOrNull { it.src == s.url }?.let { copy ->
                        parsed[s.id]?.let { parsed[copy.id] = it }
                        if (activeExtId == s.id) activeExtId = copy.id
                    }
                    toast("انحفظت الترجمة مع الفيديو")
                } else {
                    toast("تعذّر حفظ هذه الترجمة، جرّب غيرها")
                }
                refreshPanel()
            }
        }
    }

    /** Connected with working internet (an unvalidated network counts once addons answered). */
    private fun isOnline(): Boolean {
        val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) || catalog.isNotEmpty()
    }

    private data class TextTrack(val group: Tracks.Group, val index: Int)

    private fun textTracks(p: ExoPlayer): List<TextTrack> =
        p.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
            .flatMap { g -> (0 until g.length).filter { g.isTrackSupported(it) }.map { TextTrack(g, it) } }

    private fun selectedEmbedded(p: ExoPlayer): TextTrack? =
        if (p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)) null
        else textTracks(p).firstOrNull { it.group.isTrackSelected(it.index) }

    private fun applyTextSelection(p: ExoPlayer) {
        val b = p.trackSelectionParameters.buildUpon()
        if (prefSubLangs.isNotEmpty()) b.setPreferredTextLanguages(*prefSubLangs.toTypedArray())
        b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, activeExtId != null || subsOff)
        p.trackSelectionParameters = b.build()
    }

    private fun selectOff() {
        activeExtId = null
        subsOff = true
        ext?.clear()
        player?.let { applyTextSelection(it) }
        refreshPanel()
    }

    private fun selectEmbedded(t: TextTrack) {
        activeExtId = null
        subsOff = false
        ext?.clear()
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .setOverrideForType(TrackSelectionOverride(t.group.mediaTrackGroup, t.index))
            .build()
        refreshPanel()
    }

    private fun selectExternal(s: CatalogSub, onFail: (() -> Unit)? = null) {
        val cues = parsed[s.id]
        if (cues != null) {
            activeExtId = s.id
            subsOff = false
            ext?.set(cues)
            player?.let { applyTextSelection(it) }
            refreshPanel()
            return
        }
        if (!loading.add(s.id)) return
        refreshPanel()
        val gen = contentKey
        val ua = userAgent
        subPool.execute {
            val local = subStore.fetch(s.id, s.url, s.lang, s.label, ua)
            val list = local?.let { try { ExternalSubs.parse(it) } catch (_: Exception) { null } }
            handler.post {
                loading.remove(s.id)
                if (gen != contentKey) return@post
                if (list.isNullOrEmpty()) {
                    if (onFail != null) onFail() else toast("تعذّر تحميل هذه الترجمة، جرّب غيرها")
                    refreshPanel()
                    return@post
                }
                parsed[s.id] = list
                if (onFail != null && userPickedSub) return@post // the user chose something else meanwhile
                selectExternal(s)
            }
        }
    }

    /** Automatic choice: the best addon subtitle in a preferred language, unless an embedded
     *  track in an equally (or more) preferred language is already showing. */
    private fun maybeAutoSelectSub() {
        if (userPickedSub || autoSubDone || prefSubLangs.isEmpty()) return
        val p = player ?: return
        if (p.currentTracks.isEmpty) return
        val embeddedRank = selectedEmbedded(p)?.let { prefRank(it.group.getTrackFormat(it.index).language) } ?: 999
        // Saved ones first (local, work offline), then addon ones when online.
        val pool = saved + if (isOnline()) catalog.filter { !isSaved(it) } else emptyList()
        val candidates = pool.filter { prefRank(it.lang) < embeddedRank }.sortedBy { prefRank(it.lang) }.take(4)
        if (candidates.isEmpty()) return
        autoSubDone = true
        autoTry(candidates, 0)
    }

    /** Try the automatic candidates in order until one downloads and parses. */
    private fun autoTry(candidates: List<CatalogSub>, i: Int) {
        if (i >= candidates.size || userPickedSub) return
        selectExternal(candidates[i]) { autoTry(candidates, i + 1) }
    }

    private fun addToCatalog(arr: JSONArray?) {
        if (arr == null || arr.length() == 0 || source?.optBoolean("isLive") == true) return
        var added = 0
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val url = o.optString("url").takeIf { it.isNotBlank() } ?: continue
            val lang = o.optString("lang").takeIf { it.isNotBlank() }
            val label = o.optString("label").ifBlank { langName(lang) }
            if (url.startsWith("file:")) {
                // A subtitle saved on the phone (offline playback): list it with the saved ones.
                if (saved.none { it.url == url }) {
                    saved.add(CatalogSub(savedId(url), url, lang, if (lang != null) label.substringAfter(" · ", label) else label))
                    added++
                }
                continue
            }
            if (!catalogUrls.add(url)) continue
            catalog.add(CatalogSub("s${++subSeq}", url, lang, label))
            added++
        }
        if (added == 0) return
        maybeAutoSelectSub()
        if (panel?.isOpen == true && panelKind == "subs") refreshPanel()
    }

    private fun applySubStyle() {
        subStyle.applyTo(view?.subtitleView)
        subStyle.applyTo(extView)
    }

    private fun setSubDelay(ms: Long) {
        if (activeExtId == null) {
            toast("التأخير يشتغل على ترجمات الإضافات")
            return
        }
        ext?.delayMs = ms.coerceIn(-600_000, 600_000)
    }

    // ---- audio + speed ---------------------------------------------------------------------

    private fun openAudio() {
        openPanel("audio", "الصوت والسرعة")
        renderAudio()
    }

    private fun audioName(f: Format): String {
        val codec = when (f.sampleMimeType) {
            MimeTypes.AUDIO_AC3 -> "Dolby Digital"
            MimeTypes.AUDIO_E_AC3 -> "Dolby Digital Plus"
            MimeTypes.AUDIO_E_AC3_JOC -> "Dolby Atmos"
            MimeTypes.AUDIO_TRUEHD -> "Dolby TrueHD"
            MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_EXPRESS -> "DTS"
            MimeTypes.AUDIO_DTS_HD -> "DTS-HD"
            MimeTypes.AUDIO_AAC -> "AAC"
            MimeTypes.AUDIO_OPUS -> "Opus"
            MimeTypes.AUDIO_FLAC -> "FLAC"
            MimeTypes.AUDIO_MPEG -> "MP3"
            MimeTypes.AUDIO_VORBIS -> "Vorbis"
            else -> f.sampleMimeType?.substringAfter('/')?.uppercase()
        }
        val ch = when (f.channelCount) {
            1 -> "أحادي"; 2 -> "ستيريو"; 6 -> "5.1"; 8 -> "7.1"
            Format.NO_VALUE -> null
            else -> "${f.channelCount}ch"
        }
        return listOfNotNull(codec, ch).joinToString(" · ")
    }

    private fun renderAudio() {
        val p = panel ?: return
        val pl = player ?: return
        p.clear()
        val groups = pl.currentTracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        p.section("المسار الصوتي")
        if (groups.isEmpty()) p.note("ما فيه مسارات صوت.")
        groups.forEach { g ->
            for (i in 0 until g.length) {
                if (!g.isTrackSupported(i)) continue
                val f = g.getTrackFormat(i)
                p.row(
                    f.label?.takeIf { it.isNotBlank() } ?: langName(f.language),
                    audioName(f).ifBlank { null },
                    selected = g.isTrackSelected(i),
                ) {
                    pl.trackSelectionParameters = pl.trackSelectionParameters.buildUpon()
                        .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
                        .build()
                    handler.postDelayed({ refreshPanel() }, 250)
                }
            }
        }
        p.section("سرعة التشغيل")
        val speeds = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)
        val cur = pl.playbackParameters.speed
        p.chips(speeds.map { s ->
            Triple((if (s == 1f) "عادي" else "${s}x"), kotlin.math.abs(cur - s) < 0.01f) {
                pl.playbackParameters = PlaybackParameters(s)
                renderAudio()
            }
        })
    }

    // =========================================================================================
    // JS commands
    // =========================================================================================

    fun command(json: String) {
        val c = try { JSONObject(json) } catch (_: Exception) { return }
        when (c.optString("cmd")) {
            "meta" -> {
                c.optString("title").takeIf { it.isNotBlank() }?.let { title = it }
                subtitleLine = c.optString("subtitle", "")
                hasNext = c.optBoolean("hasNext", false)
                updateChrome()
                return
            }
            "streams" -> {
                streamsPayload = c
                if (panelKind == "streams") renderStreams()
                return
            }
            "streamFailed" -> {
                pickingStream = null
                toast(c.optString("message").ifBlank { "تعذّر تشغيل هذا المصدر، جرّب غيره" })
                if (panelKind == "streams") renderStreams()
                return
            }
            "subSearch" -> {
                searching = false
                val n = c.optInt("count", 0)
                if (c.optBoolean("manual")) toast(if (n == 0) "ما لقيت ترجمات من الإضافات" else "لقيت $n ترجمة")
                if (panelKind == "subs") refreshPanel()
                return
            }
            "addSubs" -> {
                val langs = jsonStrings(c.optJSONArray("prefLangs"))
                if (langs.isNotEmpty()) prefSubLangs = langs
                addToCatalog(c.optJSONArray("subs"))
                return
            }
        }
        val p = player ?: return
        when (c.optString("cmd")) {
            "play" -> p.play()
            "pause" -> p.pause()
            "seek" -> p.seekTo(c.optLong("ms", 0).coerceAtLeast(0))
            "rate" -> p.setPlaybackSpeed(c.optDouble("rate", 1.0).toFloat().coerceIn(0.25f, 4f))
            "volume" -> p.volume = c.optDouble("volume", 1.0).toFloat().coerceIn(0f, 1f)
        }
        sendState()
    }

    /** User closed the player: tell the web UI to leave the player view. */
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
        panel?.dismiss()
        releasePlayer()
        source = null
        pickingStream = null
        ext?.clear()
        if (locked) setLocked(false)
        view?.let {
            it.player = null
            it.visibility = View.GONE
        }
        listOfNotNull(topBar, nextButton, indicator, unlockButton).forEach { it.visibility = View.GONE }
        if (brightnessTouched) {
            val a = activity.window.attributes
            a.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            activity.window.attributes = a
            brightnessTouched = false
        }
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

    private fun toast(msg: String) = Toast.makeText(activity, msg, Toast.LENGTH_SHORT).show()

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

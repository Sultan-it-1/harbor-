package app.harbor.android

import android.content.pm.ActivityInfo
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import org.json.JSONArray
import org.json.JSONObject

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
    private val ticker = object : Runnable {
        override fun run() {
            sendState()
            handler.postDelayed(this, 1000)
        }
    }

    val isShowing: Boolean get() = view?.visibility == View.VISIBLE

    fun play(sourceJson: String) {
        val src = try { JSONObject(sourceJson) } catch (_: Exception) { return }
        source = src
        droppedSubs = false
        start(src, src.optLong("startMs", 0), withSubs = true)
    }

    private fun start(src: JSONObject, startMs: Long, withSubs: Boolean) {
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
            .setEnableDecoderFallback(true)
        val p = ExoPlayer.Builder(ctx, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()

        val url = src.getString("url")
        val item = MediaItem.Builder().setUri(url)
        val lower = url.lowercase()
        if (lower.contains(".m3u8") || lower.contains("/hlsv2/")) item.setMimeType(MimeTypes.APPLICATION_M3U8)
        else if (lower.contains(".mpd")) item.setMimeType(MimeTypes.APPLICATION_MPD)
        if (withSubs) item.setSubtitleConfigurations(subtitleConfigs(src.optJSONArray("subtitles")))

        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) emit(JSONObject().put("type", "ended").toString())
                sendState()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()
            override fun onVideoSizeChanged(videoSize: VideoSize) = sendState()

            override fun onPlayerError(error: PlaybackException) {
                // A broken side-loaded subtitle fails the whole playback; retry once without them.
                val cur = source
                if (cur != null && !droppedSubs && (cur.optJSONArray("subtitles")?.length() ?: 0) > 0) {
                    droppedSubs = true
                    val pos = player?.currentPosition ?: 0
                    handler.post { start(cur, pos, withSubs = false) }
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
        p.setMediaItem(item.build(), startMs.coerceAtLeast(0))
        p.prepare()
        p.playWhenReady = true
        player = p
        show(p)
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    private fun subtitleConfigs(arr: JSONArray?): List<MediaItem.SubtitleConfiguration> {
        if (arr == null) return emptyList()
        val out = ArrayList<MediaItem.SubtitleConfiguration>()
        for (i in 0 until arr.length()) {
            val s = arr.optJSONObject(i) ?: continue
            val u = s.optString("url").takeIf { it.isNotBlank() } ?: continue
            val l = u.lowercase().substringBefore('?')
            val mime = when {
                l.endsWith(".vtt") -> MimeTypes.TEXT_VTT
                l.endsWith(".ass") || l.endsWith(".ssa") -> MimeTypes.TEXT_SSA
                l.endsWith(".ttml") || l.endsWith(".dfxp") -> MimeTypes.APPLICATION_TTML
                else -> MimeTypes.APPLICATION_SUBRIP
            }
            val lang = s.optString("lang").takeIf { it.isNotBlank() }
            out.add(
                MediaItem.SubtitleConfiguration.Builder(Uri.parse(u))
                    .setMimeType(mime)
                    .setLanguage(lang)
                    .setLabel(s.optString("label").takeIf { it.isNotBlank() } ?: lang)
                    .setId("ext-$i")
                    .build(),
            )
        }
        return out
    }

    private fun show(p: ExoPlayer) {
        val v = view ?: PlayerView(activity).also { pv ->
            pv.setBackgroundColor(Color.BLACK)
            pv.setShowSubtitleButton(true)
            pv.setShowNextButton(false)
            pv.setShowPreviousButton(false)
            pv.keepScreenOn = true
            root.addView(pv, FrameLayout.LayoutParams(MainActivity.MATCH, MainActivity.MATCH))
            view = pv
        }
        v.player = p
        v.visibility = View.VISIBLE
        v.bringToFront()
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        activity.setFullscreenMode(true)
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
        view?.let {
            it.player = null
            it.visibility = View.GONE
        }
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        activity.setFullscreenMode(false)
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

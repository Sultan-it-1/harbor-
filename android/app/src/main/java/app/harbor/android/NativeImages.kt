package app.harbor.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.widget.ImageView
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** An ImageView that remembers which picture it is waiting for (see [NativeImages.load]). */
class NetImage(context: Context) : ImageView(context) {
    internal var want: String? = null
    internal var job: Future<*>? = null
}

/**
 * Pictures for the native screens (NativeHome). They come from the same on-phone cache the
 * WebView uses (ImageStore, so a poster seen once in either shows at once in the other), are
 * decoded at the size they are shown (a poster is a few hundred pixels, not the 2000px file) and
 * kept in memory while there is room.
 */
class NativeImages(private val store: ImageStore, private val screenShortSidePx: Int) {
    @Volatile var userAgent: String = "HarborAndroid"
    /** The app's own files (the web build in assets/www): pictures the page ships with (format
     *  badges, addon logos) are read from there by their https://appassets… address. */
    @Volatile var appAssets: android.content.res.AssetManager? = null

    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newFixedThreadPool(3) { r ->
        Thread(r, "harbor-native-img").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }
    private val memory = object : LruCache<String, Bitmap>(cacheBytes()) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }
    /** Addresses that failed this session: the next candidate is tried straight away. */
    private val failed = ConcurrentHashMap.newKeySet<String>()

    /**
     * Shows the first of [urls] that loads in [view], decoded for about [widthPx] x [heightPx].
     * A view that is bound to something else before the picture arrives never gets it.
     * [onResult] (main thread) says whether a picture is shown. [crop]: the view shows it
     * centre-cropped to [widthPx] x [heightPx] (a hero): its largest version is fetched and only
     * that middle part is decoded, at full sharpness.
     */
    fun load(view: NetImage, urls: List<String>, widthPx: Int, heightPx: Int, alpha: Boolean = false, crop: Boolean = false, onResult: ((Boolean) -> Unit)? = null) {
        val list = urls.filter {
            (it.startsWith("https://") || it.startsWith("http://") || it.startsWith("data:image/")) && it !in failed
        }.distinct()
        val w = widthPx.coerceAtLeast(1)
        val h = heightPx.coerceAtLeast(1)
        val sig = list.joinToString("|") + "@" + w + "x" + h + (if (crop) "c" else "")
        if (view.want == sig && view.drawable != null) {
            onResult?.invoke(true)
            return
        }
        view.job?.cancel(false)
        view.job = null
        view.want = sig
        if (list.isEmpty()) {
            view.setImageDrawable(null)
            onResult?.invoke(false)
            return
        }
        memory.get(memKey(list[0], w, h, crop))?.let {
            view.alpha = 1f
            view.setImageBitmap(it)
            onResult?.invoke(true)
            return
        }
        view.setImageDrawable(null)
        view.job = pool.submit {
            var bmp: Bitmap? = null
            for (u in list) {
                val key = memKey(u, w, h, crop)
                bmp = memory.get(key) ?: decode(u, w, h, alpha, crop)?.also { memory.put(key, it) }
                if (bmp != null) break
                failed.add(u)
            }
            val result = bmp
            main.post {
                if (view.want != sig) return@post
                view.job = null
                if (result != null) {
                    view.alpha = 0f
                    view.setImageBitmap(result)
                    view.animate().alpha(1f).setDuration(180).start()
                }
                onResult?.invoke(result != null)
            }
        }
    }

    /** Forget what [view] was showing or waiting for (it scrolled away for good). */
    fun clear(view: NetImage) {
        view.job?.cancel(false)
        view.job = null
        view.want = null
        view.setImageDrawable(null)
    }

    /** Android is short of memory: keep only what the screen shows right now. */
    fun trim(severe: Boolean) {
        if (severe) memory.evictAll() else memory.trimToSize(memory.maxSize() / 2)
    }

    private fun decode(url: String, w: Int, h: Int, alpha: Boolean, crop: Boolean = false): Bitmap? {
        val target = if (crop) ImageStore.heroSized(url) else ImageStore.phoneSized(url, screenShortSidePx)
        val headers = mapOf("User-Agent" to userAgent, "Accept" to "image/webp,image/png,image/jpeg,image/*;q=0.8")
        val bytes = try {
            if (url.startsWith("data:")) {
                // A picture the page drew itself (a service logo): carried in the address.
                android.util.Base64.decode(url.substringAfter(','), android.util.Base64.DEFAULT)
            } else if (url.startsWith(APP_ORIGIN)) {
                val path = url.removePrefix(APP_ORIGIN).substringBefore('?').substringBefore('#')
                if (path.isEmpty() || path.contains("..")) return null
                (appAssets ?: return null).open("www/$path").use { it.readBytes() }
            } else {
                val hit = store.cached(target)
                if (hit != null) {
                    if (hit.stale) store.recheck(target, hit.meta, headers)
                    hit.file.readBytes()
                } else {
                    store.download(target, headers).use { it.readBytes() }
                }
            }
        } catch (_: Exception) {
            return null
        }
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            if (crop) cropped(bytes, bounds.outWidth, bounds.outHeight, w, h)?.let { return it }
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= w && bounds.outHeight / (sample * 2) >= h) sample *= 2
            // Full colour: 16-bit (RGB_565) halved the memory but banded and softened the
            // pictures, most visibly the full-width hero.
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        } catch (_: OutOfMemoryError) {
            memory.evictAll()
            null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * The middle of the picture that a centre-crop to [w] x [h] shows, decoded on its own (a 4K
     * backdrop's middle for a tall hero is ~1300 x 2160, not the whole 3840 x 2160), halved
     * while it stays at least as sharp as the screen.
     */
    private fun cropped(bytes: ByteArray, ow: Int, oh: Int, w: Int, h: Int): Bitmap? {
        val scale = maxOf(w.toFloat() / ow, h.toFloat() / oh)
        val rw = minOf(ow, Math.ceil(w / scale.toDouble()).toInt()).coerceAtLeast(1)
        val rh = minOf(oh, Math.ceil(h / scale.toDouble()).toInt()).coerceAtLeast(1)
        val left = (ow - rw) / 2
        val top = (oh - rh) / 2
        var sample = 1
        while (rw / (sample * 2) >= w && rh / (sample * 2) >= h) sample *= 2
        return try {
            @Suppress("DEPRECATION")
            val dec = BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false) ?: return null
            try {
                dec.decodeRegion(
                    Rect(left, top, left + rw, top + rh),
                    BitmapFactory.Options().apply {
                        inSampleSize = sample
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                    },
                )
            } finally {
                dec.recycle()
            }
        } catch (_: OutOfMemoryError) {
            memory.evictAll()
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun memKey(url: String, w: Int, h: Int, crop: Boolean = false) = "$url@${w / 64}x${h / 64}${if (crop) "c" else ""}"

    companion object {
        private const val APP_ORIGIN = "https://${WebAssets.HOST}/"

        private fun cacheBytes(): Int {
            val max = Runtime.getRuntime().maxMemory()
            return (max / 6).coerceIn(16L * 1024 * 1024, 96L * 1024 * 1024).toInt()
        }
    }
}

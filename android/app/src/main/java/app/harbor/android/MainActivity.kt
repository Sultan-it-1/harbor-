package app.harbor.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import org.json.JSONObject

/**
 * Hosts the Harbor web UI (bundled from the Vite build) in a WebView and plays video
 * with a native ExoPlayer overlay, so Dolby/DTS audio that the WebView can't decode
 * still plays with sound.
 *
 * JS <-> native contract (see src/lib/android.ts):
 *   window.HarborAndroid.fetch(id, requestJson)   -> window.__harborNativeFetchDone(id, responseJson)
 *   window.HarborAndroid.play(sourceJson) / command(json) / stop()
 *                                                 -> window.__harborNativeEvent(eventJson)
 *   native back button                            -> window.__harborAndroidBack(): boolean
 */
class MainActivity : ComponentActivity() {
    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
    private lateinit var player: NativePlayer
    private lateinit var fetcher: NativeFetch
    private lateinit var downloads: Downloads
    private lateinit var images: ImageCache
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var fullscreen = false
    private var lastBackAt = 0L
    private var pageLoaded = false
    private var pendingOpenDownloads = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Draw edge-to-edge on every Android version (15+ forces it anyway) and pad the
        // content ourselves, so the UI never slides under the status bar / notch / nav bar.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }

        root = FrameLayout(this).apply { setBackgroundColor(0xFF000000.toInt()) }
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            if (fullscreen) {
                v.setPadding(0, 0, 0, 0)
            } else {
                val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
                val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
                v.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            }
            WindowInsetsCompat.CONSUMED
        }
        webView = WebView(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            overScrollMode = View.OVER_SCROLL_NEVER
            isHorizontalScrollBarEnabled = false
        }
        root.addView(webView, FrameLayout.LayoutParams(MATCH, MATCH))
        setContentView(root)
        RefreshRate.apply(this)

        fetcher = NativeFetch { id, result -> sendToJs("__harborNativeFetchDone", id, result) }
        downloads = Downloads.get(this)
        player = NativePlayer(this, root, downloads) { event -> sendToJs("__harborNativeEvent", event) }
        DownloadService.createChannel(this)
        pendingOpenDownloads = intent?.getBooleanExtra(EXTRA_OPEN_DOWNLOADS, false) == true

        val assets = WebAssets(this)
        images = ImageCache(this, minOf(resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels))
        val ws = webView.settings
        ws.javaScriptEnabled = true
        ws.domStorageEnabled = true
        ws.databaseEnabled = true
        ws.mediaPlaybackRequiresUserGesture = false
        ws.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        ws.allowFileAccess = false
        ws.loadWithOverviewMode = true
        ws.useWideViewPort = true
        ws.setSupportMultipleWindows(false)
        // Feel like an app, not a web page: no pinch zoom, and the phone's font-size setting
        // doesn't blow the layout up (the UI has its own scale setting).
        ws.setSupportZoom(false)
        ws.builtInZoomControls = false
        ws.displayZoomControls = false
        ws.textZoom = 100
        ws.userAgentString = ws.userAgentString + " HarborAndroid/" + BuildConfigInfo.versionName(this)
        fetcher.userAgent = ws.userAgentString
        player.userAgent = ws.userAgentString
        downloads.userAgent = ws.userAgentString
        images.userAgent = ws.userAgentString

        // The page keeps running when Harbor is in the background (season downloads and
        // subtitle searches happen there), so its renderer keeps the app's priority.
        if (Build.VERSION.SDK_INT >= 26) webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)

        webView.addJavascriptInterface(JsApi(), "HarborAndroid")
        webView.webViewClient = object : WebViewClient() {
            // The app's own files, then posters/backdrops from the phone's image cache.
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                assets.intercept(request) ?: images.intercept(request)

            override fun onPageFinished(view: WebView, url: String?) {
                pageLoaded = true
                if (pendingOpenDownloads) openDownloadsPage()
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                if (uri.host == WebAssets.HOST) return false
                openExternally(uri)
                return true
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                hideCustomView()
                customView = view
                customViewCallback = callback
                root.addView(view, FrameLayout.LayoutParams(MATCH, MATCH))
                setFullscreenMode(true)
            }

            override fun onHideCustomView() = hideCustomView()
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = onBack()
        })

        if (savedInstanceState != null) webView.restoreState(savedInstanceState)
        else webView.loadUrl("https://${WebAssets.HOST}/index.html")
    }

    private fun onBack() {
        when {
            player.isShowing -> if (!player.handleBack()) player.close()
            customView != null -> hideCustomView()
            else -> webView.evaluateJavascript(
                "(function(){try{return !!(window.__harborAndroidBack&&window.__harborAndroidBack())}catch(e){return false}})()",
            ) { handled ->
                if (handled != "true") {
                    if (webView.canGoBack()) {
                        webView.goBack()
                    } else {
                        // On Home: a single back swipe shouldn't drop you out of the app.
                        val now = System.currentTimeMillis()
                        if (now - lastBackAt < 2000) {
                            moveTaskToBack(true)
                        } else {
                            lastBackAt = now
                            Toast.makeText(this, "اسحب رجوع مرة ثانية للخروج", Toast.LENGTH_SHORT).show()
                        }
                    }
                }
            }
        }
    }

    /** Tapped the downloads notification: show the Downloads page (unless a video is playing). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(EXTRA_OPEN_DOWNLOADS, false)) {
            pendingOpenDownloads = true
            if (pageLoaded) openDownloadsPage()
        }
    }

    private fun openDownloadsPage() {
        pendingOpenDownloads = false
        if (player.isShowing) return
        // The app sets window.harbor once it has mounted; wait for it on a cold start.
        webView.evaluateJavascript(
            "(function t(n){if(window.harbor&&window.harbor.navigate){window.harbor.navigate('downloads')}else if(n>0){setTimeout(function(){t(n-1)},250)}})(60)",
            null,
        )
    }

    /** Asked once, on the first download: lets the progress notification show (Android 13+). */
    private fun askNotificationsOnce() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("harbor.app", MODE_PRIVATE)
        if (prefs.getBoolean("askedNotifications", false)) return
        prefs.edit().putBoolean("askedNotifications", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
    }

    private fun ignoringBatteryOptimizations(): Boolean =
        (getSystemService(POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)

    /** System dialog: "Let Harbor always run in the background?" (falls back to the settings list). */
    @SuppressLint("BatteryLife")
    private fun requestBackgroundRun() {
        try {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun hideCustomView() {
        val v = customView ?: return
        root.removeView(v)
        customView = null
        customViewCallback?.onCustomViewHidden()
        customViewCallback = null
        if (!player.isShowing) setFullscreenMode(false)
    }

    fun setFullscreenMode(on: Boolean) {
        val ctl = WindowInsetsControllerCompat(window, window.decorView)
        fullscreen = on
        if (on) {
            ctl.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            ctl.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            ctl.show(WindowInsetsCompat.Type.systemBars())
        }
        ViewCompat.requestApplyInsets(root)
    }

    private fun openExternally(uri: Uri) {
        try {
            val intent = if (uri.scheme == "intent") {
                Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
            } else {
                Intent(Intent.ACTION_VIEW, uri)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Exception) {
            // No app can handle it (e.g. vlc:// without VLC installed) — ignore.
        }
    }

    /** Calls window[fn](...args) in the page; each arg is passed as a JS string literal. */
    private fun sendToJs(fn: String, vararg args: String) {
        val js = buildString {
            append("window.").append(fn).append("&&window.").append(fn).append("(")
            args.forEachIndexed { i, a ->
                if (i > 0) append(",")
                append(JSONObject.quote(a))
            }
            append(")")
        }
        webView.post { webView.evaluateJavascript(js, null) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    override fun onResume() {
        super.onResume()
        if (!player.isShowing) RefreshRate.apply(this)
        downloads.kick()
        // e.g. back from the battery dialog: let the page re-check what it shows.
        if (pageLoaded) webView.evaluateJavascript("window.dispatchEvent(new Event('harbor:resume'))", null)
    }

    override fun onPause() {
        super.onPause()
        player.onHostPause()
    }

    override fun onDestroy() {
        // The page (and any season queue / subtitle search in it) goes away with the activity;
        // system downloads carry on and DownloadService stays up while they run.
        DownloadService.keepAlive(this, false)
        player.stop(notify = false)
        fetcher.shutdown()
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
        super.onDestroy()
    }

    inner class JsApi {
        @JavascriptInterface
        fun version(): String = BuildConfigInfo.versionName(this@MainActivity)

        @JavascriptInterface
        fun fetch(id: String, requestJson: String) = fetcher.enqueue(id, requestJson)

        @JavascriptInterface
        fun play(sourceJson: String) = runOnUiThread { player.play(sourceJson) }

        @JavascriptInterface
        fun command(json: String) = runOnUiThread { player.command(json) }

        @JavascriptInterface
        fun stop() = runOnUiThread { player.stop(notify = false) }

        @JavascriptInterface
        fun openExternal(url: String) = runOnUiThread { openExternally(Uri.parse(url)) }

        // ---- downloads (see Downloads.kt) ----
        @JavascriptInterface
        fun dlStart(json: String): String {
            runOnUiThread { askNotificationsOnce() }
            return downloads.start(json)
        }

        /** The page has background work (season queue, subtitle searches) — keep Harbor running. */
        @JavascriptInterface
        fun dlKeepAlive(on: Boolean) = DownloadService.keepAlive(this@MainActivity, on)

        @JavascriptInterface
        fun bgAllowed(): Boolean = ignoringBatteryOptimizations()

        @JavascriptInterface
        fun bgRequest() = runOnUiThread { requestBackgroundRun() }

        @JavascriptInterface
        fun dlStatus(): String = downloads.status()

        @JavascriptInterface
        fun dlDelete(id: String): Boolean = downloads.delete(id)

        @JavascriptInterface
        fun dlPause(id: String): Boolean = downloads.pause(id)

        /** Resume a paused download, or retry a failed one from where it got to. */
        @JavascriptInterface
        fun dlResume(id: String): Boolean = downloads.resume(id)

        @JavascriptInterface
        fun dlAddSubs(id: String, json: String): Boolean = downloads.addSubtitles(id, json)

        @JavascriptInterface
        fun dlFiles(id: String): String = downloads.files(id)

        @JavascriptInterface
        fun dlStorage(): String = downloads.storage()
    }

    companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val EXTRA_OPEN_DOWNLOADS = "app.harbor.android.OPEN_DOWNLOADS"
    }
}

object BuildConfigInfo {
    fun versionName(activity: ComponentActivity): String = try {
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: "0"
    } catch (_: Exception) {
        "0"
    }
}

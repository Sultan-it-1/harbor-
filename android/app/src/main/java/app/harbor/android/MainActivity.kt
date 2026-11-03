package app.harbor.android

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Bundle
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
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var fullscreen = false
    private var lastBackAt = 0L

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

        player = NativePlayer(this, root) { event -> sendToJs("__harborNativeEvent", event) }
        fetcher = NativeFetch { id, result -> sendToJs("__harborNativeFetchDone", id, result) }

        val assets = WebAssets(this)
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

        webView.addJavascriptInterface(JsApi(), "HarborAndroid")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                assets.intercept(request)

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
            player.isShowing -> player.close()
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

    override fun onPause() {
        super.onPause()
        player.onHostPause()
    }

    override fun onDestroy() {
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
    }

    companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}

object BuildConfigInfo {
    fun versionName(activity: ComponentActivity): String = try {
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: "0"
    } catch (_: Exception) {
        "0"
    }
}

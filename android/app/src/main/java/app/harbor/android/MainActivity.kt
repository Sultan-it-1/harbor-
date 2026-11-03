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

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)

        root = FrameLayout(this).apply { setBackgroundColor(0xFF000000.toInt()) }
        webView = WebView(this).apply { setBackgroundColor(0xFF000000.toInt()) }
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
                    if (webView.canGoBack()) webView.goBack() else moveTaskToBack(true)
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
        WindowCompat.setDecorFitsSystemWindows(window, !on)
        if (on) {
            ctl.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            ctl.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            ctl.show(WindowInsetsCompat.Type.systemBars())
        }
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

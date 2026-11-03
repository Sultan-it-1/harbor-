package app.harbor.android

import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import org.json.JSONObject

/** Subtitle look, saved on the device. First run is seeded from Harbor's subtitle settings. */
data class SubStyle(
    var scale: Float = 1f,
    var background: String = "shadow", // shadow | outline | box | none
    var color: Int = Color.WHITE,
    var bottom: Float = 0.08f,
    var bold: Boolean = false,
    var boxOpacity: Float = 0.6f,
) {
    companion object {
        private const val PREFS = "harbor.substyle"

        fun load(ctx: Context): SubStyle? {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!p.getBoolean("saved", false)) return null
            return SubStyle(
                scale = p.getFloat("scale", 1f),
                background = p.getString("background", "shadow") ?: "shadow",
                color = p.getInt("color", Color.WHITE),
                bottom = p.getFloat("bottom", 0.08f),
                bold = p.getBoolean("bold", false),
                boxOpacity = p.getFloat("boxOpacity", 0.6f),
            )
        }

        /** Harbor web settings: subFontSize (32 = 100%), subFontColor, subStyle, subBold, subMarginY, subBoxOpacity. */
        fun fromHarbor(o: JSONObject?): SubStyle {
            val s = SubStyle()
            if (o == null) return s
            val size = o.optDouble("fontSize", 32.0)
            if (size > 0) s.scale = (size / 32.0).toFloat().coerceIn(0.5f, 2.5f)
            try {
                o.optString("color").takeIf { it.startsWith("#") }?.let { s.color = Color.parseColor(it) }
            } catch (_: Exception) {}
            s.background = when (o.optString("style")) {
                "outline" -> "outline"
                "box" -> "box"
                else -> "shadow"
            }
            s.bold = o.optBoolean("bold", false)
            val margin = o.optDouble("marginY", 12.0)
            s.bottom = (0.04 + margin / 400.0).toFloat().coerceIn(0.02f, 0.4f)
            s.boxOpacity = o.optDouble("boxOpacity", 0.6).toFloat().coerceIn(0.1f, 1f)
            return s
        }
    }

    fun save(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("saved", true)
            .putFloat("scale", scale)
            .putString("background", background)
            .putInt("color", color)
            .putFloat("bottom", bottom)
            .putBoolean("bold", bold)
            .putFloat("boxOpacity", boxOpacity)
            .apply()
    }

    @OptIn(UnstableApi::class)
    fun applyTo(sv: SubtitleView?) {
        if (sv == null) return
        // Our look wins over styling baked into ASS / embedded tracks, like a normal player.
        sv.setApplyEmbeddedStyles(false)
        sv.setApplyEmbeddedFontSizes(false)
        sv.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * scale)
        sv.setBottomPaddingFraction(bottom)
        val typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        val boxAlpha = (boxOpacity * 255).toInt().coerceIn(0, 255)
        val style = when (background) {
            "box" -> CaptionStyleCompat(color, Color.argb(boxAlpha, 0, 0, 0), Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_NONE, Color.BLACK, typeface)
            "outline" -> CaptionStyleCompat(color, Color.TRANSPARENT, Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, typeface)
            "none" -> CaptionStyleCompat(color, Color.TRANSPARENT, Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_NONE, Color.BLACK, typeface)
            else -> CaptionStyleCompat(color, Color.TRANSPARENT, Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW, Color.BLACK, typeface)
        }
        sv.setStyle(style)
    }
}

/** The "Aa" panel: size, background, colour, position, bold and (addon-sub) delay. */
class SubtitleControls(
    private val ctx: Context,
    private val style: SubStyle,
    private val onStyle: () -> Unit,
    private val getDelayMs: () -> Long,
    private val onDelay: (Long) -> Unit,
) {
    fun show() {
        val dp = ctx.resources.displayMetrics.density
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((20 * dp).toInt(), (12 * dp).toInt(), (20 * dp).toInt(), (8 * dp).toInt())
        }

        val sizeLabel = valueLabel()
        val posLabel = valueLabel()
        val delayLabel = valueLabel()
        fun refresh() {
            sizeLabel.text = "${(style.scale * 100).toInt()}%"
            posLabel.text = "${(style.bottom * 100).toInt()}%"
            val d = getDelayMs()
            delayLabel.text = (if (d > 0) "+" else "") + String.format("%.1f", d / 1000.0) + "s"
        }

        col.addView(row("الحجم", btn("−") { style.scale = (style.scale - 0.1f).coerceAtLeast(0.5f); changed(); refresh() }, sizeLabel,
            btn("+") { style.scale = (style.scale + 0.1f).coerceAtMost(2.5f); changed(); refresh() }))

        val bgButtons = listOf("shadow" to "ظل", "outline" to "إطار", "box" to "خلفية", "none" to "بدون")
        val bgViews = ArrayList<Button>()
        fun markBg() = bgViews.forEachIndexed { i, b -> highlight(b, bgButtons[i].first == style.background) }
        bgButtons.forEach { (key, name) -> bgViews.add(btn(name) { style.background = key; changed(); markBg() }) }
        col.addView(row("الخلفية", *bgViews.toTypedArray()))
        markBg()

        col.addView(row("شفافية الخلفية",
            btn("−") { style.boxOpacity = (style.boxOpacity - 0.1f).coerceAtLeast(0.1f); changed() },
            btn("+") { style.boxOpacity = (style.boxOpacity + 0.1f).coerceAtMost(1f); changed() }))

        val colors = listOf(Color.WHITE, Color.parseColor("#FFE14D"), Color.parseColor("#7FE7FF"), Color.parseColor("#8CFF8C"))
        val colorViews = ArrayList<Button>()
        fun markColor() = colorViews.forEachIndexed { i, b -> highlight(b, colors[i] == style.color, colors[i]) }
        colors.forEach { c -> colorViews.add(btn("A") { style.color = c; changed(); markColor() }.apply { setTextColor(c) }) }
        col.addView(row("اللون", *colorViews.toTypedArray()))
        markColor()

        col.addView(row("المكان", btn("↓") { style.bottom = (style.bottom - 0.03f).coerceAtLeast(0.0f); changed(); refresh() }, posLabel,
            btn("↑") { style.bottom = (style.bottom + 0.03f).coerceAtMost(0.45f); changed(); refresh() }))

        val boldBtn = btn("عريض") { style.bold = !style.bold; changed() }
        boldBtn.setOnClickListener { style.bold = !style.bold; changed(); highlight(boldBtn, style.bold) }
        highlight(boldBtn, style.bold)
        col.addView(row("الخط", boldBtn))

        col.addView(row("التأخير", btn("−0.5") { onDelay(getDelayMs() - 500); refresh() }, delayLabel,
            btn("+0.5") { onDelay(getDelayMs() + 500); refresh() }, btn("0") { onDelay(0); refresh() }))
        col.addView(TextView(ctx).apply {
            text = "التأخير يشتغل على ترجمات الإضافات (مو المدمجة في الملف)."
            setTextColor(Color.argb(150, 255, 255, 255))
            textSize = 12f
            setPadding(0, (4 * dp).toInt(), 0, 0)
        })
        refresh()

        AlertDialog.Builder(ctx, android.R.style.Theme_Material_Dialog_NoActionBar)
            .setTitle("إعدادات الترجمة")
            .setView(ScrollView(ctx).apply { addView(col) })
            .setPositiveButton("تم", null)
            .setNeutralButton("الافتراضي") { _, _ ->
                val d = SubStyle()
                style.scale = d.scale; style.background = d.background; style.color = d.color
                style.bottom = d.bottom; style.bold = d.bold; style.boxOpacity = d.boxOpacity
                changed()
            }
            .create()
            .apply {
                // Keep the immersive player behind the dialog.
                window?.setFlags(
                    android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                    android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                )
                window?.setDimAmount(0.2f)
                show()
                window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
            }
    }

    private fun changed() {
        style.save(ctx)
        onStyle()
    }

    private fun row(title: String, vararg views: View): View {
        val dp = ctx.resources.displayMetrics.density
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, (6 * dp).toInt(), 0, (6 * dp).toInt())
            addView(TextView(ctx).apply {
                text = title
                setTextColor(Color.WHITE)
                textSize = 14f
                minWidth = (96 * dp).toInt()
            })
            views.forEach { v ->
                addView(v, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, (40 * dp).toInt()).apply {
                    marginEnd = (6 * dp).toInt()
                })
            }
        }
    }

    private fun valueLabel() = TextView(ctx).apply {
        setTextColor(Color.WHITE)
        textSize = 14f
        gravity = Gravity.CENTER
        minWidth = (56 * ctx.resources.displayMetrics.density).toInt()
    }

    private fun btn(text: String, onClick: () -> Unit) = Button(ctx).apply {
        this.text = text
        isAllCaps = false
        textSize = 14f
        setTextColor(Color.WHITE)
        minWidth = 0
        minimumWidth = (44 * ctx.resources.displayMetrics.density).toInt()
        setPadding((10 * ctx.resources.displayMetrics.density).toInt(), 0, (10 * ctx.resources.displayMetrics.density).toInt(), 0)
        background = pill(false, Color.WHITE)
        setOnClickListener { onClick() }
    }

    private fun highlight(b: Button, on: Boolean, accent: Int = Color.WHITE) {
        b.background = pill(on, accent)
    }

    private fun pill(on: Boolean, accent: Int) = GradientDrawable().apply {
        cornerRadius = 999f
        setColor(if (on) Color.argb(70, 255, 255, 255) else Color.argb(28, 255, 255, 255))
        setStroke((1.5f * ctx.resources.displayMetrics.density).toInt(), if (on) accent else Color.argb(60, 255, 255, 255))
    }
}

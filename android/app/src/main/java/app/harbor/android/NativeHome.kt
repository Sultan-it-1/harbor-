package app.harbor.android

import android.content.Context
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Parcelable
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.PagerSnapHelper
import androidx.recyclerview.widget.RecyclerView
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The Home screen drawn with Android's own views instead of in the WebView: the featured hero,
 * Continue Watching, Top 10 and the catalog poster rows. Some devices (Android 13 handhelds such
 * as the Anbernic RG 476H) ship a WebView that can't lay out the poster rows; here the system
 * draws them, whatever the WebView.
 *
 * The page still decides WHAT is on Home (addons, TMDB, Trakt, row order, hidden rows…) and
 * handles every tap, so nothing of that is written twice. Contract (src/views/home/native-home.ts):
 *   page   -> HarborAndroid.homeSet(modelJson)   what to show (HomeModel)
 *   page   -> HarborAndroid.homeShow(on, …)       shown only while Home is on screen with nothing over it
 *   native -> window.__harborNativeHome(json)    {p:page, a:"hero",i,what:"open"|"play"|"list"}
 *                                                {a:"open"|"hold"|"play",row,i} {a:"all",row} {a:"more",row}
 *                                                {a:"chip",row,what} {a:"customize"} {a:"together"} {a:"failed"}
 * The same screen serves Discover, Movies, Shows and the Library (NativeScreens keeps one per page).
 */
class NativeHome(
    private val ctx: Context,
    private val images: NativeImages,
    /** Which screen this draws ("home", "discover", "movies", "shows", "library"); sent with every tap. */
    val page: String,
    private val onAction: (JSONObject) -> Unit,
) {
    val root = FrameLayout(ctx)
    private val list = RecyclerView(ctx)
    private val sections = SectionsAdapter()
    private val togetherButton = FrameLayout(ctx)
    private val cardPool = RecyclerView.RecycledViewPool()
    private val rowScroll = HashMap<String, Parcelable?>()
    private val askedMore = HashMap<String, Int>()
    private var model: HomeModel? = null
    private var colors = HomeColors.DEFAULT
    private var lastJson: String? = null
    private var lastTop = Int.MIN_VALUE
    private var heroPage = 0
    /** What the page last asked for (it may ask before the first model arrives). */
    private var wanted = false
    private var laidOutWidth = 0
    private var laidOutHeight = 0

    val isShowing: Boolean get() = root.visibility == View.VISIBLE

    init {
        root.visibility = View.GONE
        root.isClickable = true // taps never fall through to the page underneath
        list.layoutManager = LinearLayoutManager(ctx, RecyclerView.VERTICAL, false).apply { initialPrefetchItemCount = 3 }
        list.adapter = sections
        list.overScrollMode = View.OVER_SCROLL_NEVER
        list.isVerticalScrollBarEnabled = false
        list.clipToPadding = false
        list.itemAnimator = null
        cardPool.setMaxRecycledViews(C_POSTER, 40)
        cardPool.setMaxRecycledViews(C_RANK, 16)
        cardPool.setMaxRecycledViews(C_CW, 12)
        cardPool.setMaxRecycledViews(C_TILE, 16)
        cardPool.setMaxRecycledViews(C_LOGO, 12)
        cardPool.setMaxRecycledViews(C_FEATURE, 2)
        root.addView(list, FrameLayout.LayoutParams(MATCH, MATCH))

        togetherButton.apply {
            visibility = View.GONE
            isClickable = true
            isFocusable = true
            setOnClickListener { act("together") }
            val ic = ImageView(ctx).apply { setImageDrawable(icon(R.drawable.ic_users, Color.WHITE)) }
            addView(ic, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        }
        root.addView(togetherButton, FrameLayout.LayoutParams(dp(44), dp(44), Gravity.TOP or Gravity.END).apply {
            topMargin = dp(12)
            marginEnd = dp(12)
        })

        // New width (rotation, split screen): card sizes follow it.
        root.addOnLayoutChangeListener { _, l, t, r, b, _, _, _, _ ->
            val w = r - l
            val h = b - t
            if (w > 0 && (w != laidOutWidth || abs(h - laidOutHeight) > dp(80))) {
                val first = laidOutWidth == 0
                laidOutWidth = w
                laidOutHeight = h
                if (!first) root.post { sections.notifyDataSetChanged() }
            }
        }
    }

    /** A new description of Home from the page. Nothing changed = nothing redrawn. */
    fun setModel(json: String) {
        if (json == lastJson) return
        val m = try {
            HomeModel.parse(json)
        } catch (e: Exception) {
            Log.e(TAG, "home model rejected", e)
            act("failed")
            return
        }
        lastJson = json
        try {
            model = m
            colors = m.colors
            root.layoutDirection = if (m.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
            root.setBackgroundColor(colors.canvas)
            togetherButton.background = rounded(withAlpha(colors.canvas, 0.72f), dp(22).toFloat())
            togetherButton.contentDescription = m.label("together", "Watch together")
            togetherButton.visibility = if (m.showTogether) View.VISIBLE else View.GONE
            sections.submit(m)
            if (lastTop != Int.MIN_VALUE && m.top != lastTop) list.scrollToPosition(0)
            lastTop = m.top
            applyVisibility()
        } catch (e: Exception) {
            Log.e(TAG, "home model failed to show", e)
            show(false, 0)
            act("failed")
        }
    }

    /** On (Home on screen, nothing over it) or off; [bottomPx] = room kept for the page's tab bar. */
    fun show(on: Boolean, bottomPx: Int) {
        val lp = root.layoutParams as? ViewGroup.MarginLayoutParams
        if (lp != null && lp.bottomMargin != bottomPx.coerceAtLeast(0)) {
            lp.bottomMargin = bottomPx.coerceAtLeast(0)
            root.layoutParams = lp
        }
        wanted = on
        applyVisibility()
    }

    private fun applyVisibility() {
        val want = wanted && model != null
        if (want == isShowing) return
        root.animate().cancel()
        if (want) {
            root.alpha = 0f
            root.visibility = View.VISIBLE
            root.animate().alpha(1f).setDuration(120).start()
        } else {
            root.visibility = View.GONE
        }
    }

    /** A D-pad / controller key while the focus is elsewhere (the page underneath): bring it here. */
    fun takeFocus(): Boolean = isShowing && (list.requestFocus() || root.requestFocus())

    private fun act(a: String, row: String? = null, i: Int? = null, what: String? = null, text: String? = null) {
        val o = JSONObject().put("p", page).put("a", a)
        if (row != null) o.put("row", row)
        if (i != null) o.put("i", i)
        if (what != null) o.put("what", what)
        if (text != null) o.put("text", text)
        onAction(o)
    }

    // ---- sizes ---------------------------------------------------------------------------------

    private fun width(): Int = (if (laidOutWidth > 0) laidOutWidth else ctx.resources.displayMetrics.widthPixels)
    private fun height(): Int = (if (laidOutHeight > 0) laidOutHeight else ctx.resources.displayMetrics.heightPixels)
    private val gutter get() = dp(20)
    private val gap get() = dp(12)

    /** About 3.3 posters across a phone (like the web layout), never bigger than 150dp. */
    private fun posterWidth(): Int = min(((width() - gutter) / 3.3f).toInt(), dp(150))
    /** Top 10 posters: a little bigger than the others. */
    private fun rankWidth(): Int = (posterWidth() * 1.15f).toInt()
    private fun cwWidth(): Int = min(((width() - gutter) / 1.7f).toInt(), dp(300))
    private fun heroHeight(): Int = max(min((height() * 0.76f).toInt(), dp(640)), dp(320))
    /** Genre / language / award / collection tiles: about 2.3 across, 5:4. */
    private fun tileWidth(): Int = min(((width() - gutter) / 2.3f).toInt(), dp(220))
    private fun logoWidth(): Int = min(((width() - gutter) / 2.6f).toInt(), dp(172))
    /** One card the width of the screen (Critics' Pick). */
    private fun featureWidth(): Int = width() - 2 * gutter

    // ---- outer list: hero, Customize, rows -----------------------------------------------------

    private class Section(val type: Int, val id: Long, val row: HomeRow? = null, val chipsIndex: Int = -1)

    private inner class SectionsAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private var items: List<Section> = emptyList()

        init {
            setHasStableIds(true)
        }

        fun submit(m: HomeModel) {
            val out = ArrayList<Section>()
            if (m.header != null) out.add(Section(T_HEADER, -6))
            if (m.hero.isNotEmpty()) out.add(Section(T_HERO, -1))
            if (m.showCustomize || m.edit) out.add(Section(T_TOOLS, -2))
            else if (m.hero.isNotEmpty()) out.add(Section(T_GAP, -5))
            m.chips.forEachIndexed { i, _ -> out.add(Section(T_CHIPS, -100L - i, chipsIndex = i)) }
            if (m.cwEmpty != null) out.add(Section(T_CW_EMPTY, -3))
            for (r in m.rows) out.add(Section(T_ROW, stableId(r.key), r))
            if (m.rows.isEmpty() && m.empty != null) out.add(Section(T_EMPTY, -7))
            out.add(Section(T_END, -4))
            items = out
            // Text at the top (no hero, or a heading above it): keep it clear of the floating
            // Watch together button.
            val top = if (m.hero.isEmpty() || m.header != null) dp(64) else 0
            if (list.paddingTop != top) list.setPadding(0, top, 0, 0)
            notifyDataSetChanged()
        }

        override fun getItemCount() = items.size
        override fun getItemViewType(position: Int) = items[position].type
        override fun getItemId(position: Int) = items[position].id

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = when (viewType) {
            T_HERO -> HeroHolder()
            T_TOOLS -> ToolsHolder()
            T_CW_EMPTY, T_EMPTY -> CwEmptyHolder()
            T_HEADER -> HeaderHolder()
            T_CHIPS -> ChipsHolder()
            T_ROW -> RowHolder()
            T_GAP -> SpacerHolder(dp(28))
            else -> SpacerHolder(dp(28))
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val m = model ?: return
            when (holder) {
                is HeroHolder -> holder.bind(m)
                is ToolsHolder -> holder.bind(m)
                is CwEmptyHolder -> if (items[position].type == T_EMPTY) {
                    m.empty?.let { holder.bind(it.first, it.second) }
                } else {
                    m.cwEmpty?.let { holder.bind(it.first, it.second) }
                }
                is HeaderHolder -> m.header?.let { holder.bind(it) }
                is ChipsHolder -> m.chips.getOrNull(items[position].chipsIndex)?.let { holder.bind(it) }
                is RowHolder -> items[position].row?.let { holder.bind(it) }
            }
        }

        override fun onViewRecycled(holder: RecyclerView.ViewHolder) {
            if (holder is RowHolder) holder.saveScroll()
        }
    }

    private inner class SpacerHolder(h: Int) : RecyclerView.ViewHolder(View(ctx).apply {
        layoutParams = RecyclerView.LayoutParams(MATCH, h)
    })

    /** "Customize home" under the hero (the editor itself is the page's). */
    /** "Customize" under the hero; while the editor is open: Done, Reset (and Add source on Home). */
    private inner class ToolsHolder : RecyclerView.ViewHolder(LinearLayout(ctx)) {
        private val bar = itemView as LinearLayout

        init {
            bar.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            bar.orientation = LinearLayout.HORIZONTAL
            bar.gravity = Gravity.END or Gravity.CENTER_VERTICAL
            bar.setPaddingRelative(gutter, dp(10), gutter, dp(14))
        }

        fun bind(m: HomeModel) {
            bar.removeAllViews()
            if (!m.edit) {
                bar.addView(pill(m.label("customize", "Customize home"), R.drawable.ic_pencil, primary = false) { act("customize") })
                return
            }
            if (m.addSource) bar.addView(pill(m.label("addSource", "Add Source"), R.drawable.ic_plus, primary = false) { act("addsource") })
            bar.addView(pill(m.label("reset", "Reset"), R.drawable.ic_rotate_ccw, primary = false) { act("reset") })
            bar.addView(pill(m.label("done", "Done editing"), R.drawable.ic_check, primary = true) { act("done") })
        }

        private fun pill(text: String, ic: Int, primary: Boolean, onTap: () -> Unit): View = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPaddingRelative(dp(12), 0, dp(14), 0)
            isClickable = true
            isFocusable = true
            setOnClickListener { onTap() }
            val fg = if (primary) colors.canvas else colors.muted
            addView(ImageView(ctx).apply { setImageDrawable(icon(ic, fg)) }, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginEnd = dp(8) })
            addView(label(text, 13f, bold = primary, lines = 1).apply { setTextColor(fg) })
            background = focusable(
                if (primary) rounded(colors.ink, dp(10).toFloat())
                else rounded(withAlpha(colors.surface, 0.9f), dp(10).toFloat(), dp(1), withAlpha(colors.ink, 0.08f)),
            )
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36)).apply { marginStart = dp(8) }
        }
    }

    private inner class CwEmptyHolder : RecyclerView.ViewHolder(LinearLayout(ctx)) {
        private val col = itemView as LinearLayout
        private val title = label("", 17f, bold = true)
        private val box = label("", 15f)

        init {
            col.orientation = LinearLayout.VERTICAL
            col.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            col.setPaddingRelative(gutter, dp(8), gutter, dp(24))
            col.addView(title, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) })
            box.gravity = Gravity.CENTER
            box.setPadding(dp(20), dp(36), dp(20), dp(36))
            col.addView(box, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT))
        }

        fun bind(t: String?, text: String) {
            title.text = t ?: ""
            title.visibility = if (t.isNullOrBlank()) View.GONE else View.VISIBLE
            title.setTextColor(colors.ink)
            box.text = text
            box.setTextColor(colors.muted)
            val dash = withAlpha(colors.ink, 0.22f) // (inside apply, "colors" would be the drawable's own)
            box.background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), dash, dp(5).toFloat(), dp(4).toFloat())
            }
        }
    }

    /** A page's heading (Shows, Library): small kicker, big title, a line under it. */
    private inner class HeaderHolder : RecyclerView.ViewHolder(LinearLayout(ctx)) {
        private val col = itemView as LinearLayout
        private val kicker = label("", 11f, bold = true)
        private val title = label("", 30f, lines = 2)
        private val subtitle = label("", 14f, lines = 3)

        init {
            col.orientation = LinearLayout.VERTICAL
            col.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            col.setPaddingRelative(gutter, 0, gutter, dp(18))
            kicker.letterSpacing = 0.28f
            title.typeface = Typeface.create(Typeface.SERIF, Typeface.NORMAL)
            col.addView(kicker)
            col.addView(title, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4) })
            col.addView(subtitle, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
        }

        fun bind(h: HomeHeader) {
            kicker.text = h.kicker?.uppercase() ?: ""
            kicker.visibility = if (h.kicker.isNullOrBlank()) View.GONE else View.VISIBLE
            kicker.setTextColor(colors.subtle)
            // Arabic has no letter case and its letters must stay joined.
            kicker.letterSpacing = if (model?.rtl == true) 0f else 0.28f
            title.text = h.title
            title.visibility = if (h.title.isBlank()) View.GONE else View.VISIBLE
            title.setTextColor(colors.ink)
            subtitle.text = h.subtitle ?: ""
            subtitle.visibility = if (h.subtitle.isNullOrBlank()) View.GONE else View.VISIBLE
            subtitle.setTextColor(colors.muted)
        }
    }

    /** A row of choices (Library tab, type, sort); the chosen one is filled. Scrolls sideways. */
    private inner class ChipsHolder : RecyclerView.ViewHolder(android.widget.HorizontalScrollView(ctx)) {
        private val scroller = itemView as android.widget.HorizontalScrollView
        private val strip = LinearLayout(ctx)

        init {
            scroller.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            scroller.isHorizontalScrollBarEnabled = false
            scroller.overScrollMode = View.OVER_SCROLL_NEVER
            scroller.clipToPadding = false
            strip.orientation = LinearLayout.HORIZONTAL
            strip.setPaddingRelative(gutter, dp(2), gutter, dp(12))
            scroller.addView(strip)
        }

        fun bind(g: HomeChips) {
            strip.removeAllViews()
            for (c in g.items) {
                val chip = label(c.label, 13f, bold = c.on, lines = 1).apply {
                    gravity = Gravity.CENTER
                    setPaddingRelative(dp(14), 0, dp(14), 0)
                    isClickable = true
                    isFocusable = true
                    setTextColor(if (c.on) colors.canvas else colors.muted)
                    background = focusable(
                        if (c.on) rounded(colors.ink, dp(18).toFloat())
                        else rounded(withAlpha(colors.surface, 0.9f), dp(18).toFloat(), dp(1), withAlpha(colors.ink, 0.1f)),
                    )
                    setOnClickListener { act("chip", row = g.key, what = c.id) }
                }
                strip.addView(chip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36)).apply { marginEnd = dp(8) })
            }
        }
    }

    // ---- hero ----------------------------------------------------------------------------------

    private inner class HeroHolder : RecyclerView.ViewHolder(FrameLayout(ctx)) {
        private val frame = itemView as FrameLayout
        private val pager = RecyclerView(ctx)
        private val dots = LinearLayout(ctx)
        private val slides = SlidesAdapter()
        private val pagerLayout = LinearLayoutManager(ctx, RecyclerView.HORIZONTAL, false)
        private val snap = PagerSnapHelper()
        /** The next slide on its own, every [HERO_TURN_MS] (like the page's carousel). */
        private val turn = Runnable { autoTurn() }

        init {
            frame.layoutParams = RecyclerView.LayoutParams(MATCH, heroHeight())
            pager.layoutManager = pagerLayout
            pager.adapter = slides
            pager.overScrollMode = View.OVER_SCROLL_NEVER
            pager.itemAnimator = null
            snap.attachToRecyclerView(pager)
            pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
                override fun onScrollStateChanged(rv: RecyclerView, newState: Int) {
                    // A swipe by hand: the next turn waits a full interval from now.
                    if (newState == RecyclerView.SCROLL_STATE_DRAGGING) scheduleTurn()
                    if (newState != RecyclerView.SCROLL_STATE_IDLE) return
                    val v = snap.findSnapView(pagerLayout) ?: return
                    val p = pagerLayout.getPosition(v)
                    if (p != RecyclerView.NO_POSITION) {
                        heroPage = p
                        paintDots()
                    }
                }
            })
            frame.addView(pager, FrameLayout.LayoutParams(MATCH, MATCH))
            dots.orientation = LinearLayout.HORIZONTAL
            dots.gravity = Gravity.CENTER
            frame.addView(dots, FrameLayout.LayoutParams(MATCH, dp(10), Gravity.BOTTOM).apply { bottomMargin = dp(18) })
            frame.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) = scheduleTurn()
                override fun onViewDetachedFromWindow(v: View) {
                    frame.removeCallbacks(turn)
                }
            })
        }

        private fun scheduleTurn() {
            frame.removeCallbacks(turn)
            frame.postDelayed(turn, HERO_TURN_MS)
        }

        /** Only while the screen shows, nobody is swiping it and the D-pad isn't on its buttons. */
        private fun autoTurn() {
            val n = model?.hero?.size ?: 0
            if (n > 1 && isShowing && pager.scrollState == RecyclerView.SCROLL_STATE_IDLE && !frame.hasFocus()) {
                val next = (heroPage + 1) % n
                if (next == 0) {
                    // Back to the first: a quick fade rather than sliding past every slide.
                    pager.animate().alpha(0f).setDuration(220).withEndAction {
                        pagerLayout.scrollToPosition(0)
                        heroPage = 0
                        paintDots()
                        pager.animate().alpha(1f).setDuration(320).start()
                    }.start()
                } else {
                    val slide = object : androidx.recyclerview.widget.LinearSmoothScroller(ctx) {
                        override fun calculateSpeedPerPixel(dm: android.util.DisplayMetrics): Float = 160f / dm.densityDpi
                    }
                    slide.targetPosition = next
                    pagerLayout.startSmoothScroll(slide)
                }
            }
            scheduleTurn()
        }

        fun bind(m: HomeModel) {
            val lp = frame.layoutParams
            val h = heroHeight()
            if (lp.height != h) {
                lp.height = h
                frame.layoutParams = lp
            }
            slides.submit(m.hero)
            pager.alpha = 1f
            if (heroPage >= m.hero.size) heroPage = 0
            pagerLayout.scrollToPosition(heroPage)
            paintDots()
        }

        private fun paintDots() {
            val n = model?.hero?.size ?: 0
            if (dots.childCount != n) {
                dots.removeAllViews()
                repeat(n) { dots.addView(View(ctx)) }
            }
            dots.visibility = if (n > 1) View.VISIBLE else View.GONE
            for (i in 0 until n) {
                val on = i == heroPage
                val d = dots.getChildAt(i)
                d.layoutParams = LinearLayout.LayoutParams(if (on) dp(22) else dp(6), dp(6)).apply {
                    marginStart = dp(3)
                    marginEnd = dp(3)
                }
                d.background = rounded(if (on) colors.ink else withAlpha(colors.ink, 0.35f), dp(3).toFloat())
            }
        }
    }

    private inner class SlidesAdapter : RecyclerView.Adapter<SlideHolder>() {
        private var items: List<HomeSlide> = emptyList()

        fun submit(s: List<HomeSlide>) {
            items = s
            notifyDataSetChanged()
        }

        override fun getItemCount() = items.size
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = SlideHolder()
        override fun onBindViewHolder(holder: SlideHolder, position: Int) = holder.bind(items[position])
        override fun onViewRecycled(holder: SlideHolder) {
            images.clear(holder.backdrop)
            images.clear(holder.logo)
        }
    }

    private inner class SlideHolder : RecyclerView.ViewHolder(FrameLayout(ctx)) {
        private val frame = itemView as FrameLayout
        val backdrop = NetImage(ctx)
        val logo = NetImage(ctx)
        private val topShade = View(ctx)
        private val bottomShade = View(ctx)
        private val content = LinearLayout(ctx)
        private val rank = label("", 12f, bold = true)
        private val title = label("", 34f, lines = 2)
        private val desc = label("", 14f, lines = 2)
        private val stats = LinearLayout(ctx)
        private val playBtn = LinearLayout(ctx)
        private val listBtn = LinearLayout(ctx)
        private val playText = label("", 14f, bold = true)
        private val listText = label("", 14f)
        private val playIcon = ImageView(ctx)
        private val listIcon = ImageView(ctx)

        init {
            frame.layoutParams = RecyclerView.LayoutParams(MATCH, MATCH)
            frame.isClickable = true
            frame.setOnClickListener { pos()?.let { act("hero", i = it, what = "open") } }
            backdrop.scaleType = ImageView.ScaleType.CENTER_CROP
            frame.addView(backdrop, FrameLayout.LayoutParams(MATCH, MATCH))
            frame.addView(topShade, FrameLayout.LayoutParams(MATCH, dp(112), Gravity.TOP))
            frame.addView(bottomShade, FrameLayout.LayoutParams(MATCH, MATCH, Gravity.BOTTOM))

            content.orientation = LinearLayout.VERTICAL
            content.gravity = Gravity.BOTTOM
            content.setPaddingRelative(gutter, 0, gutter, dp(40))
            frame.addView(content, FrameLayout.LayoutParams(MATCH, MATCH))

            rank.setPaddingRelative(dp(10), dp(4), dp(10), dp(4))
            content.addView(rank, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(10) })

            logo.scaleType = ImageView.ScaleType.FIT_START
            logo.adjustViewBounds = true
            logo.maxHeight = dp(84)
            content.addView(logo, LinearLayout.LayoutParams((width() * 0.7f).toInt(), dp(84)))
            title.typeface = Typeface.create(Typeface.SERIF, Typeface.NORMAL)
            title.setShadowLayer(dp(12).toFloat(), 0f, dp(3).toFloat(), 0x73000000)
            content.addView(title)
            content.addView(desc, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
            stats.orientation = LinearLayout.HORIZONTAL
            stats.gravity = Gravity.CENTER_VERTICAL
            content.addView(stats, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })

            val buttons = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
            for ((b, ic, t) in listOf(Triple(playBtn, playIcon, playText), Triple(listBtn, listIcon, listText))) {
                b.orientation = LinearLayout.HORIZONTAL
                b.gravity = Gravity.CENTER
                b.isClickable = true
                b.isFocusable = true
                b.addView(ic, LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginEnd = dp(8) })
                t.maxLines = 1
                t.ellipsize = TextUtils.TruncateAt.END
                b.addView(t)
            }
            playBtn.setOnClickListener { pos()?.let { act("hero", i = it, what = "play") } }
            listBtn.setOnClickListener { pos()?.let { act("hero", i = it, what = "list") } }
            buttons.addView(playBtn, LinearLayout.LayoutParams(0, dp(44), 1f).apply { marginEnd = dp(10) })
            buttons.addView(listBtn, LinearLayout.LayoutParams(0, dp(44), 1f))
            content.addView(buttons, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) })
        }

        private fun pos(): Int? = bindingAdapterPosition.takeIf { it != RecyclerView.NO_POSITION }

        fun bind(s: HomeSlide) {
            val m = model ?: return
            frame.setBackgroundColor(colors.canvas)
            frame.contentDescription = s.title
            topShade.background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(withAlpha(colors.canvas, 0.8f), Color.TRANSPARENT))
            bottomShade.background = GradientDrawable(
                GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(colors.canvas, withAlpha(colors.canvas, 0.85f), withAlpha(colors.canvas, 0.35f), Color.TRANSPARENT),
            )
            backdrop.alpha = 1f
            images.load(backdrop, s.images, width(), heroHeight())

            rank.visibility = if (s.rank != null) View.VISIBLE else View.GONE
            rank.text = s.rank ?: ""
            rank.setTextColor(colors.ink)
            rank.background = rounded(withAlpha(colors.canvas, 0.85f), dp(6).toFloat())

            title.text = s.title
            title.setTextColor(colors.ink)
            title.visibility = View.VISIBLE
            logo.scaleType = if (m.rtl) ImageView.ScaleType.FIT_END else ImageView.ScaleType.FIT_START
            logo.visibility = View.GONE
            if (s.logo != null) {
                logo.visibility = View.INVISIBLE
                images.load(logo, listOf(s.logo), (width() * 0.7f).toInt(), dp(84), alpha = true) { ok ->
                    logo.visibility = if (ok) View.VISIBLE else View.GONE
                    title.visibility = if (ok) View.GONE else View.VISIBLE
                }
            }
            desc.text = s.description ?: ""
            desc.visibility = if (s.description.isNullOrBlank()) View.GONE else View.VISIBLE
            desc.setTextColor(colors.muted)

            stats.removeAllViews()
            s.year?.let { stats.addView(stat(m.label("year", "Year"), it)) }
            s.rating?.let { stats.addView(imdbBadge(it, 13f)) }
            s.runtime?.let { stats.addView(stat(m.label("runtime", "Runtime"), it)) }
            stats.visibility = if (stats.childCount > 0) View.VISIBLE else View.GONE

            playBtn.background = focusable(rounded(colors.ink, dp(22).toFloat()))
            playIcon.setImageDrawable(icon(R.drawable.ic_play, colors.canvas))
            playText.text = m.label("play", "Play")
            playText.setTextColor(colors.canvas)
            listBtn.background = focusable(rounded(withAlpha(colors.canvas, 0.55f), dp(22).toFloat(), dp(1), withAlpha(colors.ink, 0.25f)))
            listIcon.setImageDrawable(icon(if (s.inList) R.drawable.ic_check else R.drawable.ic_plus, colors.ink))
            listText.text = if (s.inList) m.label("inList", "In Watchlist") else m.label("add", "Add to Watchlist")
            listText.setTextColor(colors.ink)
        }

        private fun stat(name: String, value: String): View = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(label("$name: ", 13f).apply { setTextColor(colors.subtle) })
            addView(label(value, 13f).apply { setTextColor(colors.ink) })
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(18) }
        }
    }

    // ---- a row: title + sideways cards -----------------------------------------------------------

    private inner class RowHolder : RecyclerView.ViewHolder(LinearLayout(ctx)) {
        private val col = itemView as LinearLayout
        private val header = LinearLayout(ctx)
        private val title = label("", 17f, bold = true, lines = 1)
        private val seeAll = label("", 12.5f, lines = 1)
        private val strip = RecyclerView(ctx)
        private val layout = LinearLayoutManager(ctx, RecyclerView.HORIZONTAL, false).apply { initialPrefetchItemCount = 5 }
        private val cards = CardsAdapter()
        private var boundKey: String? = null
        /** The editor's controls for the row (up, down, hide, Top 10 look, hero, rename, delete). */
        private val controls = LinearLayout(ctx)
        /** Critics' Pick: its own card instead of the strip (made the first time one is shown). */
        private var critic: CriticCard? = null

        init {
            col.orientation = LinearLayout.VERTICAL
            col.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            col.setPadding(0, 0, 0, dp(26))
            header.orientation = LinearLayout.HORIZONTAL
            header.gravity = Gravity.CENTER_VERTICAL
            header.setPaddingRelative(gutter, 0, gutter, 0)
            header.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            header.addView(seeAll)
            header.setOnClickListener { boundKey?.let { k -> act("all", row = k) } }
            col.addView(header, LinearLayout.LayoutParams(MATCH, dp(40)).apply { bottomMargin = dp(6) })
            controls.orientation = LinearLayout.HORIZONTAL
            controls.gravity = Gravity.CENTER_VERTICAL
            controls.visibility = View.GONE
            col.addView(controls, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(44)).apply {
                marginStart = gutter
                marginEnd = gutter
                bottomMargin = dp(10)
            })

            strip.layoutManager = layout
            strip.adapter = cards
            strip.setRecycledViewPool(cardPool)
            strip.clipToPadding = false
            strip.setPaddingRelative(gutter, dp(4), gutter - gap, dp(4))
            strip.overScrollMode = View.OVER_SCROLL_NEVER
            strip.isHorizontalScrollBarEnabled = false
            strip.isNestedScrollingEnabled = false
            strip.itemAnimator = null
            strip.addOnScrollListener(object : RecyclerView.OnScrollListener() {
                override fun onScrolled(rv: RecyclerView, dx: Int, dy: Int) = maybeAskMore()
            })
            col.addView(strip, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT))
        }

        fun bind(row: HomeRow) {
            val m = model ?: return
            if (boundKey != row.key) {
                saveScroll()
                boundKey = row.key
                cards.submit(row)
                val saved = rowScroll[row.key]
                if (saved != null) layout.onRestoreInstanceState(saved) else layout.scrollToPosition(0)
            } else {
                cards.submit(row)
            }
            title.text = row.title
            title.setTextColor(colors.ink)
            val ed = if (m.edit) row.edit else null
            val hidden = ed?.hidden == true
            // The end of the title line: "See all", or the row's small note (Critics' Pick).
            val note = row.note
            if (row.seeAll && ed == null) {
                seeAll.text = m.label("seeAll", "See all") + " ›"
                seeAll.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                seeAll.letterSpacing = 0f
                seeAll.visibility = View.VISIBLE
            } else if (note != null && ed == null) {
                // Small capitals like the page's (Arabic has no case, and its letters stay joined).
                seeAll.text = if (m.rtl) note else note.uppercase()
                seeAll.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                seeAll.letterSpacing = if (m.rtl) 0f else 0.14f
                seeAll.visibility = View.VISIBLE
            } else {
                seeAll.visibility = View.GONE
            }
            seeAll.setTextColor(colors.subtle)
            header.isClickable = row.seeAll && ed == null
            header.isFocusable = row.seeAll && ed == null
            // A hidden row in the editor: its name dimmed and its controls, no cards.
            title.alpha = if (hidden) 0.45f else 1f
            val info = row.critic
            val isCritic = row.kind == HomeRow.Kind.CRITIC
            strip.visibility = if (hidden || isCritic || row.items.isEmpty()) View.GONE else View.VISIBLE
            if (isCritic && info != null && !hidden) {
                val card = critic ?: CriticCard().also {
                    critic = it
                    col.addView(it.view, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT))
                }
                card.view.visibility = View.VISIBLE
                card.bind(m, row.key, info)
            } else {
                critic?.view?.visibility = View.GONE
            }
            bindControls(m, row, ed)
            strip.post { maybeAskMore() }
        }

        private fun bindControls(m: HomeModel, row: HomeRow, ed: RowEdit?) {
            controls.removeAllViews()
            if (ed == null) {
                controls.visibility = View.GONE
                return
            }
            controls.visibility = View.VISIBLE
            controls.background = rounded(withAlpha(colors.surface, 0.9f), dp(12).toFloat(), dp(1), withAlpha(colors.ink, 0.08f))
            controls.setPaddingRelative(dp(4), 0, dp(4), 0)
            fun button(ic: Int, desc: String, enabled: Boolean = true, on: Boolean = false, what: String, extra: (() -> Unit)? = null) {
                val b = FrameLayout(ctx).apply {
                    isClickable = enabled
                    isFocusable = enabled
                    contentDescription = desc
                    alpha = if (enabled) 1f else 0.3f
                    background = if (on) rounded(withAlpha(colors.accent, 0.22f), dp(10).toFloat()) else null
                    addView(ImageView(ctx).apply { setImageDrawable(icon(ic, if (on) colors.accent else colors.muted)) }, FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER))
                    setOnClickListener { if (extra != null) extra() else act("edit", row = row.key, what = what) }
                }
                controls.addView(b, LinearLayout.LayoutParams(dp(40), dp(40)))
            }
            if (!ed.pinned) {
                button(R.drawable.ic_arrow_up, m.label("up", "Move up"), enabled = ed.up, what = "up")
                button(R.drawable.ic_arrow_down, m.label("down", "Move down"), enabled = ed.down, what = "down")
            }
            button(
                if (ed.hidden) R.drawable.ic_eye_off else R.drawable.ic_eye,
                if (ed.hidden) m.label("show", "Show row") else m.label("hide", "Hide row"),
                on = ed.hidden,
                what = "hide",
            )
            if (!ed.pinned) {
                if (ed.numerals >= 0) button(R.drawable.ic_list_ordered, m.label("numerals", "Top 10 look"), on = ed.numerals == 1, what = "num")
                if (ed.hero >= 0) button(R.drawable.ic_sparkles, m.label("heroSource", "Feature in the hero"), on = ed.hero == 1, what = "hero")
                button(R.drawable.ic_pencil, m.label("rename", "Rename row"), on = ed.renamed, what = "rename") { rename(m, row, ed) }
                if (ed.delete) button(R.drawable.ic_trash_2, m.label("delete", "Delete"), what = "del")
            }
        }

        /** The row's new name; empty (or "Reset") = its own name again. */
        private fun rename(m: HomeModel, row: HomeRow, ed: RowEdit) {
            val input = android.widget.EditText(ctx).apply {
                setText(row.title)
                setSelection(text.length)
                setSingleLine(true)
            }
            val frame = FrameLayout(ctx).apply {
                setPadding(dp(20), dp(8), dp(20), 0)
                addView(input)
            }
            val b = android.app.AlertDialog.Builder(ctx)
                .setTitle(m.label("rename", "Rename row"))
                .setView(frame)
                .setPositiveButton(m.label("save", "Save")) { _, _ ->
                    act("edit", row = row.key, what = "rename", text = input.text.toString().trim())
                }
                .setNegativeButton(m.label("cancel", "Cancel"), null)
            if (ed.renamed) b.setNeutralButton(m.label("resetName", "Reset name")) { _, _ -> act("edit", row = row.key, what = "rename", text = "") }
            try {
                b.show()
            } catch (_: Exception) {
            }
        }

        fun saveScroll() {
            val k = boundKey ?: return
            rowScroll[k] = layout.onSaveInstanceState()
        }

        private fun maybeAskMore() {
            val row = cards.row ?: return
            if (!row.more) return
            val last = layout.findLastVisibleItemPosition()
            if (last == RecyclerView.NO_POSITION || last < row.items.size - 6) return
            if (askedMore[row.key] == row.items.size) return
            askedMore[row.key] = row.items.size
            act("more", row = row.key)
        }
    }

    // ---- cards -----------------------------------------------------------------------------------

    private inner class CardsAdapter : RecyclerView.Adapter<CardHolder>() {
        var row: HomeRow? = null
            private set

        fun submit(r: HomeRow) {
            row = r
            notifyDataSetChanged()
        }

        override fun getItemCount() = row?.items?.size ?: 0
        override fun getItemViewType(position: Int) = when (row?.kind) {
            HomeRow.Kind.CW -> C_CW
            HomeRow.Kind.RANK -> C_RANK
            HomeRow.Kind.TILE -> C_TILE
            HomeRow.Kind.LOGO -> C_LOGO
            HomeRow.Kind.FEATURE -> C_FEATURE
            else -> C_POSTER
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = CardHolder(viewType)
        override fun onBindViewHolder(holder: CardHolder, position: Int) {
            val r = row ?: return
            holder.bind(r, r.items[position])
        }

        override fun onViewRecycled(holder: CardHolder) = images.clear(holder.image)
    }

    private inner class CardHolder(private val kind: Int) : RecyclerView.ViewHolder(LinearLayout(ctx)) {
        private val col = itemView as LinearLayout
        private val box = FrameLayout(ctx)
        val image = NetImage(ctx)
        private val title = label("", 13f, lines = if (kind == C_CW) 1 else 2)
        private val badge = LinearLayout(ctx)
        private val rankNumber = label("", 32f, bold = true, lines = 1)
        /** Top 10: the number and the title, side by side under the poster. */
        private val rankLine = LinearLayout(ctx)
        private val sub = label("", 11f, lines = 1)
        private val track = FrameLayout(ctx)
        private val bar = View(ctx)
        private val play = FrameLayout(ctx)
        private val shade = View(ctx)
        /** The "watched" check (as on the page's posters). */
        private val check = FrameLayout(ctx)
        /** Tiles and the feature card: their name (and a line under it) on the picture. */
        private val overlay = LinearLayout(ctx)
        private val bigTitle = label("", if (kind == C_FEATURE) 24f else 17f, lines = 2)
        private val bigSub = label("", if (kind == C_FEATURE) 13.5f else 11.5f, lines = if (kind == C_FEATURE) 3 else 1)
        private var row: HomeRow? = null
        private val titleBelow get() = kind == C_POSTER || kind == C_RANK || kind == C_CW
        /** The picture's rounded frame. */
        private val frame: FrameLayout = box
        /** The wide card: a label on top, the rating, a Play button. */
        private val kicker = label("", 11.5f, bold = true, lines = 1)
        private val stats = LinearLayout(ctx)
        private val featurePlay = LinearLayout(ctx)

        init {
            col.orientation = LinearLayout.VERTICAL
            col.layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = gap }
            col.isClickable = true
            col.isFocusable = true
            col.setOnClickListener { tap("open") }
            col.setOnLongClickListener {
                tap("hold")
                true
            }
            col.setOnFocusChangeListener { _, has -> frame.foreground = if (has) ring() else null }

            frame.clipToOutline = true
            frame.outlineProvider = roundOutline(dp(12).toFloat())
            image.scaleType = ImageView.ScaleType.CENTER_CROP
            col.addView(box)
            frame.addView(image, FrameLayout.LayoutParams(MATCH, MATCH))

            when (kind) {
                C_CW -> {
                    box.addView(shade, FrameLayout.LayoutParams(MATCH, MATCH, Gravity.BOTTOM))
                    sub.setPaddingRelative(dp(8), dp(3), dp(8), dp(3))
                    box.addView(sub, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START).apply {
                        marginStart = dp(8)
                        bottomMargin = dp(10)
                    })
                    track.addView(bar, FrameLayout.LayoutParams(0, MATCH, Gravity.START))
                    box.addView(track, FrameLayout.LayoutParams(MATCH, dp(3), Gravity.BOTTOM))
                    play.isClickable = true
                    play.isFocusable = true
                    play.setOnClickListener { tap("play") }
                    play.addView(ImageView(ctx).apply { tag = "ic" }, FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
                    box.addView(play, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER))
                }
                C_RANK -> Unit
                C_TILE, C_FEATURE -> {
                    box.addView(shade, FrameLayout.LayoutParams(MATCH, MATCH))
                    overlay.orientation = LinearLayout.VERTICAL
                    val pad = if (kind == C_FEATURE) dp(18) else dp(14)
                    overlay.setPaddingRelative(pad, 0, pad, if (kind == C_FEATURE) dp(16) else dp(12))
                    bigTitle.typeface = Typeface.create(Typeface.SERIF, Typeface.NORMAL)
                    bigTitle.setShadowLayer(dp(10).toFloat(), 0f, dp(2).toFloat(), 0x99000000.toInt())
                    overlay.addView(bigTitle)
                    if (kind == C_FEATURE) {
                        stats.orientation = LinearLayout.HORIZONTAL
                        stats.gravity = Gravity.CENTER_VERTICAL
                        overlay.addView(stats, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
                    }
                    overlay.addView(bigSub, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
                    if (kind == C_FEATURE) {
                        featurePlay.orientation = LinearLayout.HORIZONTAL
                        featurePlay.gravity = Gravity.CENTER
                        featurePlay.isClickable = true
                        featurePlay.isFocusable = true
                        featurePlay.setPaddingRelative(dp(18), 0, dp(20), 0)
                        featurePlay.setOnClickListener { tap("play") }
                        featurePlay.addView(ImageView(ctx).apply { tag = "ic" }, LinearLayout.LayoutParams(dp(16), dp(16)).apply { marginEnd = dp(8) })
                        featurePlay.addView(label("", 14f, bold = true, lines = 1).apply { tag = "tx" })
                        overlay.addView(featurePlay, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(42)).apply { topMargin = dp(14) })
                        kicker.setPaddingRelative(dp(10), dp(4), dp(10), dp(4))
                        box.addView(kicker, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
                            marginStart = dp(16)
                            topMargin = dp(16)
                        })
                    }
                    box.addView(overlay, FrameLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
                }
                C_LOGO -> {
                    image.scaleType = ImageView.ScaleType.FIT_CENTER
                    val pad = dp(22)
                    image.setPadding(pad, pad, pad, pad)
                    bigTitle.gravity = Gravity.CENTER
                    box.addView(bigTitle, FrameLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
                }
                else -> {
                    badge.orientation = LinearLayout.HORIZONTAL
                    badge.gravity = Gravity.CENTER_VERTICAL
                    box.addView(badge, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
                        marginEnd = dp(6)
                        bottomMargin = dp(6)
                        topMargin = dp(6)
                    })
                }
            }
            if (kind == C_POSTER || kind == C_RANK) {
                check.visibility = View.GONE
                check.addView(ImageView(ctx).apply { tag = "ic" }, FrameLayout.LayoutParams(dp(13), dp(13), Gravity.CENTER))
                // Bottom-start, like the page's posters.
                frame.addView(check, FrameLayout.LayoutParams(dp(22), dp(22), Gravity.BOTTOM or Gravity.START).apply {
                    marginStart = dp(6)
                    marginEnd = dp(6)
                    topMargin = dp(6)
                    bottomMargin = dp(6)
                })
            }
            if (kind == C_RANK) {
                // Top 10: the whole poster clear; under it the number, big and bold in the
                // accent colour (two digits read as easily as one), the title beside it.
                rankNumber.includeFontPadding = false
                rankNumber.typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD)
                rankNumber.maxLines = 1
                rankNumber.ellipsize = null
                rankLine.orientation = LinearLayout.HORIZONTAL
                rankLine.gravity = Gravity.CENTER_VERTICAL
                rankLine.addView(rankNumber, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                rankLine.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(8) })
                col.addView(rankLine, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
            } else {
                col.addView(title, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
            }
            if (!titleBelow) title.visibility = View.GONE
        }

        private fun tap(what: String) {
            val r = row ?: return
            val p = bindingAdapterPosition
            if (p == RecyclerView.NO_POSITION) return
            act(what, row = r.key, i = p)
        }

        fun bind(r: HomeRow, c: HomeCard) {
            row = r
            val w = when (kind) {
                C_CW -> cwWidth()
                C_RANK -> rankWidth()
                C_TILE -> tileWidth()
                C_LOGO -> logoWidth()
                C_FEATURE -> featureWidth()
                else -> posterWidth()
            }
            val posterW = w
            val h = when (kind) {
                C_CW -> w * 9 / 16
                C_TILE -> w * 4 / 5
                C_LOGO -> dp(80)
                C_FEATURE -> max(min(w * 10 / 16, dp(440)), dp(300))
                else -> w * 3 / 2
            }
            val lp = box.layoutParams as LinearLayout.LayoutParams
            if (lp.width != w || lp.height != h) {
                lp.width = w
                lp.height = h
                box.layoutParams = lp
            }
            if (kind == C_RANK) {
                rankNumber.setTextSize(TypedValue.COMPLEX_UNIT_PX, (w * 0.3f).coerceIn(dp(26).toFloat(), dp(48).toFloat()))
            } else {
                val tlp = title.layoutParams as LinearLayout.LayoutParams
                if (tlp.width != posterW) {
                    tlp.width = posterW
                    title.layoutParams = tlp
                }
            }
            col.contentDescription = c.title
            val tint = c.tint
            frame.background = if (kind == C_TILE && c.emblem && tint != null) {
                // An award: its colour lit from the top corner, deep at the bottom (like the page's).
                GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(tint, toward(tint, Color.BLACK, 0.6f))).apply {
                    cornerRadius = dp(12).toFloat()
                }
            } else {
                rounded(
                    when (kind) {
                        C_LOGO -> withAlpha(colors.surface, 0.9f)
                        else -> tint ?: plate(c.title)
                    },
                    dp(12).toFloat(),
                )
            }
            frame.foreground = if (col.isFocused) ring() else null
            // Award tiles: the emblem whole in the top part; other tiles: the picture fills them.
            if (kind == C_TILE) {
                val ilp = image.layoutParams as FrameLayout.LayoutParams
                val wantH = if (c.emblem) (h * 0.66f).toInt() else MATCH
                if (ilp.height != wantH) {
                    ilp.height = wantH
                    ilp.gravity = Gravity.TOP
                    image.layoutParams = ilp
                }
                image.scaleType = if (c.emblem) ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
                val pad = if (c.emblem) dp(14) else 0
                image.setPadding(pad, pad, pad, 0)
            }
            images.load(image, c.images, posterW, h, alpha = kind == C_LOGO || c.emblem) { ok ->
                // A logo that didn't come: its name instead.
                if (kind == C_LOGO) bigTitle.visibility = if (ok) View.GONE else View.VISIBLE
            }
            title.text = c.title
            title.setTextColor(colors.ink)
            if (kind == C_POSTER || kind == C_RANK) {
                title.minLines = 2
                check.visibility = if (c.watched) View.VISIBLE else View.GONE
                if (c.watched) {
                    check.background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                    }.also { it.setColor(colors.accent); it.setStroke(dp(2), withAlpha(colors.canvas, 0.7f)) }
                    check.findViewWithTag<ImageView>("ic")?.setImageDrawable(icon(R.drawable.ic_check, colors.canvas))
                    check.contentDescription = model?.label("watched", "Watched")
                }
            }

            when (kind) {
                C_CW -> {
                    shade.background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP, intArrayOf(withAlpha(colors.canvas, 0.8f), Color.TRANSPARENT))
                    sub.text = c.sub ?: ""
                    sub.visibility = if (c.sub.isNullOrBlank()) View.GONE else View.VISIBLE
                    sub.setTextColor(colors.ink)
                    sub.background = rounded(withAlpha(colors.canvas, 0.95f), dp(6).toFloat())
                    track.setBackgroundColor(withAlpha(colors.canvas, 0.4f))
                    bar.setBackgroundColor(colors.accent)
                    val blp = bar.layoutParams
                    blp.width = (w * c.progress).toInt()
                    bar.layoutParams = blp
                    play.background = focusable(rounded(withAlpha(colors.canvas, 0.85f), dp(24).toFloat(), dp(1), withAlpha(colors.ink, 0.15f)))
                    play.contentDescription = model?.label("play", "Play")
                    play.findViewWithTag<ImageView>("ic")?.setImageDrawable(icon(R.drawable.ic_play, colors.ink))
                }
                C_RANK -> {
                    rankNumber.text = if (c.rank > 0) c.rank.toString() else ""
                    rankNumber.setTextColor(colors.accent)
                }
                C_TILE, C_FEATURE -> {
                    // Tiles: the picture washed with the tile's colour all over (more at the bottom,
                    // under the name); an emblem stays clear. The feature card: like the hero, the
                    // picture clear at the top and dark under its text.
                    val base = c.tint ?: colors.canvas
                    shade.background = GradientDrawable(
                        GradientDrawable.Orientation.BOTTOM_TOP,
                        when {
                            kind == C_FEATURE -> intArrayOf(colors.canvas, withAlpha(colors.canvas, 0.85f), withAlpha(colors.canvas, 0.25f), Color.TRANSPARENT)
                            c.emblem -> intArrayOf(withAlpha(toward(base, Color.BLACK, 0.6f), 0.7f), Color.TRANSPARENT)
                            else -> intArrayOf(withAlpha(base, 0.95f), withAlpha(base, 0.6f), withAlpha(base, 0.45f))
                        },
                    )
                    bigTitle.text = c.title
                    bigTitle.setTextColor(Color.WHITE)
                    bigSub.text = c.sub ?: ""
                    bigSub.visibility = if (c.sub.isNullOrBlank()) View.GONE else View.VISIBLE
                    bigSub.setTextColor(withAlpha(Color.WHITE, 0.75f))
                    if (kind == C_FEATURE) {
                        kicker.text = c.kicker ?: ""
                        kicker.visibility = if (c.kicker.isNullOrBlank()) View.GONE else View.VISIBLE
                        kicker.setTextColor(colors.ink)
                        kicker.background = rounded(withAlpha(colors.canvas, 0.85f), dp(6).toFloat())
                        stats.removeAllViews()
                        c.rating?.let { stats.addView(imdbBadge(it, 13f, trailing = 0)) }
                        stats.visibility = if (stats.childCount > 0) View.VISIBLE else View.GONE
                        featurePlay.visibility = if (c.play) View.VISIBLE else View.GONE
                        featurePlay.background = focusable(rounded(colors.ink, dp(21).toFloat()))
                        featurePlay.findViewWithTag<ImageView>("ic")?.setImageDrawable(icon(R.drawable.ic_play, colors.canvas))
                        featurePlay.findViewWithTag<TextView>("tx")?.apply {
                            text = model?.label("play", "Play")
                            setTextColor(colors.canvas)
                        }
                    }
                }
                C_LOGO -> {
                    bigTitle.text = c.title
                    bigTitle.setTextColor(colors.ink)
                }
                else -> {
                    badge.removeAllViews()
                    if (c.rating != null) {
                        badge.visibility = View.VISIBLE
                        // In the poster's corner (bottom, or top per Settings), nothing pushing it in.
                        badge.addView(imdbBadge(c.rating, 9.5f, trailing = 0))
                        val blp = badge.layoutParams as FrameLayout.LayoutParams
                        val g = (if (model?.badgesTop == true) Gravity.TOP else Gravity.BOTTOM) or Gravity.END
                        if (blp.gravity != g) {
                            blp.gravity = g
                            badge.layoutParams = blp
                        }
                    } else {
                        badge.visibility = View.GONE
                    }
                }
            }
        }
    }

    // ---- Critics' Pick ---------------------------------------------------------------------------

    /** Which review each Critics' Pick shows (its arrows page through them). */
    private val criticReview = HashMap<String, Int>()

    /**
     * Critics' Pick, like the page's card: the title's picture with its logo (or name), year and
     * IMDb rating; under it the review (paged, "Read full"), four stills (full screen on a tap),
     * the cast, the director, the genres and Play.
     */
    private inner class CriticCard {
        val view = LinearLayout(ctx)
        private var rowKey = ""
        private var info: CriticInfo? = null
        private val poster = FrameLayout(ctx)
        private val backdrop = NetImage(ctx)
        private val shade = View(ctx)
        private val logo = NetImage(ctx)
        private val bigTitle = label("", 28f, lines = 2)
        private val posterStats = LinearLayout(ctx)
        private val panel = LinearLayout(ctx)
        private val quoteIcon = ImageView(ctx)
        private val quote = label("", 15f, lines = 5)
        private val byline = LinearLayout(ctx)
        private val author = label("", 11f, lines = 1)
        private val source = ImageView(ctx)
        private val pager = LinearLayout(ctx)
        private val prev = ImageView(ctx)
        private val count = label("", 10.5f, lines = 1)
        private val next = ImageView(ctx)
        private val readFull = label("", 11.5f, bold = true, lines = 1)
        private val stills = LinearLayout(ctx)
        private val stillViews = List(4) { NetImage(ctx) }
        private val castLabel = label("", 10.5f, lines = 1)
        private val castScroll = android.widget.HorizontalScrollView(ctx)
        private val castStrip = LinearLayout(ctx)
        private val directorRow = LinearLayout(ctx)
        private val directorLabel = label("", 10.5f, lines = 1)
        private val directorName = label("", 13f, lines = 1)
        private val genres = LinearLayout(ctx)
        private val play = LinearLayout(ctx)
        private val playIcon = ImageView(ctx)
        private val playText = label("", 13.5f, bold = true, lines = 1)

        init {
            view.orientation = LinearLayout.VERTICAL
            view.setPaddingRelative(gutter, dp(4), gutter, 0)

            // The title's picture.
            poster.isClickable = true
            poster.isFocusable = true
            poster.setOnClickListener { act("open", row = rowKey, i = 0) }
            poster.setOnFocusChangeListener { _, has -> poster.foreground = if (has) ring() else null }
            poster.clipToOutline = true
            poster.outlineProvider = roundOutline(dp(16).toFloat())
            backdrop.scaleType = ImageView.ScaleType.CENTER_CROP
            poster.addView(backdrop, FrameLayout.LayoutParams(MATCH, MATCH))
            poster.addView(shade, FrameLayout.LayoutParams(MATCH, MATCH))
            val text = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPaddingRelative(dp(20), 0, dp(20), dp(20))
            }
            logo.scaleType = ImageView.ScaleType.FIT_START
            text.addView(logo, LinearLayout.LayoutParams(MATCH, dp(72)))
            bigTitle.typeface = Typeface.create(Typeface.SERIF, Typeface.NORMAL)
            bigTitle.setShadowLayer(dp(12).toFloat(), 0f, dp(2).toFloat(), 0x8C000000.toInt())
            text.addView(bigTitle)
            posterStats.orientation = LinearLayout.HORIZONTAL
            posterStats.gravity = Gravity.CENTER_VERTICAL
            text.addView(posterStats, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })
            poster.addView(text, FrameLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
            view.addView(poster, LinearLayout.LayoutParams(MATCH, dp(300)))

            // The panel under it.
            panel.orientation = LinearLayout.VERTICAL
            panel.setPadding(dp(20), dp(20), dp(20), dp(20))
            view.addView(panel, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) })
            panel.addView(quoteIcon, LinearLayout.LayoutParams(dp(22), dp(22)))
            quote.typeface = Typeface.create(Typeface.SERIF, Typeface.ITALIC)
            quote.setLineSpacing(0f, 1.25f)
            quote.setOnClickListener { showFull() }
            panel.addView(quote, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })

            byline.orientation = LinearLayout.HORIZONTAL
            byline.gravity = Gravity.CENTER_VERTICAL
            byline.addView(author, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            source.setPadding(dp(4), dp(4), dp(4), dp(4))
            source.isClickable = true
            source.isFocusable = true
            source.setOnClickListener { currentReview()?.url?.let { act("link", row = rowKey, text = it) } }
            byline.addView(source, LinearLayout.LayoutParams(dp(24), dp(24)).apply { marginStart = dp(2) })
            pager.orientation = LinearLayout.HORIZONTAL
            pager.gravity = Gravity.CENTER_VERTICAL
            for (b in listOf(prev, next)) {
                b.setPadding(dp(5), dp(5), dp(5), dp(5))
                b.isClickable = true
                b.isFocusable = true
            }
            prev.setOnClickListener { step(-1) }
            next.setOnClickListener { step(1) }
            pager.addView(prev, LinearLayout.LayoutParams(dp(26), dp(26)))
            pager.addView(count)
            pager.addView(next, LinearLayout.LayoutParams(dp(26), dp(26)))
            byline.addView(pager, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8) })
            readFull.isClickable = true
            readFull.isFocusable = true
            readFull.setPaddingRelative(dp(8), dp(6), 0, dp(6))
            readFull.setOnClickListener { showFull() }
            byline.addView(readFull)
            panel.addView(byline, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })

            stills.orientation = LinearLayout.VERTICAL
            for (r in 0 until 2) {
                val line = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
                for (c in 0 until 2) {
                    val i = r * 2 + c
                    val v = stillViews[i]
                    v.scaleType = ImageView.ScaleType.CENTER_CROP
                    v.clipToOutline = true
                    v.outlineProvider = roundOutline(dp(10).toFloat())
                    v.isClickable = true
                    v.isFocusable = true
                    v.setOnClickListener { info?.let { showStills(it.stills.ifEmpty { it.images.take(1) }, i) } }
                    line.addView(v, LinearLayout.LayoutParams(0, dp(80), 1f).apply { if (c == 0) marginEnd = dp(6) })
                }
                stills.addView(line, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { if (r == 0) bottomMargin = dp(6) })
            }
            panel.addView(stills, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

            panel.addView(castLabel, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) })
            castScroll.isHorizontalScrollBarEnabled = false
            castScroll.overScrollMode = View.OVER_SCROLL_NEVER
            castStrip.orientation = LinearLayout.HORIZONTAL
            castScroll.addView(castStrip)
            panel.addView(castScroll, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })

            directorRow.orientation = LinearLayout.HORIZONTAL
            directorRow.gravity = Gravity.CENTER_VERTICAL
            directorRow.addView(directorLabel, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            directorName.isClickable = true
            directorName.isFocusable = true
            directorRow.addView(directorName)
            panel.addView(directorRow, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) })
            genres.orientation = LinearLayout.HORIZONTAL
            panel.addView(genres, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })

            play.orientation = LinearLayout.HORIZONTAL
            play.gravity = Gravity.CENTER
            play.isClickable = true
            play.isFocusable = true
            play.setPaddingRelative(dp(20), 0, dp(24), 0)
            play.setOnClickListener { act("play", row = rowKey, i = 0) }
            play.addView(playIcon, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginEnd = dp(8) })
            play.addView(playText)
            panel.addView(play, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(42)).apply {
                topMargin = dp(20)
                gravity = Gravity.END
            })
        }

        private fun reviews() = info?.reviews ?: emptyList()
        private fun index(): Int = (criticReview[rowKey] ?: 0).coerceIn(0, max(0, reviews().size - 1))
        private fun currentReview(): CriticReview? = reviews().getOrNull(index())

        private fun step(d: Int) {
            val n = reviews().size
            if (n < 2) return
            criticReview[rowKey] = (index() + d + n) % n
            model?.let { paintReview(it) }
        }

        fun bind(m: HomeModel, key: String, c: CriticInfo) {
            rowKey = key
            info = c
            val cardW = width() - 2 * gutter
            val posterH = max(dp(300), min(cardW * 9 / 16, dp(460)))
            val plp = poster.layoutParams
            if (plp.height != posterH) {
                plp.height = posterH
                poster.layoutParams = plp
            }
            poster.background = rounded(colors.surface, dp(16).toFloat())
            poster.contentDescription = c.title
            shade.background = GradientDrawable(
                GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(withAlpha(colors.canvas, 0.92f), withAlpha(colors.canvas, 0.3f), Color.TRANSPARENT),
            )
            images.load(backdrop, c.images, cardW, posterH)
            bigTitle.text = c.title
            bigTitle.setTextColor(colors.ink)
            bigTitle.visibility = View.VISIBLE
            logo.scaleType = if (m.rtl) ImageView.ScaleType.FIT_END else ImageView.ScaleType.FIT_START
            logo.visibility = View.GONE
            if (c.logo != null) {
                logo.visibility = View.INVISIBLE
                images.load(logo, listOf(c.logo), (cardW * 0.6f).toInt(), dp(72), alpha = true) { ok ->
                    logo.visibility = if (ok) View.VISIBLE else View.GONE
                    bigTitle.visibility = if (ok) View.GONE else View.VISIBLE
                }
            }
            posterStats.removeAllViews()
            c.year?.let {
                posterStats.addView(label(it, 13f, lines = 1).apply { setTextColor(withAlpha(colors.ink, 0.8f)) },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(10) })
            }
            c.rating?.let { posterStats.addView(imdbBadge(it, 12.5f, trailing = 0)) }
            posterStats.visibility = if (posterStats.childCount > 0) View.VISIBLE else View.GONE

            panel.background = rounded(withAlpha(colors.surface, 0.55f), dp(16).toFloat(), dp(1), withAlpha(colors.ink, 0.08f))
            quoteIcon.setImageDrawable(icon(R.drawable.ic_quote, colors.accent))
            paintReview(m)

            // Four stills, two by two (the title's picture where there are fewer).
            val inner = cardW - dp(40)
            val stillH = (inner - dp(6)) / 2 * 9 / 16
            val shots = c.stills
            stills.visibility = if (shots.isEmpty()) View.GONE else View.VISIBLE
            stillViews.forEachIndexed { i, v ->
                val lp = v.layoutParams
                if (lp.height != stillH) {
                    lp.height = stillH
                    v.layoutParams = lp
                }
                v.background = rounded(colors.surface, dp(10).toFloat())
                val src = shots.getOrNull(i) ?: c.images.firstOrNull()
                if (shots.isNotEmpty() && src != null) images.load(v, listOf(src), inner / 2, stillH) else images.clear(v)
            }

            castLabel.text = caps(m, c.castTitle ?: m.label("cast", "Cast"))
            castLabel.setTextColor(colors.subtle)
            castLabel.letterSpacing = if (m.rtl) 0f else 0.2f
            castStrip.removeAllViews()
            for (p in c.cast) castStrip.addView(castChip(p))
            castLabel.visibility = if (c.cast.isEmpty()) View.GONE else View.VISIBLE
            castScroll.visibility = castLabel.visibility

            val d = c.director
            directorRow.visibility = if (d == null) View.GONE else View.VISIBLE
            directorLabel.text = caps(m, m.label("director", "Director"))
            directorLabel.setTextColor(colors.subtle)
            directorLabel.letterSpacing = if (m.rtl) 0f else 0.2f
            directorName.text = d?.name ?: ""
            directorName.setTextColor(colors.ink)
            directorName.setOnClickListener { d?.let { act("person", row = rowKey, what = it.id.toString()) } }

            genres.removeAllViews()
            for (g in c.genres.take(3)) {
                genres.addView(label(g, 11.5f, lines = 1).apply {
                    setTextColor(colors.muted)
                    setPaddingRelative(dp(10), dp(3), dp(10), dp(3))
                    background = rounded(Color.TRANSPARENT, dp(12).toFloat(), dp(1), withAlpha(colors.ink, 0.12f))
                }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(6) })
            }
            genres.visibility = if (genres.childCount > 0) View.VISIBLE else View.GONE

            play.background = focusable(rounded(colors.ink, dp(21).toFloat()))
            playIcon.setImageDrawable(icon(R.drawable.ic_play, colors.canvas))
            playText.text = m.label("play", "Play")
            playText.setTextColor(colors.canvas)
        }

        private fun paintReview(m: HomeModel) {
            val c = info ?: return
            val r = currentReview()
            quote.text = r?.text ?: c.quote ?: ""
            quote.setTextColor(withAlpha(colors.ink, 0.9f))
            quote.visibility = if (quote.text.isNullOrBlank()) View.GONE else View.VISIBLE
            author.text = if (r == null) "" else caps(m, listOfNotNull(r.author, r.score).joinToString(" · "))
            author.setTextColor(colors.muted)
            author.letterSpacing = if (m.rtl) 0f else 0.12f
            source.visibility = if (r?.url != null) View.VISIBLE else View.GONE
            source.setImageDrawable(icon(R.drawable.ic_external_link, colors.subtle))
            source.contentDescription = m.label("source", "Open review source")
            val n = reviews().size
            pager.visibility = if (n > 1) View.VISIBLE else View.GONE
            prev.setImageDrawable(icon(R.drawable.ic_chevron_left, colors.subtle))
            next.setImageDrawable(icon(R.drawable.ic_chevron_right, colors.subtle))
            // The arrows point the way they move in a right-to-left page too.
            prev.scaleX = if (m.rtl) -1f else 1f
            next.scaleX = if (m.rtl) -1f else 1f
            count.text = "${index() + 1}/$n"
            count.setTextColor(colors.subtle)
            val full = r?.full ?: c.overview
            readFull.visibility = if (full.isNullOrBlank()) View.GONE else View.VISIBLE
            readFull.text = caps(m, m.label("readFull", "Read full"))
            readFull.setTextColor(colors.accent)
            readFull.letterSpacing = if (m.rtl) 0f else 0.12f
        }

        /** The whole review (or the overview), in a box that scrolls. */
        private fun showFull() {
            val c = info ?: return
            val m = model ?: return
            val r = currentReview()
            val text = r?.full ?: c.overview ?: return
            val body = TextView(ctx).apply {
                this.text = text
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setLineSpacing(0f, 1.3f)
                setPadding(dp(22), dp(10), dp(22), dp(10))
                setTextIsSelectable(true)
            }
            val scroll = android.widget.ScrollView(ctx).apply { addView(body) }
            val b = android.app.AlertDialog.Builder(ctx)
                .setTitle(r?.author ?: c.title)
                .setView(scroll)
                .setPositiveButton(m.label("close", "Close"), null)
            r?.url?.let { url -> b.setNeutralButton(m.label("source", "Open review source")) { _, _ -> act("link", row = rowKey, text = url) } }
            try {
                b.show()
            } catch (_: Exception) {
            }
        }

        private fun castChip(p: CriticPerson): View = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            isClickable = true
            isFocusable = true
            contentDescription = p.name
            setOnClickListener { act("person", row = rowKey, what = p.id.toString()) }
            val face = FrameLayout(ctx).apply {
                clipToOutline = true
                outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(view: View, outline: Outline) = outline.setOval(0, 0, view.width, view.height)
                }
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                }.also { it.setColor(withAlpha(colors.surface, 0.9f)); it.setStroke(dp(1), withAlpha(colors.ink, 0.12f)) }
            }
            val initial = label(p.name.take(1), 13f, lines = 1).apply {
                gravity = Gravity.CENTER
                setTextColor(colors.subtle)
            }
            face.addView(initial, FrameLayout.LayoutParams(MATCH, MATCH))
            if (p.image != null) {
                val img = NetImage(ctx).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
                face.addView(img, FrameLayout.LayoutParams(MATCH, MATCH))
                images.load(img, listOf(p.image), dp(52), dp(52)) { ok -> initial.visibility = if (ok) View.GONE else View.VISIBLE }
            }
            addView(face, LinearLayout.LayoutParams(dp(52), dp(52)))
            addView(label(p.name, 11f, lines = 1).apply {
                gravity = Gravity.CENTER
                setTextColor(colors.ink)
            }, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
            layoutParams = LinearLayout.LayoutParams(dp(68), ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(6) }
        }
    }

    /** Small capitals (Arabic has no case). */
    private fun caps(m: HomeModel, s: String): String = if (m.rtl) s else s.uppercase()

    /** Pictures full screen, swiped through; a tap (or Back) closes them. */
    private fun showStills(urls: List<String>, start: Int) {
        if (urls.isEmpty()) return
        val d = android.app.Dialog(ctx, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        val rv = RecyclerView(ctx)
        val lm = LinearLayoutManager(ctx, RecyclerView.HORIZONTAL, false)
        rv.layoutManager = lm
        rv.setBackgroundColor(Color.BLACK)
        rv.overScrollMode = View.OVER_SCROLL_NEVER
        rv.adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun getItemCount() = urls.size
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder =
                object : RecyclerView.ViewHolder(NetImage(ctx).apply {
                    layoutParams = RecyclerView.LayoutParams(MATCH, MATCH)
                    scaleType = ImageView.ScaleType.FIT_CENTER
                    setOnClickListener { d.dismiss() }
                }) {}
            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
                images.load(holder.itemView as NetImage, listOf(urls[position]), width(), height())
            }
            override fun onViewRecycled(holder: RecyclerView.ViewHolder) = images.clear(holder.itemView as NetImage)
        }
        PagerSnapHelper().attachToRecyclerView(rv)
        lm.scrollToPosition(start.coerceIn(0, urls.size - 1))
        d.setContentView(rv)
        try {
            d.show()
        } catch (_: Exception) {
        }
    }

    // ---- small pieces ----------------------------------------------------------------------------

    /** IMDb's yellow tag and the score, on a dark pill. */
    private fun imdbBadge(value: String, sizeSp: Float, trailing: Int = dp(14)): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPaddingRelative(dp(5), dp(3), dp(7), dp(3))
        background = rounded(withAlpha(colors.canvas, 0.92f), dp(7).toFloat())
        addView(TextView(ctx).apply {
            text = "IMDb"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp * 0.72f)
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.BLACK)
            includeFontPadding = false
            setPadding(dp(3), dp(1), dp(3), dp(1))
            background = rounded(0xFFF5C518.toInt(), dp(2).toFloat())
        })
        addView(TextView(ctx).apply {
            text = value
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(colors.ink)
            includeFontPadding = false
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(5) })
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = trailing }
    }

    private fun label(text: String, sizeSp: Float, bold: Boolean = false, lines: Int = 0) = TextView(ctx).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        textAlignment = View.TEXT_ALIGNMENT_VIEW_START
        if (lines > 0) {
            maxLines = lines
            ellipsize = TextUtils.TruncateAt.END
        }
    }

    private fun icon(res: Int, tint: Int): Drawable? = ctx.getDrawable(res)?.mutate()?.also { it.setTint(tint) }

    private fun rounded(color: Int, radius: Float, stroke: Int = 0, strokeColor: Int = 0) = GradientDrawable().apply {
        cornerRadius = radius
        setColor(color)
        if (stroke > 0) setStroke(stroke, strokeColor)
    }

    /** A button's background that shows when the D-pad / a controller is on it. */
    private fun focusable(base: Drawable): Drawable {
        val ring = rounded(Color.TRANSPARENT, dp(22).toFloat(), dp(2), colors.accent)
        return android.graphics.drawable.StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), android.graphics.drawable.LayerDrawable(arrayOf(base, ring)))
            addState(intArrayOf(), base)
        }
    }

    private fun ring(): Drawable = rounded(Color.TRANSPARENT, dp(12).toFloat(), dp(3), colors.accent)

    private fun roundOutline(radius: Float) = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            outline.setRoundRect(0, 0, view.width, view.height, radius)
        }
    }

    /** The coloured plate behind a poster that is still loading (or has none). */
    private fun plate(seed: String): Int {
        val hue = ((seed.hashCode() % 360) + 360) % 360
        return Color.HSVToColor(floatArrayOf(hue.toFloat(), 0.45f, 0.28f))
    }

    private fun withAlpha(color: Int, a: Float): Int = (color and 0x00FFFFFF) or ((a.coerceIn(0f, 1f) * 255).toInt() shl 24)

    /** [color] moved [f] of the way to [other]. */
    private fun toward(color: Int, other: Int, f: Float): Int {
        fun ch(shift: Int): Int {
            val x = (color shr shift) and 0xFF
            val y = (other shr shift) and 0xFF
            return ((x + (y - x) * f).toInt().coerceIn(0, 255)) shl shift
        }
        return (0xFF shl 24) or ch(16) or ch(8) or ch(0)
    }

    private fun dp(v: Int): Int = (v * ctx.resources.displayMetrics.density).toInt()

    private fun stableId(key: String): Long = key.hashCode().toLong() and 0xFFFFFFFFL

    companion object {
        private const val TAG = "HarborHome"
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val T_HERO = 1
        private const val T_TOOLS = 2
        private const val T_CW_EMPTY = 3
        private const val T_ROW = 4
        private const val T_END = 5
        private const val T_GAP = 6
        private const val T_HEADER = 7
        private const val T_CHIPS = 8
        private const val T_EMPTY = 9
        // Card kinds: shared by every row's strip (one RecycledViewPool), so they must differ from
        // the outer list's.
        private const val C_POSTER = 101
        private const val C_RANK = 102
        private const val C_CW = 103
        private const val C_TILE = 104
        private const val C_LOGO = 105
        private const val C_FEATURE = 106
        /** The hero turns to its next slide after this long. */
        private const val HERO_TURN_MS = 15_000L
    }
}

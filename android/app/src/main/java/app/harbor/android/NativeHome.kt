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
 *   native -> window.__harborNativeHome(json)    {a:"hero",i,what:"open"|"play"|"list"} {a:"open",row,i}
 *                                                {a:"play",row,i} {a:"all",row} {a:"more",row}
 *                                                {a:"customize"} {a:"together"} {a:"failed"}
 */
class NativeHome(private val ctx: Context, private val images: NativeImages, private val onAction: (JSONObject) -> Unit) {
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

    private fun act(a: String, row: String? = null, i: Int? = null, what: String? = null) {
        val o = JSONObject().put("a", a)
        if (row != null) o.put("row", row)
        if (i != null) o.put("i", i)
        if (what != null) o.put("what", what)
        onAction(o)
    }

    // ---- sizes ---------------------------------------------------------------------------------

    private fun width(): Int = (if (laidOutWidth > 0) laidOutWidth else ctx.resources.displayMetrics.widthPixels)
    private fun height(): Int = (if (laidOutHeight > 0) laidOutHeight else ctx.resources.displayMetrics.heightPixels)
    private val gutter get() = dp(20)
    private val gap get() = dp(12)

    /** About 3.3 posters across a phone (like the web layout), never bigger than 150dp. */
    private fun posterWidth(): Int = min(((width() - gutter) / 3.3f).toInt(), dp(150))
    private fun rankWidth(): Int = (posterWidth() * 1.2f).toInt()
    private fun cwWidth(): Int = min(((width() - gutter) / 1.7f).toInt(), dp(300))
    private fun heroHeight(): Int = max(min((height() * 0.76f).toInt(), dp(640)), dp(320))

    // ---- outer list: hero, Customize, rows -----------------------------------------------------

    private class Section(val type: Int, val id: Long, val row: HomeRow? = null)

    private inner class SectionsAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private var items: List<Section> = emptyList()

        init {
            setHasStableIds(true)
        }

        fun submit(m: HomeModel) {
            val out = ArrayList<Section>()
            if (m.hero.isNotEmpty()) out.add(Section(T_HERO, -1))
            if (m.showCustomize) out.add(Section(T_TOOLS, -2))
            else if (m.hero.isNotEmpty()) out.add(Section(T_GAP, -5))
            if (m.cwEmpty != null) out.add(Section(T_CW_EMPTY, -3))
            for (r in m.rows) out.add(Section(T_ROW, stableId(r.key), r))
            out.add(Section(T_END, -4))
            items = out
            notifyDataSetChanged()
        }

        override fun getItemCount() = items.size
        override fun getItemViewType(position: Int) = items[position].type
        override fun getItemId(position: Int) = items[position].id

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = when (viewType) {
            T_HERO -> HeroHolder()
            T_TOOLS -> ToolsHolder()
            T_CW_EMPTY -> CwEmptyHolder()
            T_ROW -> RowHolder()
            T_GAP -> SpacerHolder(dp(28))
            else -> SpacerHolder(dp(28))
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val m = model ?: return
            when (holder) {
                is HeroHolder -> holder.bind(m)
                is ToolsHolder -> holder.bind(m)
                is CwEmptyHolder -> holder.bind(m)
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
    private inner class ToolsHolder : RecyclerView.ViewHolder(FrameLayout(ctx)) {
        private val box = itemView as FrameLayout
        private val pill = LinearLayout(ctx)
        private val text = label("", 13f)

        init {
            box.layoutParams = RecyclerView.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT)
            box.setPaddingRelative(gutter, dp(10), gutter, dp(14))
            pill.orientation = LinearLayout.HORIZONTAL
            pill.gravity = Gravity.CENTER_VERTICAL
            pill.setPaddingRelative(dp(12), 0, dp(14), 0)
            pill.isClickable = true
            pill.isFocusable = true
            pill.setOnClickListener { act("customize") }
            pill.addView(ImageView(ctx).apply { tag = "ic" }, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginEnd = dp(8) })
            pill.addView(text)
            box.addView(pill, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36), Gravity.END))
        }

        fun bind(m: HomeModel) {
            text.text = m.label("customize", "Customize home")
            text.setTextColor(colors.muted)
            (pill.findViewWithTag<ImageView>("ic"))?.setImageDrawable(icon(R.drawable.ic_pencil, colors.muted))
            pill.background = focusable(rounded(withAlpha(colors.surface, 0.9f), dp(10).toFloat(), dp(1), withAlpha(colors.ink, 0.08f)))
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

        fun bind(m: HomeModel) {
            val (t, text) = m.cwEmpty ?: ("" to "")
            title.text = t
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

    // ---- hero ----------------------------------------------------------------------------------

    private inner class HeroHolder : RecyclerView.ViewHolder(FrameLayout(ctx)) {
        private val frame = itemView as FrameLayout
        private val pager = RecyclerView(ctx)
        private val dots = LinearLayout(ctx)
        private val slides = SlidesAdapter()
        private val pagerLayout = LinearLayoutManager(ctx, RecyclerView.HORIZONTAL, false)
        private val snap = PagerSnapHelper()

        init {
            frame.layoutParams = RecyclerView.LayoutParams(MATCH, heroHeight())
            pager.layoutManager = pagerLayout
            pager.adapter = slides
            pager.overScrollMode = View.OVER_SCROLL_NEVER
            pager.itemAnimator = null
            snap.attachToRecyclerView(pager)
            pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
                override fun onScrollStateChanged(rv: RecyclerView, newState: Int) {
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
        }

        fun bind(m: HomeModel) {
            val lp = frame.layoutParams
            val h = heroHeight()
            if (lp.height != h) {
                lp.height = h
                frame.layoutParams = lp
            }
            slides.submit(m.hero)
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
            seeAll.text = m.label("seeAll", "See all") + " ›"
            seeAll.setTextColor(colors.subtle)
            seeAll.visibility = if (row.seeAll) View.VISIBLE else View.GONE
            header.isClickable = row.seeAll
            header.isFocusable = row.seeAll
            strip.post { maybeAskMore() }
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
        private val rankNumber = label("", 56f, bold = true, lines = 1)
        private val sub = label("", 11f, lines = 1)
        private val track = FrameLayout(ctx)
        private val bar = View(ctx)
        private val play = FrameLayout(ctx)
        private val shade = View(ctx)
        private var row: HomeRow? = null

        init {
            col.orientation = LinearLayout.VERTICAL
            col.layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = gap }
            col.isClickable = true
            col.isFocusable = true
            col.setOnClickListener { tap("open") }
            col.setOnFocusChangeListener { _, has -> box.foreground = if (has) ring() else null }

            box.clipToOutline = true
            box.outlineProvider = roundOutline(dp(12).toFloat())
            image.scaleType = ImageView.ScaleType.CENTER_CROP
            box.addView(image, FrameLayout.LayoutParams(MATCH, MATCH))
            col.addView(box)

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
                C_RANK -> {
                    rankNumber.includeFontPadding = false
                    rankNumber.setShadowLayer(dp(8).toFloat(), 0f, dp(2).toFloat(), 0xCC000000.toInt())
                    box.addView(rankNumber, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START).apply {
                        marginStart = dp(8)
                        bottomMargin = dp(2)
                    })
                }
                else -> {
                    badge.orientation = LinearLayout.HORIZONTAL
                    badge.gravity = Gravity.CENTER_VERTICAL
                    box.addView(badge, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
                        marginEnd = dp(6)
                        bottomMargin = dp(6)
                    })
                }
            }
            col.addView(title, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
        }

        private fun tap(what: String) {
            val r = row ?: return
            val p = bindingAdapterPosition
            if (p == RecyclerView.NO_POSITION) return
            act(if (what == "play") "play" else "open", row = r.key, i = p)
        }

        fun bind(r: HomeRow, c: HomeCard) {
            row = r
            val w = when (kind) {
                C_CW -> cwWidth()
                C_RANK -> rankWidth()
                else -> posterWidth()
            }
            val h = if (kind == C_CW) w * 9 / 16 else w * 3 / 2
            val lp = box.layoutParams as LinearLayout.LayoutParams
            if (lp.width != w || lp.height != h) {
                lp.width = w
                lp.height = h
                box.layoutParams = lp
            }
            val tlp = title.layoutParams
            if (tlp.width != w) {
                tlp.width = w
                title.layoutParams = tlp
            }
            col.contentDescription = c.title
            box.background = rounded(plate(c.title), dp(12).toFloat())
            box.foreground = if (col.isFocused) ring() else null
            images.load(image, c.images, w, h)
            title.text = c.title
            title.setTextColor(colors.ink)
            if (kind != C_CW) title.minLines = 2

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
                    rankNumber.setTextColor(Color.WHITE)
                }
                else -> {
                    badge.removeAllViews()
                    if (c.rating != null) {
                        badge.visibility = View.VISIBLE
                        badge.addView(imdbBadge(c.rating, 10f))
                    } else {
                        badge.visibility = View.GONE
                    }
                }
            }
        }
    }

    // ---- small pieces ----------------------------------------------------------------------------

    /** IMDb's yellow tag and the score, on a dark pill. */
    private fun imdbBadge(value: String, sizeSp: Float): View = LinearLayout(ctx).apply {
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
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(14) }
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
        // Card kinds: shared by every row's strip (one RecycledViewPool), so they must differ from
        // the outer list's.
        private const val C_POSTER = 101
        private const val C_RANK = 102
        private const val C_CW = 103
    }
}

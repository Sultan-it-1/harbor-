package app.harbor.android

import org.json.JSONArray
import org.json.JSONObject

/**
 * What a native screen (Home, Discover, Movies, Shows, Library) shows, as the page describes it
 * (src/views/native/native-screens.ts and the pages build the JSON). Plain JVM (org.json only), so
 * it runs in unit tests (HomeModelTest).
 */
class HomeModel(
    /** Which screen this is ("home", "discover", "movies", "shows", "library"). */
    val page: String = "home",
    val rtl: Boolean,
    /** Changes when the page wants Home back at the top (the Home tab tapped again). */
    val top: Int,
    val colors: HomeColors,
    val labels: Map<String, String>,
    val hero: List<HomeSlide>,
    /** Continue Watching first (kind "cw") when there is anything in it, then the catalog rows. */
    val rows: List<HomeRow>,
    /** Continue Watching when it is empty: its title and the text in its box. */
    val cwEmpty: Pair<String, String>?,
    val showCustomize: Boolean,
    val showTogether: Boolean,
    /** Rating badges at the top of the poster instead of the bottom (Settings > badge placement). */
    val badgesTop: Boolean = false,
    /** A heading at the top (Shows, Library). */
    val header: HomeHeader? = null,
    /** Rows of choices under the heading (Library: tab, type, sort). */
    val chips: List<HomeChips> = emptyList(),
    /** Shown when there are no rows (an empty Library tab): optional title, then the text. */
    val empty: Pair<String?, String>? = null,
    /** The page's row editor is open: each row with an [HomeRow.edit] gets its controls. */
    val edit: Boolean = false,
    /** Home's editor offers "Add source" (custom sources). */
    val addSource: Boolean = false,
) {
    fun label(key: String, fallback: String): String = labels[key]?.takeIf { it.isNotBlank() } ?: fallback

    companion object {
        const val VERSION = 1

        fun parse(json: String): HomeModel {
            val o = JSONObject(json)
            val labels = HashMap<String, String>()
            o.optJSONObject("labels")?.let { l -> for (k in l.keys()) l.str(k)?.let { labels[k] = it } }
            val cw = o.optJSONObject("cwEmpty")
            val head = o.optJSONObject("header")
            val empty = o.optJSONObject("empty")
            return HomeModel(
                page = o.str("page") ?: "home",
                rtl = o.optBoolean("rtl", false),
                top = o.optInt("top", 0),
                colors = HomeColors.parse(o.optJSONObject("colors")),
                labels = labels,
                hero = o.optJSONArray("hero").objects().map { s ->
                    HomeSlide(
                        title = s.str("title") ?: "",
                        description = s.str("desc"),
                        year = s.str("year"),
                        rating = s.str("rating"),
                        runtime = s.str("runtime"),
                        images = s.optJSONArray("img").strings(),
                        logo = s.str("logo"),
                        rank = s.str("rank"),
                        inList = s.optBoolean("inList", false),
                    )
                },
                rows = o.optJSONArray("rows").objects().mapNotNull { r ->
                    val key = r.str("key") ?: return@mapNotNull null
                    val items = r.optJSONArray("items").objects().map { c ->
                        HomeCard(
                            title = c.str("title") ?: "",
                            images = c.optJSONArray("img").strings(),
                            rating = c.str("rating"),
                            sub = c.str("sub"),
                            progress = c.optDouble("progress", 0.0).toFloat().takeIf { !it.isNaN() }?.coerceIn(0f, 1f) ?: 0f,
                            rank = c.optInt("rank", 0),
                            watched = c.optBoolean("watched", false),
                            tint = HomeColors.parseHex(c.str("tint")),
                            kicker = c.str("kicker"),
                            play = c.optBoolean("play", false),
                            emblem = c.optBoolean("emblem", false),
                        )
                    }
                    val ed = r.optJSONObject("ed")?.let { e ->
                        RowEdit(
                            hidden = e.optBoolean("hidden", false),
                            up = e.optBoolean("up", false),
                            down = e.optBoolean("down", false),
                            numerals = tri(e.str("numerals")),
                            hero = tri(e.str("hero")),
                            delete = e.optBoolean("del", false),
                            pinned = e.optBoolean("pinned", false),
                            renamed = e.optBoolean("renamed", false),
                        )
                    }
                    // In the editor a row shows even with nothing in it (hidden, or not loaded).
                    if (items.isEmpty() && ed == null) return@mapNotNull null
                    HomeRow(
                        key = key,
                        title = r.str("title") ?: "",
                        kind = when (r.str("kind")) {
                            "cw" -> HomeRow.Kind.CW
                            "rank" -> HomeRow.Kind.RANK
                            "tile" -> HomeRow.Kind.TILE
                            "logo" -> HomeRow.Kind.LOGO
                            "feature" -> HomeRow.Kind.FEATURE
                            "critic" -> HomeRow.Kind.CRITIC
                            else -> HomeRow.Kind.POSTER
                        },
                        seeAll = r.optBoolean("all", false),
                        more = r.optBoolean("more", false),
                        items = items,
                        edit = ed,
                        note = r.str("note"),
                        critic = r.optJSONObject("critic")?.let { parseCritic(it) },
                    )
                },
                cwEmpty = cw?.let { (it.str("title") ?: "") to (it.str("text") ?: "") },
                showCustomize = o.optBoolean("customize", false),
                showTogether = o.optBoolean("together", false),
                badgesTop = o.optBoolean("badgesTop", false),
                header = head?.let { h ->
                    HomeHeader(kicker = h.str("kicker"), title = h.str("title") ?: "", subtitle = h.str("subtitle"))
                        .takeIf { it.title.isNotEmpty() || it.kicker != null || it.subtitle != null }
                },
                chips = o.optJSONArray("chips").objects().mapNotNull { g ->
                    val key = g.str("key") ?: return@mapNotNull null
                    val items = g.optJSONArray("items").objects().mapNotNull { c ->
                        val id = c.str("id") ?: return@mapNotNull null
                        HomeChip(id = id, label = c.str("label") ?: id, on = c.optBoolean("on", false))
                    }
                    if (items.isEmpty()) null else HomeChips(key, items)
                },
                empty = empty?.str("text")?.let { empty.str("title") to it },
                edit = o.optBoolean("edit", false),
                addSource = o.optBoolean("addSource", false),
            )
        }

        private fun JSONObject.str(k: String): String? = if (isNull(k)) null else optString(k).takeIf { it.isNotEmpty() }

        private fun parseCritic(c: JSONObject): CriticInfo = CriticInfo(
            title = c.str("title") ?: "",
            images = c.optJSONArray("img").strings(),
            logo = c.str("logo"),
            year = c.str("year"),
            rating = c.str("rating"),
            quote = c.str("quote"),
            overview = c.str("overview"),
            reviews = c.optJSONArray("reviews").objects().mapNotNull { r ->
                val text = r.str("text") ?: return@mapNotNull null
                CriticReview(text = text, full = r.str("full") ?: text, author = r.str("author"), score = r.str("score"), url = r.str("url"))
            },
            stills = c.optJSONArray("stills").strings(),
            cast = c.optJSONArray("cast").objects().mapNotNull { p ->
                val id = p.optLong("id", 0L).takeIf { it > 0 } ?: return@mapNotNull null
                CriticPerson(id = id, name = p.str("name") ?: "", image = p.str("img"))
            },
            director = c.optJSONObject("director")?.let { d ->
                d.optLong("id", 0L).takeIf { it > 0 }?.let { CriticPerson(id = it, name = d.str("name") ?: "", image = null) }
            },
            genres = c.optJSONArray("genres").strings(),
            castTitle = c.str("castTitle"),
        )

        /** "on" / "off" / anything else (not offered) as 1 / 0 / -1. */
        private fun tri(v: String?): Int = when (v) {
            "on" -> 1
            "off" -> 0
            else -> -1
        }

        private fun JSONArray?.objects(): List<JSONObject> {
            if (this == null) return emptyList()
            val out = ArrayList<JSONObject>(length())
            for (i in 0 until length()) optJSONObject(i)?.let { out.add(it) }
            return out
        }

        private fun JSONArray?.strings(): List<String> {
            if (this == null) return emptyList()
            val out = ArrayList<String>(length())
            for (i in 0 until length()) {
                if (isNull(i)) continue
                optString(i).takeIf { it.isNotBlank() }?.let { out.add(it) }
            }
            return out
        }
    }
}

class HomeSlide(
    val title: String,
    val description: String?,
    val year: String?,
    val rating: String?,
    val runtime: String?,
    val images: List<String>,
    val logo: String?,
    /** "#1 in Movies Today" */
    val rank: String?,
    val inList: Boolean,
)

class HomeRow(
    val key: String,
    val title: String,
    val kind: Kind,
    val seeAll: Boolean,
    /** The page can load more of this row when you near its end. */
    val more: Boolean,
    val items: List<HomeCard>,
    /** The editor's controls for this row (null = none, or the editor is closed). */
    val edit: RowEdit? = null,
    /** A small line at the end of the row's title (Critics' Pick: "Loved by reviewers today"). */
    val note: String? = null,
    /** CRITIC: everything its card shows. */
    val critic: CriticInfo? = null,
) {
    /** POSTER and RANK: titles; CW: Continue Watching; TILE: a coloured card with its name on it
     *  (genres, languages, awards, collections); LOGO: a streaming service; FEATURE: one wide
     *  card (the discovery queue); CRITIC: Critics' Pick (a title, its reviews, stills and cast). */
    enum class Kind { POSTER, RANK, CW, TILE, LOGO, FEATURE, CRITIC }
}

/** Critics' Pick, as the page's own card shows it. */
class CriticInfo(
    val title: String,
    /** The big picture, best first. */
    val images: List<String>,
    val logo: String?,
    val year: String?,
    val rating: String?,
    /** Shown when there is no review (its tagline or first sentence). */
    val quote: String?,
    /** "Read full" when there is no review. */
    val overview: String?,
    val reviews: List<CriticReview>,
    /** Four stills (they open full screen). */
    val stills: List<String>,
    val cast: List<CriticPerson>,
    val director: CriticPerson?,
    val genres: List<String>,
    /** "Cast · 12", in the app's language. */
    val castTitle: String? = null,
)

class CriticReview(val text: String, val full: String, val author: String?, val score: String?, val url: String?)

class CriticPerson(val id: Long, val name: String, val image: String?)

class HomeCard(
    val title: String,
    /** Picture addresses, best first: the next one is tried when one fails. */
    val images: List<String>,
    val rating: String?,
    /** Continue Watching: "S1E2 · 20m left". */
    val sub: String?,
    /** Continue Watching: how far in, 0..1. */
    val progress: Float,
    /** Top 10: the number shown on the card (0 = none). */
    val rank: Int,
    /** Finished: a small check on the poster (when Settings > watched marks is on). */
    val watched: Boolean = false,
    /** Tiles: the card's colour (behind / under its picture). */
    val tint: Int? = null,
    /** The wide card: a label on its top (Critics' Pick). */
    val kicker: String? = null,
    /** The wide card: a Play button (sends {a:"play"}). */
    val play: Boolean = false,
    /** Tiles: the picture is an emblem shown whole in the top part (awards), not a backdrop. */
    val emblem: Boolean = false,
)

/** A row's controls in the page's editor. [numerals] / [hero]: 1 on, 0 off, -1 not offered. */
class RowEdit(
    val hidden: Boolean,
    val up: Boolean,
    val down: Boolean,
    val numerals: Int,
    val hero: Int,
    val delete: Boolean,
    /** A fixed section (the hero, Top 10…): it can only be hidden or shown. */
    val pinned: Boolean,
    val renamed: Boolean,
)

/** The theme's colours (the page sends what its CSS uses), as ARGB ints. */
class HomeColors(
    val canvas: Int,
    val surface: Int,
    val ink: Int,
    val muted: Int,
    val subtle: Int,
    val accent: Int,
) {
    companion object {
        val DEFAULT = HomeColors(
            canvas = 0xFF141518.toInt(),
            surface = 0xFF1C1D21.toInt(),
            ink = 0xFFF5F5F7.toInt(),
            muted = 0xFFAEAFB3.toInt(),
            subtle = 0xFF6E7075.toInt(),
            accent = 0xFFE8A45E.toInt(),
        )

        fun parse(o: JSONObject?): HomeColors {
            if (o == null) return DEFAULT
            fun c(k: String, d: Int): Int = parseHex(if (o.isNull(k)) null else o.optString(k)) ?: d
            return HomeColors(
                canvas = c("canvas", DEFAULT.canvas),
                surface = c("surface", DEFAULT.surface),
                ink = c("ink", DEFAULT.ink),
                muted = c("muted", DEFAULT.muted),
                subtle = c("subtle", DEFAULT.subtle),
                accent = c("accent", DEFAULT.accent),
            )
        }

        /** "#rrggbb" or "#aarrggbb" (as the page sends them); anything else = null. */
        fun parseHex(s: String?): Int? {
            val h = s?.trim()?.removePrefix("#") ?: return null
            if (h.length != 6 && h.length != 8) return null
            val v = h.toLongOrNull(16) ?: return null
            return if (h.length == 6) (0xFF000000L or v).toInt() else v.toInt()
        }
    }
}

class HomeHeader(val kicker: String?, val title: String, val subtitle: String?)

/** One row of choices; tapping one sends {a:"chip", row:key, what:id}. */
class HomeChips(val key: String, val items: List<HomeChip>)

class HomeChip(val id: String, val label: String, val on: Boolean)

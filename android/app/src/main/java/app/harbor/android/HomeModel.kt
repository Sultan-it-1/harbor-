package app.harbor.android

import org.json.JSONArray
import org.json.JSONObject

/**
 * What the native Home shows, as the page describes it (src/views/home/native-home.ts builds the
 * JSON). Plain JVM (org.json only), so it runs in unit tests (HomeModelTest).
 */
class HomeModel(
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
) {
    fun label(key: String, fallback: String): String = labels[key]?.takeIf { it.isNotBlank() } ?: fallback

    companion object {
        const val VERSION = 1

        fun parse(json: String): HomeModel {
            val o = JSONObject(json)
            val labels = HashMap<String, String>()
            o.optJSONObject("labels")?.let { l -> for (k in l.keys()) l.str(k)?.let { labels[k] = it } }
            val cw = o.optJSONObject("cwEmpty")
            return HomeModel(
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
                        )
                    }
                    if (items.isEmpty()) return@mapNotNull null
                    HomeRow(
                        key = key,
                        title = r.str("title") ?: "",
                        kind = when (r.str("kind")) {
                            "cw" -> HomeRow.Kind.CW
                            "rank" -> HomeRow.Kind.RANK
                            else -> HomeRow.Kind.POSTER
                        },
                        seeAll = r.optBoolean("all", false),
                        more = r.optBoolean("more", false),
                        items = items,
                    )
                },
                cwEmpty = cw?.let { (it.str("title") ?: "") to (it.str("text") ?: "") },
                showCustomize = o.optBoolean("customize", false),
                showTogether = o.optBoolean("together", false),
            )
        }

        private fun JSONObject.str(k: String): String? = if (isNull(k)) null else optString(k).takeIf { it.isNotEmpty() }

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
) {
    enum class Kind { POSTER, RANK, CW }
}

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

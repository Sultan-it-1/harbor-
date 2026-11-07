package app.harbor.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeModelTest {
    @Test
    fun readsWhatThePageSends() {
        val m = HomeModel.parse(
            """
            {"v":1,"rtl":true,"top":3,
             "colors":{"canvas":"#121316","accent":"#e8a45e","ink":"nope"},
             "labels":{"play":"تشغيل","seeAll":"عرض الكل","empty":""},
             "hero":[{"title":"Dune","desc":null,"year":"2021","rating":"8.0","img":["https://a/b.jpg",null,""],"logo":"https://a/l.png","rank":"#1","inList":true}],
             "rows":[
               {"key":"cw","title":"Continue Watching","kind":"cw","items":[{"title":"Show","img":["https://a/c.jpg"],"sub":"S1E2","progress":0.4}]},
               {"key":"top","title":"Top 10","kind":"rank","items":[{"title":"A","rank":1}]},
               {"key":"pop","title":"Popular","kind":"poster","all":true,"more":true,"items":[{"title":"B","img":["https://a/d.jpg"],"rating":"7.1","watched":true},{"title":"D"}]},
               {"key":"empty","title":"Nothing","items":[]},
               {"title":"no key","items":[{"title":"C"}]}
             ],
             "cwEmpty":null,"customize":true,"together":false,"badgesTop":true}
            """.trimIndent(),
        )
        assertTrue(m.rtl)
        assertEquals(3, m.top)
        assertEquals(0xFF121316.toInt(), m.colors.canvas)
        assertEquals(HomeColors.DEFAULT.ink, m.colors.ink) // unreadable colour: the default
        assertEquals("تشغيل", m.label("play", "Play"))
        assertEquals("Customize home", m.label("customize", "Customize home"))
        assertEquals("Fallback", m.label("empty", "Fallback"))

        val s = m.hero.single()
        assertEquals("Dune", s.title)
        assertNull(s.description)
        assertEquals(listOf("https://a/b.jpg"), s.images)
        assertTrue(s.inList)

        // Rows without cards or without a key are left out.
        assertEquals(listOf("cw", "top", "pop"), m.rows.map { it.key })
        assertEquals(HomeRow.Kind.CW, m.rows[0].kind)
        assertEquals(0.4f, m.rows[0].items[0].progress, 0.0001f)
        assertEquals(HomeRow.Kind.RANK, m.rows[1].kind)
        assertEquals(1, m.rows[1].items[0].rank)
        val pop = m.rows[2]
        assertEquals(HomeRow.Kind.POSTER, pop.kind)
        assertTrue(pop.seeAll && pop.more)
        assertEquals("7.1", pop.items[0].rating)
        assertTrue(pop.items[0].watched)
        assertFalse(pop.items[1].watched)
        assertTrue(m.badgesTop)
        assertNull(m.cwEmpty)
        assertTrue(m.showCustomize)
        assertFalse(m.showTogether)
    }

    @Test
    fun progressStaysBetweenZeroAndOne() {
        val m = HomeModel.parse("""{"rows":[{"key":"cw","kind":"cw","items":[{"title":"a","progress":3},{"title":"b","progress":-1},{"title":"c"}]}]}""")
        assertEquals(listOf(1f, 0f, 0f), m.rows[0].items.map { it.progress })
    }

    @Test
    fun emptyContinueWatchingBox() {
        val m = HomeModel.parse("""{"cwEmpty":{"title":"Continue Watching","text":"Nothing yet"}}""")
        assertEquals("Continue Watching" to "Nothing yet", m.cwEmpty)
        assertTrue(m.hero.isEmpty())
        assertTrue(m.rows.isEmpty())
    }

    @Test
    fun libraryScreen() {
        val m = HomeModel.parse(
            """
            {"page":"library","header":{"kicker":"My library","title":"Your collection.","subtitle":null},
             "chips":[{"key":"tab","items":[{"id":"watchlist","label":"Watchlist","on":true},{"id":"history","label":"History"},{"label":"no id"}]},
                      {"key":"empty","items":[]},{"items":[{"id":"x"}]}],
             "rows":[],"empty":{"title":null,"text":"Your watchlist is empty"}}
            """.trimIndent(),
        )
        assertEquals("library", m.page)
        assertEquals("Your collection.", m.header?.title)
        assertNull(m.header?.subtitle)
        // Rows of choices without a key or without choices are left out; so are choices without an id.
        assertEquals(listOf("tab"), m.chips.map { it.key })
        assertEquals(listOf("watchlist", "history"), m.chips[0].items.map { it.id })
        assertTrue(m.chips[0].items[0].on)
        assertFalse(m.chips[0].items[1].on)
        assertEquals(null to "Your watchlist is empty", m.empty)
    }

    @Test
    fun criticsPick() {
        val m = HomeModel.parse(
            """{"page":"discover","rows":[{"key":"x:critics","title":"Critics' Pick","kind":"critic","note":"Loved by reviewers today",
              "items":[{"title":"Yojimbo"}],
              "critic":{"title":"Yojimbo","img":["https://a/b.jpg"],"logo":null,"year":"1961","rating":"8.1","quote":"A standout.",
                "overview":"A ronin…","reviews":[{"text":"Short","full":"Short and long","author":"CRCulver","score":"9/10","url":"https://r"},{"author":"no text"}],
                "stills":["https://s/1.jpg","https://s/2.jpg"],"cast":[{"id":7,"name":"Toshirō","img":"https://p/1.jpg"},{"id":0,"name":"No id"}],
                "director":{"id":9,"name":"Akira Kurosawa"},"genres":["Drama","Thriller"]}}]}""",
        )
        val row = m.rows.single()
        assertEquals(HomeRow.Kind.CRITIC, row.kind)
        assertEquals("Loved by reviewers today", row.note)
        val c = row.critic!!
        assertEquals("1961", c.year)
        assertNull(c.logo)
        // A review without its text, a person without an id: left out.
        assertEquals(listOf("CRCulver"), c.reviews.map { it.author })
        assertEquals("Short and long", c.reviews[0].full)
        assertEquals(listOf(7L), c.cast.map { it.id })
        assertEquals("Akira Kurosawa", c.director?.name)
        assertEquals(listOf("Drama", "Thriller"), c.genres)
        assertEquals(2, c.stills.size)
    }

    @Test
    fun defaultsToHome() {
        val m = HomeModel.parse("{}")
        assertEquals("home", m.page)
        assertNull(m.header)
        assertTrue(m.chips.isEmpty())
        assertNull(m.empty)
    }

    @Test
    fun hexColours() {
        assertEquals(0xFFE8A45E.toInt(), HomeColors.parseHex("#e8a45e"))
        assertEquals(0x80FFFFFF.toInt(), HomeColors.parseHex("#80ffffff"))
        assertNull(HomeColors.parseHex("oklch(0.5 0.1 20)"))
        assertNull(HomeColors.parseHex("#abc"))
        assertNull(HomeColors.parseHex(null))
    }
}

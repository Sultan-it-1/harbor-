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
               {"key":"pop","title":"Popular","kind":"poster","all":true,"more":true,"items":[{"title":"B","img":["https://a/d.jpg"],"rating":"7.1"}]},
               {"key":"empty","title":"Nothing","items":[]},
               {"title":"no key","items":[{"title":"C"}]}
             ],
             "cwEmpty":null,"customize":true,"together":false}
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
    fun hexColours() {
        assertEquals(0xFFE8A45E.toInt(), HomeColors.parseHex("#e8a45e"))
        assertEquals(0x80FFFFFF.toInt(), HomeColors.parseHex("#80ffffff"))
        assertNull(HomeColors.parseHex("oklch(0.5 0.1 20)"))
        assertNull(HomeColors.parseHex("#abc"))
        assertNull(HomeColors.parseHex(null))
    }
}

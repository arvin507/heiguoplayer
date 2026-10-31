package personal.heiguo

import org.junit.Assert.assertEquals
import org.junit.Test
import personal.heiguo.domain.PlaybackInfo
import personal.heiguo.domain.Quality
import personal.heiguo.domain.StreamInfo

class QualityTest {
    private fun s(h: Int, br: Long = 1000, def: String = "") = StreamInfo(url = "https://x/$h/$br", height = h, bitrate = br, definition = def)
    private val info = PlaybackInfo("e", false, listOf(s(1080, 3000), s(720, 2000), s(720, 1500), s(480, 800)))

    @Test fun optionsAreDedupedByHeightAndSortedDescending() =
        assertEquals(listOf(1080, 720, 480), Quality.options(info.streams).map { it.height })

    @Test fun noPreferenceUsesDefaultRule() =
        assertEquals(1080, Quality.pick(info, 0)!!.height)

    @Test fun exactHeightWins() =
        assertEquals(720, Quality.pick(info, 720)!!.height)

    @Test fun missingHeightFallsBackToHighestNotAbove() =
        assertEquals(720, Quality.pick(info, 900)!!.height)

    @Test fun preferenceBelowAllPicksLowest() =
        assertEquals(480, Quality.pick(info, 360)!!.height)

    @Test fun labelPrefersDefinitionThenHeight() {
        assertEquals("超清", Quality.label(s(1080, def = "超清")))
        assertEquals("720p", Quality.label(s(720)))
    }

    @Test fun emptyStreamsPickNothing() =
        assertEquals(null, Quality.pick(PlaybackInfo("e", false, emptyList()), 720))
}

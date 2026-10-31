package personal.heiguo

import org.junit.Assert.assertEquals
import org.junit.Test
import personal.heiguo.service.LiveHongguoService.Companion.suggestionKeyword

class SuggestionKeywordTest {
    @Test fun directRowWithContentIdFallsBackToText() =
        assertEquals("全球死考", suggestionKeyword("全球死考", "7512345678901234567"))

    @Test fun normalKeywordIsKept() =
        assertEquals("全球死考", suggestionKeyword("全球死考 第二季", "全球死考"))

    @Test fun emptyKeywordUsesText() =
        assertEquals("全球死考", suggestionKeyword("全球死考", ""))

    @Test fun shortNumericKeywordIsKept() =
        assertEquals("2024", suggestionKeyword("2024", "2024"))
}

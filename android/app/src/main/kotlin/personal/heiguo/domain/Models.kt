package personal.heiguo.domain

// 业务层自己的领域模型。SDK 的类型只出现在 service/LiveHongguoService.kt 里。

data class PageResult<T>(val items: List<T>, val cursor: String?, val hasMore: Boolean) {
    companion object {
        fun <T> empty() = PageResult<T>(emptyList(), null, false)
    }
}

enum class SeriesStatusKind { ONGOING, FINISHED, UNKNOWN }

/** 列表里的一部剧（搜索、筛选、榜单、上新都映射成它）。 */
data class SeriesItem(
    val id: String,
    val title: String,
    val summary: String = "",
    val coverUrl: String? = null,
    val episodeCount: Int = 0,
    /** 卡片右下角的辅助文字，例如热度或名次。 */
    val badge: String? = null,
)

data class SeriesInfo(
    val id: String,
    val title: String,
    val summary: String = "",
    val coverUrl: String? = null,
    val episodeCount: Int = 0,
    val status: SeriesStatusKind = SeriesStatusKind.UNKNOWN,
    val statusText: String = "",
    val tags: List<String> = emptyList(),
)

data class EpisodeItem(
    val id: String,
    val seriesId: String,
    val number: Int,
    val title: String = "",
    /** 服务端禁止播放时为 false。 */
    val playable: Boolean = true,
    val coverUrl: String? = null,
)

data class StreamInfo(
    val url: String,
    val backupUrl: String? = null,
    val definition: String = "",
    val height: Int = 0,
    val bitrate: Long = 0,
    val hls: Boolean = false,
    val dash: Boolean = false,
    val isProtected: Boolean = false,
    val encryption: String = "",
)

data class PlaybackInfo(
    val episodeId: String,
    val isProtected: Boolean,
    /** 按清晰度从高到低，已去掉 DASH。 */
    val streams: List<StreamInfo>,
    val durationSeconds: Int = 0,
    /** 流地址失效时间（毫秒时间戳）；null 表示服务端没给。 */
    val expiresAtMs: Long? = null,
) {
    /** 首选流：1080p 以下里最高的一档。 */
    val preferredStream: StreamInfo?
        get() = streams.firstOrNull { it.height in 1..1080 } ?: streams.firstOrNull()
}

data class SearchSuggestion(val text: String, val keyword: String)

data class HotBoardInfo(val name: String, val items: List<SeriesItem>, val topics: List<SearchSuggestion>)

data class HotSearchInfo(val guesses: List<SeriesItem> = emptyList(), val boards: List<HotBoardInfo> = emptyList())

data class FilterChoice(val name: String, val value: String)

data class FilterRowInfo(val key: String, val name: String, val choices: List<FilterChoice>)

data class RankBoardInfo(val id: String, val name: String)

data class RankContentInfo(val id: String, val name: String, val boards: List<RankBoardInfo>)

data class RankPageInfo(
    val contents: List<RankContentInfo>,
    val content: String,
    val board: String,
    val page: PageResult<SeriesItem>,
)

data class NewReleaseItem(val series: SeriesItem, val online: Boolean, val note: String, val categories: List<String>)

data class NewReleaseDayInfo(
    /** YYYYMMDD */
    val date: String,
    val dates: List<String>,
    val page: PageResult<NewReleaseItem>,
)

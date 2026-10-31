package personal.heiguo.service

import personal.heiguo.domain.*

/**
 * 业务层唯一依赖的接口。正式实现是 LiveHongguoService（包装 openhongguo SDK）。
 * 所有方法失败时抛出 AppError（或 CancellationException）。
 *
 * 这一层只做“一次调用 → 一次请求”的翻译，不做重试、缓存和去重，那些策略都在 repo 包里。
 */
interface HongguoService {
    suspend fun discover(cursor: String?): PageResult<SeriesItem>
    suspend fun search(query: String, cursor: String?): PageResult<SeriesItem>
    suspend fun suggest(prefix: String): List<SearchSuggestion>
    suspend fun hotSearch(): HotSearchInfo
    suspend fun searchCues(): List<String>

    suspend fun series(seriesId: String): SeriesInfo
    /** 批量读取详情（追更检查用）；读不到的剧不在结果里。 */
    suspend fun seriesBatch(seriesIds: List<String>): List<SeriesInfo>
    suspend fun episodes(seriesId: String, cursor: String?): PageResult<EpisodeItem>

    suspend fun filterPanel(): List<FilterRowInfo>
    suspend fun filter(selections: Map<String, List<String>>, cursor: String?): PageResult<SeriesItem>
    suspend fun rank(content: String?, board: String?, cursor: String?): RankPageInfo
    suspend fun newReleases(date: String?, cursor: String?): NewReleaseDayInfo

    /** 请求一集的播放模型。每台匿名设备基本只成功一次，调用方必须节约使用。 */
    suspend fun resolvePlayback(episodeId: String): PlaybackInfo
    /** 丢弃当前匿名设备，注册新设备。 */
    suspend fun resetDevice()
}

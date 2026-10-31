package personal.heiguo.service

import dev.openhongguo.*
import personal.heiguo.domain.*
import personal.heiguo.support.AppLog
import java.io.File
import kotlin.coroutines.cancellation.CancellationException

/**
 * HongguoService 的正式实现：包装 openhongguo SDK，把 SDK 类型映射成领域模型、
 * 把 OpenhongguoException 映射成 AppError。整个 App 里唯一 import dev.openhongguo 的文件。
 *
 * @param profileFile 设备档案位置。应放在 noBackupFilesDir 下，不参与云备份 / 设备迁移。
 */
class LiveHongguoService(profileFile: File) : HongguoService {
    private val client: OpenhongguoClient

    init {
        profileFile.parentFile?.mkdirs()
        // retryAttempts = 1：关掉 SDK 内置的自动重试，限流退避与设备重置统一由 Repository 控制，
        // 避免两层重试叠加导致请求次数翻倍。
        val options = ClientOptions(retryAttempts = 1, logger = { AppLog.net(it) })
        client = try {
            OpenhongguoClient.create(profileFile, options)
        } catch (t: Throwable) {
            throw map(t)
        }
    }

    override suspend fun discover(cursor: String?) =
        run { client.discover(DiscoverOptions(cursor = cursor)) }.mapPage(::item)

    override suspend fun search(query: String, cursor: String?) =
        run { client.search(query, SearchOptions(cursor = cursor)) }.mapPage(::item)

    override suspend fun suggest(prefix: String): List<SearchSuggestion> =
        run { client.suggest(prefix) }.filter { it.text.isNotEmpty() }
            .map { SearchSuggestion(it.text, suggestionKeyword(it.text, it.keyword)) }

    companion object {
        /**
         * 联想词点选后提交的搜索词。SDK 的直达行 keyword 是内容 ID（长数字串），
         * 拿它去搜索什么也搜不到，所以这种情况改用显示文字。
         */
        fun suggestionKeyword(text: String, keyword: String): String =
            if (keyword.isEmpty() || (keyword.length >= 10 && keyword.all { it.isDigit() })) text else keyword
    }

    override suspend fun hotSearch(): HotSearchInfo {
        val h = run { client.hotSearch() }
        return HotSearchInfo(
            guesses = h.guesses.mapNotNull(::item),
            boards = h.boards.map { b ->
                HotBoardInfo(
                    b.name, b.items.mapNotNull(::item),
                    b.topics.filter { it.title.isNotEmpty() }
                        .map { SearchSuggestion(it.title, it.query.ifEmpty { it.title }) },
                )
            },
        )
    }

    override suspend fun searchCues(): List<String> = run { client.searchCues() }.filter { it.isNotEmpty() }

    override suspend fun series(seriesId: String): SeriesInfo = info(run { client.getSeries(seriesId) })

    override suspend fun seriesBatch(seriesIds: List<String>): List<SeriesInfo> {
        if (seriesIds.isEmpty()) return emptyList()
        return run { client.getSeriesBatch(seriesIds) }.mapNotNull { it.series }.filter { it.id.isNotEmpty() }.map(::info)
    }

    override suspend fun episodes(seriesId: String, cursor: String?): PageResult<EpisodeItem> =
        run { client.listEpisodes(seriesId, EpisodeOptions(cursor = cursor)) }.mapPage { e ->
            if (e.id.isEmpty()) null
            else EpisodeItem(e.id, e.seriesId.ifEmpty { seriesId }, e.number, e.title, e.playable, e.coverUrl.ifEmpty { null })
        }

    override suspend fun filterPanel(): List<FilterRowInfo> =
        run { client.shortFilterPanel() }.filter { it.key.isNotEmpty() && it.options.isNotEmpty() }
            .map { r -> FilterRowInfo(r.key, r.name, r.options.map { FilterChoice(it.name, it.value) }) }

    override suspend fun filter(selections: Map<String, List<String>>, cursor: String?): PageResult<SeriesItem> {
        val p = run { client.shortFilter(ShortFilterQuery(selections = selections.ifEmpty { null }, cursor = cursor)) }
        return PageResult(p.items.mapNotNull(::item), p.cursor.ifEmpty { null }, p.hasMore)
    }

    override suspend fun rank(content: String?, board: String?, cursor: String?): RankPageInfo {
        val r = run { client.shortRank(ShortRankQuery(content = content, board = board, cursor = cursor)) }
        val items = r.items.mapNotNull { row ->
            if (row.seriesId.isEmpty()) return@mapNotNull null // 演员行没有 seriesId
            val place = if (row.position > 0) row.position else row.rank
            val badge = listOfNotNull(if (place > 0) "No.$place" else null, row.score.ifEmpty { null }).joinToString(" · ")
            SeriesItem(row.seriesId, row.title, coverUrl = row.coverUrl.ifEmpty { null },
                episodeCount = row.episodeCount, badge = badge.ifEmpty { null })
        }
        return RankPageInfo(
            contents = r.contents.map { c -> RankContentInfo(c.id, c.name, c.boards.map { RankBoardInfo(it.id, it.name) }) },
            content = r.content, board = r.board,
            page = PageResult(items, r.cursor.ifEmpty { null }, r.hasMore),
        )
    }

    override suspend fun newReleases(date: String?, cursor: String?): NewReleaseDayInfo {
        val p = run { client.newReleases(NewReleaseQuery(date = date, cursor = cursor)) }
        val items = p.items.mapNotNull { n ->
            if (n.seriesId.isEmpty()) return@mapNotNull null
            NewReleaseItem(
                SeriesItem(n.seriesId, n.title, n.description, n.coverUrl.ifEmpty { null }, n.episodeCount, n.heat.ifEmpty { null }),
                n.online, n.note, n.categories,
            )
        }
        return NewReleaseDayInfo(p.date, p.dates, PageResult(items, p.cursor.ifEmpty { null }, p.hasMore))
    }

    override suspend fun resolvePlayback(episodeId: String): PlaybackInfo {
        val r = run { client.resolvePlayback(episodeId) }
        val pb = r.playback
        // 只丢掉 DASH 分片（ExoPlayer 这里按单文件 / HLS 播放）。加密标记保留，由上层决定怎么处理。
        val streams = pb.streams.filter { !it.dash }.mapNotNull { s ->
            if (!s.url.startsWith("http")) null
            else StreamInfo(s.url, s.backupUrl.ifEmpty { null }, s.definition, s.height, s.bitrate,
                s.hls, s.dash, s.protected, s.encryption)
        }.sortedWith(compareByDescending<StreamInfo> { it.height }.thenByDescending { it.bitrate })
        return PlaybackInfo(
            episodeId = pb.episodeId.ifEmpty { episodeId },
            isProtected = pb.protected,
            streams = streams,
            durationSeconds = pb.durationSeconds,
            expiresAtMs = if (pb.expiresAt > 0) pb.expiresAt * 1000 else null,
            // 加密分集的内容密钥。SDK 单独请求这一项，失败时只体现在 contentKeyError 上，
            // 流地址仍然可用，所以这里不抛错：没有密钥就走“无法播放加密分集”的占位。
            contentKey = r.contentKey?.let { personal.heiguo.domain.ContentKey(it.key, it.version) },
        )
    }

    override suspend fun resetDevice() = run { client.resetDevice() }

    private suspend inline fun <T> run(crossinline body: suspend () -> T): T =
        try {
            body()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            throw map(t)
        }

    private fun map(t: Throwable): Throwable {
        if (t is CancellationException) return t
        if (t is OpenhongguoException) {
            if (t.code == ErrorCode.CANCELLED) return CancellationException("cancelled")
            val code = AppError.Code.entries.firstOrNull { it.raw == t.code.name } ?: AppError.Code.UNKNOWN
            val after = if (t.retryAfterMs > 0) t.retryAfterMs / 1000.0 else null
            return AppError(code, t.message ?: "", after)
        }
        return AppError.from(t) ?: CancellationException("cancelled")
    }

    private fun <T, U : Any> Page<T>.mapPage(f: (T) -> U?) =
        PageResult(items.mapNotNull(f), cursor.ifEmpty { null }, hasMore)

    private fun item(s: SeriesSummary): SeriesItem? =
        if (s.id.isEmpty()) null
        else SeriesItem(s.id, s.title, s.description, s.coverUrl.ifEmpty { null }, s.episodeCount)

    private fun item(h: HotItem): SeriesItem? =
        if (h.seriesId.isEmpty()) null
        else SeriesItem(h.seriesId, h.title, coverUrl = h.coverUrl.ifEmpty { null }, episodeCount = h.episodeCount,
            badge = h.searchScore.ifEmpty { null } ?: h.heat.ifEmpty { null })

    private fun info(s: Series): SeriesInfo {
        val status = when (s.status) {
            SeriesStatus.END -> SeriesStatusKind.FINISHED
            SeriesStatus.UPDATING, SeriesStatus.UPDATED_TODAY, SeriesStatus.UPDATE_STOPPED -> SeriesStatusKind.ONGOING
            else -> SeriesStatusKind.UNKNOWN
        }
        val tagKinds = setOf(InfoKind.CATEGORY, InfoKind.TAGS, InfoKind.PLOT_TAG)
        val tags = s.rows.filter { it.kind in tagKinds }
            .flatMap { it.text.split(' ', '·', ',', '，', '/') }
            .filter { it.isNotEmpty() }.distinct().take(6)
        val statusText = s.rightText.ifEmpty { null }
            ?: when {
                status == SeriesStatusKind.FINISHED -> "全${s.episodeCount}集"
                s.episodeCount > 0 -> "更新至${s.episodeCount}集"
                else -> ""
            }
        return SeriesInfo(s.id, s.title, s.description, s.coverUrl.ifEmpty { null }, s.episodeCount, status, statusText, tags)
    }
}

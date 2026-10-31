package personal.heiguo.repo

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import personal.heiguo.domain.*
import personal.heiguo.service.HongguoService
import personal.heiguo.support.TaskCoalescer

/**
 * 元数据仓库：详情、分集、列表、榜单等。带内存缓存（TTL）和并发去重。
 *
 * ANONYMOUS_LIMITED 在这里一律当作“结果为空”处理（SDK 文档：列表为空时也报这个错误），
 * 只有 PlaybackRepository 才把它当作“被限制”。
 */
class CatalogRepository(
    private val service: HongguoService,
    private val detailTtlMs: Long = 600_000,
    private val listTtlMs: Long = 300_000,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private class Cached<T>(val value: T, val at: Long)

    private val lock = Any()
    private val seriesCache = HashMap<String, Cached<SeriesInfo>>()
    private val episodesCache = HashMap<String, Cached<List<EpisodeItem>>>()
    private var hotCache: Cached<HotSearchInfo>? = null
    private var panelCache: Cached<List<FilterRowInfo>>? = null

    private val seriesCoalescer = TaskCoalescer<String, SeriesInfo>(scope)
    private val episodesCoalescer = TaskCoalescer<String, List<EpisodeItem>>(scope)
    private val hotCoalescer = TaskCoalescer<String, HotSearchInfo>(scope)
    private val panelCoalescer = TaskCoalescer<String, List<FilterRowInfo>>(scope)

    private fun fresh(at: Long, ttl: Long) = now() - at < ttl

    suspend fun series(id: String, forceRefresh: Boolean = false): SeriesInfo {
        if (!forceRefresh) synchronized(lock) { seriesCache[id] }?.let { if (fresh(it.at, detailTtlMs)) return it.value }
        val v = seriesCoalescer.value(id) { service.series(id) }
        synchronized(lock) { seriesCache[id] = Cached(v, now()) }
        return v
    }

    /** 全部分集（自动翻页，按分集 ID 去重，按集号排序）。 */
    suspend fun episodes(seriesId: String, forceRefresh: Boolean = false): List<EpisodeItem> {
        if (!forceRefresh) synchronized(lock) { episodesCache[seriesId] }?.let { if (fresh(it.at, detailTtlMs)) return it.value }
        val v = episodesCoalescer.value(seriesId) {
            val seen = HashSet<String>()
            val all = ArrayList<EpisodeItem>()
            var cursor: String? = null
            var pages = 0
            while (pages < MAX_EPISODE_PAGES) {
                pages++
                val page = emptyOnLimited { service.episodes(seriesId, cursor) }
                for (e in page.items) if (seen.add(e.id)) all.add(e)
                val next = page.cursor
                if (!page.hasMore || next == null || next == cursor) break
                cursor = next
            }
            all.sortedBy { it.number }
        }
        synchronized(lock) { episodesCache[seriesId] = Cached(v, now()) }
        return v
    }

    /** 只预取元数据（详情 + 分集），绝不请求播放模型。失败静默。 */
    fun prefetchMetadata(seriesId: String) {
        scope.launch {
            runCatching { series(seriesId) }
            runCatching { episodes(seriesId) }
        }
    }

    /** 批量读取详情，用于追更检查。每批 20 部；失败的批次跳过。 */
    suspend fun seriesBatch(ids: List<String>): List<SeriesInfo> {
        val out = ArrayList<SeriesInfo>()
        for (chunk in ids.chunked(20)) {
            val r = try { service.seriesBatch(chunk) } catch (e: kotlin.coroutines.cancellation.CancellationException) { throw e } catch (_: Throwable) { continue }
            synchronized(lock) { r.forEach { seriesCache[it.id] = Cached(it, now()) } }
            out += r
        }
        return out
    }

    suspend fun discover(cursor: String?) = emptyOnLimited { service.discover(cursor) }
    suspend fun search(query: String, cursor: String?) = emptyOnLimited { service.search(query, cursor) }
    suspend fun suggest(prefix: String) = emptyListOnLimited { service.suggest(prefix) }
    suspend fun searchCues() = emptyListOnLimited { service.searchCues() }

    suspend fun hotSearch(): HotSearchInfo {
        hotCache?.let { if (fresh(it.at, listTtlMs)) return it.value }
        val v = hotCoalescer.value("hot") {
            try { service.hotSearch() } catch (e: AppError) { if (e.code == AppError.Code.ANONYMOUS_LIMITED) HotSearchInfo() else throw e }
        }
        hotCache = Cached(v, now())
        return v
    }

    suspend fun filterPanel(): List<FilterRowInfo> {
        panelCache?.let { if (fresh(it.at, detailTtlMs)) return it.value }
        val v = panelCoalescer.value("panel") { emptyListOnLimited { service.filterPanel() } }
        panelCache = Cached(v, now())
        return v
    }

    suspend fun filter(selections: Map<String, List<String>>, cursor: String?) =
        emptyOnLimited { service.filter(selections, cursor) }

    suspend fun rank(content: String?, board: String?, cursor: String?): RankPageInfo =
        try {
            service.rank(content, board, cursor)
        } catch (e: AppError) {
            if (e.code != AppError.Code.ANONYMOUS_LIMITED) throw e
            RankPageInfo(emptyList(), content ?: "", board ?: "", PageResult.empty())
        }

    suspend fun newReleases(date: String?, cursor: String?): NewReleaseDayInfo =
        try {
            service.newReleases(date, cursor)
        } catch (e: AppError) {
            if (e.code != AppError.Code.ANONYMOUS_LIMITED) throw e
            NewReleaseDayInfo(date ?: "", emptyList(), PageResult.empty())
        }

    companion object {
        /** 分集列表最多翻多少页，防止服务端异常时死循环。 */
        const val MAX_EPISODE_PAGES = 30
    }
}

/** 列表接口：ANONYMOUS_LIMITED / END_OF_LIST 视为空页。 */
suspend fun <T> emptyOnLimited(body: suspend () -> PageResult<T>): PageResult<T> =
    try {
        body()
    } catch (e: AppError) {
        if (e.code == AppError.Code.ANONYMOUS_LIMITED || e.code == AppError.Code.END_OF_LIST) PageResult.empty() else throw e
    }

suspend fun <T> emptyListOnLimited(body: suspend () -> List<T>): List<T> =
    try {
        body()
    } catch (e: AppError) {
        if (e.code == AppError.Code.ANONYMOUS_LIMITED || e.code == AppError.Code.END_OF_LIST) emptyList() else throw e
    }

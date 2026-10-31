package personal.heiguo.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import personal.heiguo.AppEnv
import personal.heiguo.domain.*

data class FeedUiState(
    val focusedId: String? = null,
    /** 当前正在播放的那一部（停留够久之后才创建）。 */
    val player: PlayerController? = null,
    val preparingId: String? = null,
    val prepareError: AppError? = null,
)

/**
 * 推荐流：竖屏一屏一部剧，上下滑动切换。
 * - 停留 dwell 毫秒后才为当前这部剧请求播放模型（快速划过的不请求，节约设备额度）；
 * - 只预取前后几部剧的元数据（分集列表），绝不预取播放模型；
 * - 记住上次停在哪部剧，下次打开回到那里，并从那部剧的观看记录续播。
 */
class FeedViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(FeedUiState())
    val ui: StateFlow<FeedUiState> = _ui
    val feed = Paginator<SeriesItem>(viewModelScope, { it.id }) { cursor ->
        val page = env.catalog.discover(cursor)
        // 首页：把上次停留的剧放到最前面，回到上次的位置
        val last = if (cursor == null) env.library.feedSeriesId() else null
        if (last != null && page.items.none { it.id == last }) {
            val info = runCatching { env.catalog.series(last) }.getOrNull()
            if (info != null) {
                val head = SeriesItem(info.id, info.title, info.summary, info.coverUrl, info.episodeCount)
                return@Paginator page.copy(items = listOf(head) + page.items)
            }
        }
        page
    }

    var dwellMs = 600L
    private var dwellJob: Job? = null
    private var restoredId: String? = null

    fun load() {
        viewModelScope.launch {
            restoredId = env.library.feedSeriesId()
            feed.loadIfNeeded()
        }
    }

    /** 首屏应当停在哪一部。 */
    fun initialIndex(): Int {
        val items = feed.state.value.items
        val r = restoredId ?: return 0
        return items.indexOfFirst { it.id == r }.coerceAtLeast(0)
    }

    /** 滚动停到第 index 部时调用。 */
    fun focus(index: Int) {
        val items = feed.state.value.items
        val item = items.getOrNull(index)
        if (item?.id == _ui.value.focusedId && _ui.value.player != null) return
        dwellJob?.cancel()
        _ui.value.player?.stop()
        _ui.update { it.copy(focusedId = item?.id, player = null, prepareError = null, preparingId = null) }
        if (item == null) return
        viewModelScope.launch { env.library.setFeedPosition(item.id) }
        feed.onItemVisible(index)

        // 元数据预取：当前和后两部
        items.subList(index, minOf(index + 3, items.size)).forEach { env.catalog.prefetchMetadata(it.id) }

        dwellJob = viewModelScope.launch {
            delay(dwellMs)
            if (_ui.value.focusedId == item.id) preparePlayer(item)
        }
    }

    private suspend fun preparePlayer(item: SeriesItem) {
        _ui.update { it.copy(preparingId = item.id) }
        try {
            val eps = env.catalog.episodes(item.id)
            if (_ui.value.focusedId != item.id) return
            if (eps.isEmpty()) {
                _ui.update { it.copy(prepareError = AppError(AppError.Code.CONTENT_UNAVAILABLE, "no episodes")) }
                return
            }
            var startIndex = 0
            var startAt = 0.0
            val last = env.library.lastWatched(item.id)
            val i = last?.let { l -> eps.indexOfFirst { it.number == l.episodeNumber } } ?: -1
            if (last != null && i >= 0) {
                if (last.isFinished && i + 1 < eps.size) startIndex = i + 1
                else { startIndex = i; startAt = if (last.isFinished) 0.0 else maxOf(0.0, last.progressSeconds - 2) }
            }
            val p = PlayerController(item.id, item.title, item.coverUrl, eps, startIndex, startAt, env, viewModelScope)
            _ui.update { it.copy(player = p) }
            p.start()
        } catch (t: Throwable) {
            if (_ui.value.focusedId != item.id) return
            AppError.from(t)?.let { e -> _ui.update { it.copy(prepareError = e) } }
        } finally {
            _ui.update { if (it.preparingId == item.id) it.copy(preparingId = null) else it }
        }
    }

    fun retry() {
        val idx = feed.state.value.items.indexOfFirst { it.id == _ui.value.focusedId }
        _ui.update { it.copy(focusedId = null, player = null) }
        if (idx >= 0) focus(idx)
    }

    /** 离开推荐页（切 Tab、进入详情）：停止播放、取消未完成的请求。 */
    fun pause() {
        dwellJob?.cancel()
        _ui.value.player?.stop()
    }

    fun resume() = retry()
}

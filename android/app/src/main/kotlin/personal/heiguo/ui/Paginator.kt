package personal.heiguo.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import personal.heiguo.domain.AppError
import personal.heiguo.domain.PageResult

/** 每个页面都有的四种状态：加载中、有内容、空、出错。 */
sealed interface LoadState {
    data object Idle : LoadState
    data object Loading : LoadState
    data object Loaded : LoadState
    data object Empty : LoadState
    data class Failed(val error: AppError) : LoadState
}

data class PagerState<T>(
    val items: List<T> = emptyList(),
    val load: LoadState = LoadState.Idle,
    val hasMore: Boolean = false,
    val loadingMore: Boolean = false,
    val moreError: AppError? = null,
)

/**
 * 通用游标分页：按 ID 去重（服务端会跨页返回重复短剧），处理加载更多、空态、错误。
 * 所有方法都在 scope（viewModelScope，主线程）里调用；页面销毁时 scope 取消，未完成的请求随之取消。
 */
class Paginator<T>(
    private val scope: CoroutineScope,
    private val idOf: (T) -> String,
    private var fetch: suspend (cursor: String?) -> PageResult<T>,
) {
    private val _state = MutableStateFlow(PagerState<T>())
    val state: StateFlow<PagerState<T>> = _state

    private var cursor: String? = null
    private val seen = HashSet<String>()
    private var generation = 0
    private var refreshJob: Job? = null
    private var moreJob: Job? = null
    /** 连续多少页没有新条目就停止（防止服务端一直返回重复内容导致无限加载）。 */
    private var barrenPages = 0

    /** 换一个数据源（例如筛选条件变化），并清空。 */
    fun reset(fetch: suspend (String?) -> PageResult<T>) {
        cancel()
        generation++
        this.fetch = fetch
        clear()
        _state.value = PagerState()
    }

    private fun clear() {
        cursor = null
        seen.clear()
        barrenPages = 0
    }

    /** 首次加载或下拉刷新。 */
    fun refresh() {
        cancel()
        refreshJob?.cancel()
        val gen = ++generation
        if (_state.value.items.isEmpty()) _state.value = _state.value.copy(load = LoadState.Loading)
        val f = fetch
        refreshJob = scope.launch {
            try {
                val page = f(null)
                if (gen != generation) return@launch
                clear()
                _state.value = PagerState()
                append(page)
                _state.value = _state.value.let { it.copy(load = if (it.items.isEmpty()) LoadState.Empty else LoadState.Loaded) }
            } catch (t: Throwable) {
                if (gen != generation) return@launch
                val e = AppError.from(t)
                if (e == null) {
                    // 被取消：退回 idle，下次进入时重新加载，而不是卡在 loading
                    if (_state.value.items.isEmpty()) _state.value = _state.value.copy(load = LoadState.Idle)
                    return@launch
                }
                _state.value = if (_state.value.items.isEmpty()) _state.value.copy(load = LoadState.Failed(e))
                else _state.value.copy(moreError = e)
            }
        }
    }

    /** 首次进入页面时调用：已经有数据就不重复加载。 */
    fun loadIfNeeded() {
        val s = _state.value.load
        if (s == LoadState.Idle || s is LoadState.Failed) refresh()
    }

    /** 列表滚到第 index 项时调用，接近末尾就加载下一页。 */
    fun onItemVisible(index: Int) {
        if (index >= _state.value.items.size - 5) loadMore()
    }

    fun loadMore() {
        val s = _state.value
        if (!s.hasMore || s.loadingMore || s.moreError != null || s.load != LoadState.Loaded) return
        _state.value = s.copy(loadingMore = true)
        val gen = generation
        val cur = cursor
        val f = fetch
        moreJob = scope.launch {
            try {
                val page = f(cur)
                if (gen != generation) return@launch
                append(page)
                _state.value = _state.value.copy(loadingMore = false)
            } catch (t: Throwable) {
                if (gen != generation) return@launch
                val e = AppError.from(t)
                _state.value = _state.value.copy(loadingMore = false, moreError = e)
            }
        }
    }

    fun retryLoadMore() {
        _state.value = _state.value.copy(moreError = null)
        loadMore()
    }

    fun cancel() {
        moreJob?.cancel()
        moreJob = null
        if (_state.value.loadingMore) _state.value = _state.value.copy(loadingMore = false)
    }

    private fun append(page: PageResult<T>) {
        val fresh = page.items.filter { seen.add(idOf(it)) }
        barrenPages = if (fresh.isEmpty()) barrenPages + 1 else 0
        val advanced = page.cursor != null && page.cursor != cursor
        cursor = page.cursor
        _state.value = _state.value.copy(
            items = _state.value.items + fresh,
            hasMore = page.hasMore && advanced && barrenPages < MAX_BARREN_PAGES,
        )
    }

    companion object {
        const val MAX_BARREN_PAGES = 3
    }
}

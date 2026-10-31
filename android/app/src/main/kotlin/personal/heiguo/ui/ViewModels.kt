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
import personal.heiguo.data.FollowedSeries
import personal.heiguo.data.Favorite
import personal.heiguo.data.WatchRecord
import personal.heiguo.domain.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

// ───────────────────────── 找剧 · 搜索 ─────────────────────────

data class SearchUiState(
    val query: String = "",
    val submitted: String? = null,
    val suggestions: List<SearchSuggestion> = emptyList(),
    val hot: HotSearchInfo = HotSearchInfo(),
    val hotState: LoadState = LoadState.Idle,
    val cue: String? = null,
)

class SearchViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(SearchUiState())
    val ui: StateFlow<SearchUiState> = _ui
    val results = Paginator<SeriesItem>(viewModelScope, { it.id }) { PageResult.empty() }
    private var suggestJob: Job? = null
    var debounceMs = 300L

    fun loadHot() {
        if (_ui.value.hotState == LoadState.Loaded) return
        _ui.update { it.copy(hotState = LoadState.Loading) }
        viewModelScope.launch {
            val cues = launch { runCatching { env.catalog.searchCues() }.getOrNull()?.firstOrNull()?.let { c -> _ui.update { it.copy(cue = c) } } }
            try {
                val hot = env.catalog.hotSearch()
                _ui.update { it.copy(hot = hot, hotState = if (hot.guesses.isEmpty() && hot.boards.isEmpty()) LoadState.Empty else LoadState.Loaded) }
            } catch (t: Throwable) {
                AppError.from(t)?.let { e -> _ui.update { it.copy(hotState = LoadState.Failed(e)) } }
            }
            cues.join()
        }
    }

    fun onQueryChange(text: String) {
        _ui.update { it.copy(query = text) }
        suggestJob?.cancel()
        val q = text.trim()
        if (q.isEmpty() || q == _ui.value.submitted) {
            _ui.update { it.copy(suggestions = emptyList()) }
            return
        }
        suggestJob = viewModelScope.launch {
            delay(debounceMs)
            val list = runCatching { env.catalog.suggest(q) }.getOrDefault(emptyList())
            _ui.update { it.copy(suggestions = list.take(10)) }
        }
    }

    /** 提交搜索。空输入时用搜索框里的提示词。 */
    fun submit(text: String? = null) {
        val q = (text ?: _ui.value.query).trim()
        val final = q.ifEmpty { _ui.value.cue ?: "" }
        if (final.isEmpty()) return
        suggestJob?.cancel()
        _ui.update { it.copy(query = final, submitted = final, suggestions = emptyList()) }
        results.reset { cursor -> env.catalog.search(final, cursor) }
        results.refresh()
    }

    fun clear() {
        suggestJob?.cancel()
        _ui.update { it.copy(query = "", submitted = null, suggestions = emptyList()) }
        results.reset { PageResult.empty() }
    }
}

// ───────────────────────── 找剧 · 筛选 ─────────────────────────

data class FilterUiState(
    val rows: List<FilterRowInfo> = emptyList(),
    val panel: LoadState = LoadState.Idle,
    /** 每行选中的值；不在 map 里表示“全部”。 */
    val selections: Map<String, String> = emptyMap(),
)

class FilterViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(FilterUiState())
    val ui: StateFlow<FilterUiState> = _ui
    val results = Paginator<SeriesItem>(viewModelScope, { it.id }) { c -> env.catalog.filter(emptyMap(), c) }

    fun load() {
        if (_ui.value.panel != LoadState.Loaded) {
            _ui.update { it.copy(panel = LoadState.Loading) }
            viewModelScope.launch {
                try {
                    val rows = env.catalog.filterPanel()
                    _ui.update { it.copy(rows = rows, panel = if (rows.isEmpty()) LoadState.Empty else LoadState.Loaded) }
                } catch (t: Throwable) {
                    AppError.from(t)?.let { e -> _ui.update { it.copy(panel = LoadState.Failed(e)) } }
                }
            }
        }
        results.loadIfNeeded()
    }

    /** 选择某行的某个值；choice 为 null 表示“全部”。 */
    fun select(row: FilterRowInfo, choice: FilterChoice?) {
        _ui.update {
            val m = it.selections.toMutableMap()
            if (choice != null && choice.value.isNotEmpty()) m[row.key] = choice.value else m.remove(row.key)
            it.copy(selections = m)
        }
        val query = _ui.value.selections.mapValues { listOf(it.value) }
        results.reset { c -> env.catalog.filter(query, c) }
        results.refresh()
    }
}

// ───────────────────────── 榜单 ─────────────────────────

data class RankUiState(val contents: List<RankContentInfo> = emptyList(), val content: String? = null, val board: String? = null) {
    val boards: List<RankBoardInfo> get() = contents.firstOrNull { it.id == content }?.boards ?: emptyList()
}

class RankViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(RankUiState())
    val ui: StateFlow<RankUiState> = _ui
    val results = Paginator<SeriesItem>(viewModelScope, { it.id }) { PageResult.empty() }

    init { configure() }

    private fun configure() {
        val content = _ui.value.content
        val board = _ui.value.board
        results.reset { cursor ->
            val page = env.catalog.rank(content, board, cursor)
            if (cursor == null) {
                _ui.update {
                    it.copy(
                        contents = page.contents.ifEmpty { it.contents },
                        content = it.content ?: page.content.ifEmpty { null },
                        board = it.board ?: page.board.ifEmpty { null },
                    )
                }
            }
            page.page
        }
    }

    fun load() = results.loadIfNeeded()

    fun selectContent(id: String) {
        if (id == _ui.value.content) return
        _ui.update { it.copy(content = id, board = null) }
        configure(); results.refresh()
    }

    fun selectBoard(id: String) {
        if (id == _ui.value.board) return
        _ui.update { it.copy(board = id) }
        configure(); results.refresh()
    }
}

// ───────────────────────── 上新日历 ─────────────────────────

data class NewReleasesUiState(val dates: List<String> = emptyList(), val selected: String? = null)

class NewReleasesViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(NewReleasesUiState())
    val ui: StateFlow<NewReleasesUiState> = _ui
    val results = Paginator<NewReleaseItem>(viewModelScope, { it.series.id }) { PageResult.empty() }

    init { configure() }

    private fun configure() {
        val date = _ui.value.selected
        results.reset { cursor ->
            val day = env.catalog.newReleases(date, cursor)
            if (cursor == null) {
                _ui.update { it.copy(dates = day.dates.ifEmpty { it.dates }, selected = it.selected ?: day.date.ifEmpty { null }) }
            }
            day.page
        }
    }

    fun load() = results.loadIfNeeded()

    fun select(date: String) {
        if (date == _ui.value.selected) return
        _ui.update { it.copy(selected = date) }
        configure(); results.refresh()
    }

    companion object {
        /** "20261031" → "10/31 周五"；今天显示“今天”。 */
        fun label(yyyymmdd: String, today: Calendar = Calendar.getInstance()): String {
            val f = SimpleDateFormat("yyyyMMdd", Locale.CHINA)
            val d = runCatching { f.parse(yyyymmdd) }.getOrNull() ?: return yyyymmdd
            val c = Calendar.getInstance().apply { time = d }
            if (c.get(Calendar.YEAR) == today.get(Calendar.YEAR) && c.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)) return "今天"
            return SimpleDateFormat("M/d E", Locale.CHINA).format(d)
        }
    }
}

// ───────────────────────── 详情 ─────────────────────────

sealed interface EpisodeStatus {
    data object Unwatched : EpisodeStatus
    data class InProgress(val fraction: Float) : EpisodeStatus
    data object Finished : EpisodeStatus
    data object Encrypted : EpisodeStatus
    data object Unplayable : EpisodeStatus
}

data class ResumeTarget(val episode: EpisodeItem, val seconds: Double, val label: String)

data class DetailUiState(
    val series: SeriesInfo? = null,
    val state: LoadState = LoadState.Idle,
    val episodes: List<EpisodeItem> = emptyList(),
    val episodesState: LoadState = LoadState.Idle,
    val isFavorite: Boolean = false,
    val isFollowed: Boolean = false,
    val records: Map<Int, WatchRecord> = emptyMap(),
    val encrypted: Set<String> = emptySet(),
    val resume: ResumeTarget? = null,
)

class SeriesDetailViewModel(val seriesId: String, private val env: AppEnv, preview: SeriesItem? = null) : ViewModel() {
    private val _ui = MutableStateFlow(
        DetailUiState(series = preview?.let { SeriesInfo(it.id, it.title, it.summary, it.coverUrl, it.episodeCount) }),
    )
    val ui: StateFlow<DetailUiState> = _ui

    fun load(force: Boolean = false) {
        viewModelScope.launch {
            refreshLocal()
            if (_ui.value.state == LoadState.Loaded && !force) return@launch
            _ui.update { it.copy(state = LoadState.Loading, episodesState = LoadState.Loading) }
            val info = launch {
                try {
                    val s = env.catalog.series(seriesId, force)
                    _ui.update { it.copy(series = s, state = LoadState.Loaded) }
                    env.library.acknowledgeUpdate(s)
                } catch (t: Throwable) {
                    AppError.from(t)?.let { e -> _ui.update { it.copy(state = LoadState.Failed(e)) } }
                }
            }
            val eps = launch {
                try {
                    val list = env.catalog.episodes(seriesId, force)
                    _ui.update { it.copy(episodes = list, episodesState = if (list.isEmpty()) LoadState.Empty else LoadState.Loaded) }
                } catch (t: Throwable) {
                    AppError.from(t)?.let { e -> _ui.update { it.copy(episodesState = LoadState.Failed(e)) } }
                }
            }
            info.join(); eps.join()
            refreshLocal()
        }
    }

    /** 从本机资料库刷新观看状态、收藏、追更（从播放页返回时调用）。 */
    fun refreshLocal() {
        viewModelScope.launch { refreshLocalNow() }
    }

    private suspend fun refreshLocalNow() {
        val records = env.library.records(seriesId)
        val encrypted = env.library.encryptedEpisodeIds(seriesId)
        val fav = env.library.isFavorite(seriesId)
        val follow = env.library.followed(seriesId) != null
        val last = env.library.lastWatched(seriesId)
        _ui.update {
            it.copy(
                records = records, encrypted = encrypted,
                isFavorite = fav, isFollowed = follow, resume = computeResume(it.episodes, last),
            )
        }
    }

    private fun computeResume(episodes: List<EpisodeItem>, last: WatchRecord?): ResumeTarget? {
        if (episodes.isEmpty()) return null
        val idx = last?.let { l -> episodes.indexOfFirst { it.number == l.episodeNumber } } ?: -1
        if (last == null || idx < 0) return ResumeTarget(episodes[0], 0.0, if (last == null) "从第 1 集开始" else "看第 ${episodes[0].number} 集")
        if (last.isFinished && idx + 1 < episodes.size) return ResumeTarget(episodes[idx + 1], 0.0, "看第 ${episodes[idx + 1].number} 集")
        val secs = if (last.isFinished) 0.0 else last.progressSeconds
        return ResumeTarget(episodes[idx], secs, if (secs > 0) "继续看第 ${episodes[idx].number} 集" else "看第 ${episodes[idx].number} 集")
    }

    fun toggleFavorite() {
        val s = _ui.value.series ?: return
        viewModelScope.launch { env.library.toggleFavorite(s); refreshLocalNow() }
    }

    fun toggleFollow() {
        val s = _ui.value.series ?: return
        viewModelScope.launch { env.library.toggleFollow(s); refreshLocalNow() }
    }

    companion object {
        fun status(ui: DetailUiState, ep: EpisodeItem): EpisodeStatus {
            if (!ep.playable) return EpisodeStatus.Unplayable
            if (ep.id in ui.encrypted) return EpisodeStatus.Encrypted
            val r = ui.records[ep.number] ?: return EpisodeStatus.Unwatched
            if (r.isFinished) return EpisodeStatus.Finished
            if (r.durationSeconds <= 0) return if (r.progressSeconds > 0) EpisodeStatus.InProgress(0.05f) else EpisodeStatus.Unwatched
            return EpisodeStatus.InProgress((r.progressSeconds / r.durationSeconds).toFloat().coerceIn(0.02f, 1f))
        }
    }
}

// ───────────────────────── 我的 ─────────────────────────

data class LibraryUiState(
    val history: List<WatchRecord> = emptyList(),
    val favorites: List<Favorite> = emptyList(),
    val follows: List<FollowedSeries> = emptyList(),
) {
    val updatedFollowCount: Int get() = follows.count { it.hasUpdate }
}

class LibraryViewModel(private val env: AppEnv) : ViewModel() {
    private val _ui = MutableStateFlow(LibraryUiState())
    val ui: StateFlow<LibraryUiState> = _ui

    init {
        // 资料库每次写入后刷新
        viewModelScope.launch { env.library.revision.collect { reload() } }
    }

    fun reload() {
        viewModelScope.launch {
            _ui.value = LibraryUiState(env.library.history(), env.library.favorites(), env.library.followedSeries())
        }
    }

    fun deleteHistory(seriesId: String) { viewModelScope.launch { env.library.deleteHistory(seriesId) } }
    fun clearHistory() { viewModelScope.launch { env.library.clearHistory() } }
}

/** 追更检查：打开 App（以及回到前台，最多每 10 分钟一次）时批量拉取追更剧的详情，对比集数。只在 App 内打标记。 */
class FollowUpdateChecker(private val env: AppEnv, private val minIntervalMs: Long = 600_000) {
    private var checking = false
    private var lastChecked = 0L

    suspend fun checkIfNeeded(force: Boolean = false) {
        if (checking) return
        if (!force && System.currentTimeMillis() - lastChecked < minIntervalMs) return
        val ids = env.library.followedSeries().filter { !it.isFinished }.map { it.seriesId }
        if (ids.isEmpty()) { lastChecked = System.currentTimeMillis(); return }
        checking = true
        try {
            val infos = env.catalog.seriesBatch(ids)
            env.library.applyLatest(infos)
            lastChecked = System.currentTimeMillis()
        } finally {
            checking = false
        }
    }
}

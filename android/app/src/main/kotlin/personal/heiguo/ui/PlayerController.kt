package personal.heiguo.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import personal.heiguo.AppEnv
import personal.heiguo.domain.*
import personal.heiguo.support.AppLog

sealed interface PlayerState {
    data object Idle : PlayerState
    data object Resolving : PlayerState
    /** 可以播放：地址、起播秒数。nonce 保证同一地址重新起播也能触发界面更新。 */
    data class Ready(val url: String, val startAt: Double, val nonce: Int = 0) : PlayerState
    data object Unplayable : PlayerState
    data class Failed(val error: AppError) : PlayerState
}

/**
 * 播放一部剧：选集、请求播放模型（仅在真正要播时）、断点续播、自动连播。
 * 不持有播放器：界面拿 state 里的地址自己播放，再把进度和结束事件回传，方便测试。
 */
class PlayerController(
    val seriesId: String,
    val seriesTitle: String,
    val coverUrl: String?,
    val episodes: List<EpisodeItem>,
    startIndex: Int,
    private val startAt: Double,
    private val env: AppEnv,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow<PlayerState>(PlayerState.Idle)
    val state: StateFlow<PlayerState> = _state
    private val _index = MutableStateFlow(startIndex.coerceIn(0, maxOf(0, episodes.size - 1)))
    val index: StateFlow<Int> = _index
    var autoplayNext = true

    private var resolveJob: Job? = null
    private var streams: List<StreamInfo> = emptyList()
    private var lastSaved: Triple<Int, Double, Long>? = null // 集号、秒、时间
    private var duration = 0.0
    private var nonce = 0

    val current: EpisodeItem? get() = episodes.getOrNull(_index.value)
    val hasNext: Boolean get() = _index.value + 1 < episodes.size
    val hasPrevious: Boolean get() = _index.value > 0

    /** 开始播放当前集。重复调用不会重复请求（仓库层缓存 + 合并）。 */
    fun start() = play(_index.value, startAt)

    /** startAt 为 null 或负数：用本机记录的进度续播。 */
    fun play(newIndex: Int, startAt: Double? = null) {
        if (newIndex !in episodes.indices) return
        scope.launch { flushProgress() }
        resolveJob?.cancel()
        _index.value = newIndex
        duration = 0.0
        val ep = episodes[newIndex]
        if (!ep.playable) { _state.value = PlayerState.Unplayable; return }
        _state.value = PlayerState.Resolving
        resolveJob = scope.launch {
            try {
                val resume = if (startAt != null && startAt >= 0) startAt else resumeSeconds(ep)
                val info = env.playback.playback(ep.id)
                if (current?.id != ep.id) return@launch
                streams = info.streams
                val stream = info.preferredStream
                if (stream == null) {
                    _state.value = PlayerState.Failed(AppError(AppError.Code.NO_PLAYABLE_STREAM)); return@launch
                }
                duration = info.durationSeconds.toDouble()
                _state.value = PlayerState.Ready(stream.url, resume, nonce++)
            } catch (t: Throwable) {
                if (current?.id != ep.id) return@launch
                val e = AppError.from(t) ?: return@launch // 取消：不要覆盖界面状态
                AppLog.error(e, "playback")
                _state.value = PlayerState.Failed(e)
            }
        }
    }

    fun retry() = play(_index.value)
    fun next() { if (hasNext) play(_index.value + 1, 0.0) }
    fun previous() { if (hasPrevious) play(_index.value - 1) }

    /** 播放器播放当前地址失败时调用：依次换备用地址、其他清晰度；都失败才报错。不会重新请求播放模型。 */
    fun playerFailed(message: String, atSeconds: Double) {
        val st = _state.value as? PlayerState.Ready ?: return
        val candidates = streams.flatMap { listOfNotNull(it.url, it.backupUrl) }
        val i = candidates.indexOf(st.url)
        _state.value = if (i >= 0 && i + 1 < candidates.size) PlayerState.Ready(candidates[i + 1], atSeconds, nonce++)
        else PlayerState.Failed(AppError(AppError.Code.NO_PLAYABLE_STREAM, message))
    }

    /** 播放进度回调（界面每秒左右调用一次）。 */
    fun progress(seconds: Double, durationSeconds: Double) {
        val ep = current ?: return
        if (!seconds.isFinite()) return
        if (durationSeconds.isFinite() && durationSeconds > 0) duration = durationSeconds
        val now = System.currentTimeMillis()
        val l = lastSaved
        if (l != null && l.first == ep.number && now - l.third < SAVE_INTERVAL_MS) {
            lastSaved = Triple(ep.number, seconds, l.third) // 只更新内存里的最新进度
            return
        }
        save(ep, seconds)
    }

    /** 当前集播完。 */
    fun didFinish() {
        current?.let { save(it, maxOf(duration, 1.0)) }
        if (autoplayNext && hasNext) play(_index.value + 1, 0.0)
    }

    /** 离开页面：取消未完成的请求，写入最后进度。 */
    fun stop(atSeconds: Double? = null) {
        resolveJob?.cancel()
        val ep = current
        if (atSeconds != null && ep != null && _state.value is PlayerState.Ready) save(ep, atSeconds)
        else scope.launch { flushProgress() }
    }

    private suspend fun flushProgress() {
        val l = lastSaved ?: return
        val ep = current ?: return
        if (l.first == ep.number) env.library.saveProgress(seriesId, seriesTitle, coverUrl, ep, l.second, duration)
    }

    private fun save(ep: EpisodeItem, seconds: Double) {
        lastSaved = Triple(ep.number, seconds, System.currentTimeMillis())
        val d = duration
        scope.launch { env.library.saveProgress(seriesId, seriesTitle, coverUrl, ep, seconds, d) }
    }

    private suspend fun resumeSeconds(ep: EpisodeItem): Double {
        val r = env.library.record(seriesId, ep.number) ?: return 0.0
        return if (r.isFinished) 0.0 else maxOf(0.0, r.progressSeconds - 2) // 往回退 2 秒，接上剧情
    }

    companion object {
        const val SAVE_INTERVAL_MS = 5_000L
    }
}

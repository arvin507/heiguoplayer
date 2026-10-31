package personal.heiguo.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import personal.heiguo.AppEnv
import personal.heiguo.domain.*
import personal.heiguo.media.CENCDecryptor
import personal.heiguo.media.ProtectedMediaStore
import personal.heiguo.support.AppLog
import java.io.File

sealed interface PlayerState {
    data object Idle : PlayerState
    data object Resolving : PlayerState
    /** 加密分集正在下载 / 解密，progress 0..1。 */
    data class Preparing(val progress: Float) : PlayerState
    /** 可以播放：地址、起播秒数。加密分集给的是本地解密后的文件。nonce 保证同一地址重新起播也能触发界面更新。 */
    data class Ready(val url: String, val startAt: Double, val nonce: Int = 0) : PlayerState
    /** 服务端没有下发内容密钥，解不了。 */
    data object KeyUnavailable : PlayerState
    data object Unplayable : PlayerState
    data class Failed(val error: AppError) : PlayerState
}

/**
 * 播放一部剧：选集、请求播放模型（仅在真正要播时）、断点续播、自动连播、预解密后续几集。
 * 不持有播放器：界面拿 state 里的地址自己播放，再把进度和结束事件回传，方便测试。
 *
 * @param prefetchCount 当前集可播后，提前解密后面几集。0 表示不预取（推荐流用 0，别白耗设备额度）。
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
    private val prefetchCount: Int = 0,
) {
    private val _state = MutableStateFlow<PlayerState>(PlayerState.Idle)
    val state: StateFlow<PlayerState> = _state
    private val _index = MutableStateFlow(startIndex.coerceIn(0, maxOf(0, episodes.size - 1)))
    val index: StateFlow<Int> = _index
    var autoplayNext = true

    private var resolveJob: Job? = null
    private var prefetchJob: Job? = null
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
        prefetchJob?.cancel()
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

                if (info.isProtected || stream.isProtected) {
                    // 加密分集：记一下，分集网格会标个锁；然后下载 + 解密到本地再播。
                    env.library.markEncrypted(ep.id, seriesId)
                    val key = info.usableKey
                    if (key == null) {
                        _state.value = PlayerState.KeyUnavailable; return@launch
                    }
                    _state.value = PlayerState.Preparing(0f)
                    val file = env.protectedMedia.prepare(ep.id, stream, key) { stage ->
                        if (current?.id == ep.id) _state.value = PlayerState.Preparing(progressOf(stage))
                    }
                    if (current?.id != ep.id) return@launch
                    _state.value = PlayerState.Ready(localUri(file), resume, nonce++)
                    schedulePrefetch(newIndex)
                    return@launch
                }

                _state.value = PlayerState.Ready(stream.url, resume, nonce++)
                schedulePrefetch(newIndex)
            } catch (t: Throwable) {
                if (current?.id != ep.id) return@launch
                val e = mapError(t) ?: return@launch // 取消：不要覆盖界面状态
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
        // 解密后的本地文件没有备用地址可换，直接报错（也不会再消耗额度）。
        if (st.url.startsWith("file:")) {
            _state.value = PlayerState.Failed(AppError(AppError.Code.DECODING, message))
            return
        }
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

    /** 离开页面：取消未完成的请求和预解密，写入最后进度。 */
    fun stop(atSeconds: Double? = null) {
        resolveJob?.cancel()
        prefetchJob?.cancel()
        env.protectedMedia.cancelPrefetch()
        val ep = current
        if (atSeconds != null && ep != null && _state.value is PlayerState.Ready) save(ep, atSeconds)
        else scope.launch { flushProgress() }
    }

    // ───────────────────────── 预解密 ─────────────────────────

    /**
     * 当前集可播之后，把后面几集的播放模型取回来排进后台解密队列。
     * 任何一次取模型失败就整体停下：大概率是设备额度用尽，继续请求只会把后面几集一起拖垮。
     */
    private fun schedulePrefetch(after: Int) {
        prefetchJob?.cancel()
        if (prefetchCount <= 0) return
        val from = after + 1
        if (from >= episodes.size) return
        val targets = episodes.subList(from, minOf(from + prefetchCount, episodes.size))
        prefetchJob = scope.launch {
            for (ep in targets) {
                if (!isActive) return@launch
                val info = try {
                    env.playback.playback(ep.id)
                } catch (t: Throwable) {
                    AppError.from(t)?.let { AppLog.net("prefetch resolve ${ep.id} failed: ${it.debugMessage}") }
                    return@launch
                }
                if (!isActive) return@launch
                val stream = info.preferredStream ?: continue
                if (!(info.isProtected || stream.isProtected)) continue
                val key = info.usableKey ?: continue
                env.protectedMedia.enqueue(listOf(ProtectedMediaStore.DecryptJob(ep.id, stream, key)))
            }
        }
    }

    // ───────────────────────── 内部 ─────────────────────────

    private fun progressOf(stage: ProtectedMediaStore.Stage): Float = when (stage) {
        is ProtectedMediaStore.Stage.Downloading ->
            if (stage.fraction < 0f) 0f else (stage.fraction * DOWNLOAD_SHARE).coerceIn(0f, DOWNLOAD_SHARE)
        is ProtectedMediaStore.Stage.Decrypting ->
            (DOWNLOAD_SHARE + stage.fraction * (1f - DOWNLOAD_SHARE)).coerceIn(DOWNLOAD_SHARE, 1f)
    }

    private fun mapError(t: Throwable): AppError? = when (t) {
        is ProtectedMediaStore.Failure -> AppError(AppError.Code.TRANSPORT, t.message ?: "prepare failed")
        is CENCDecryptor.Failure -> AppError(AppError.Code.DECODING, t.message ?: "cenc failed")
        else -> AppError.from(t)
    }

    private fun localUri(file: File): String = "file://" + file.absolutePath

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
        /** 下载阶段占进度的比重，剩下的是解密。 */
        private const val DOWNLOAD_SHARE = 0.35f
    }
}

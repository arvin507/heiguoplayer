package personal.heiguo.repo

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import personal.heiguo.domain.AppError
import personal.heiguo.domain.PlaybackInfo
import personal.heiguo.service.HongguoService
import personal.heiguo.support.AppLog
import personal.heiguo.support.DelaySleeper
import personal.heiguo.support.Sleeper
import personal.heiguo.support.TaskCoalescer
import kotlin.math.pow

/**
 * 播放模型仓库。服务端基本只给每台匿名设备一次播放模型，所以这里：
 * - 只在调用方真正要播放时请求，不提供任何预取接口；
 * - 全局串行（Mutex，先来后到、可取消），同一集并发请求合并（TaskCoalescer），结果按集缓存；
 * - ANONYMOUS_LIMITED：重置设备后重试，最多 2 次；DEVICE_REJECTED：重置后重试 1 次；
 * - RATE_LIMITED：建议等待 ≤ 10 秒时退避重试（最多 2 次），超过 10 秒直接失败并进入冷却期，
 *   冷却期内的请求不发网络、立即失败；
 * - 其他错误（TRANSPORT 等）不自动重试，交给界面的“重试”按钮。
 */
class PlaybackRepository(
    private val service: HongguoService,
    private val sleeper: Sleeper = DelaySleeper,
    private val policy: Policy = Policy(),
    private val now: () -> Long = { System.currentTimeMillis() },
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    data class Policy(
        val maxLimitedResets: Int = 2,
        val maxRejectedResets: Int = 1,
        val maxRateLimitRetries: Int = 2,
        /** 超过这个等待时间（秒）就不在原地等，直接提示用户稍后再试。 */
        val maxInlineWait: Double = 10.0,
        val defaultBackoff: Double = 1.0,
        /** 流地址离过期不足这么多毫秒就视为过期。 */
        val expiryMarginMs: Long = 30_000,
    )

    private val gate = Mutex()
    private val coalescer = TaskCoalescer<String, PlaybackInfo>(scope)
    private val cacheLock = Any()
    private val cache = HashMap<String, PlaybackInfo>()
    @Volatile private var cooldownUntil: Long? = null

    /** 内存里已有的结果（不发请求）。 */
    fun cached(episodeId: String): PlaybackInfo? {
        val info = synchronized(cacheLock) { cache[episodeId] } ?: return null
        // 一条可播流都没有说明这一集当前确实放不了，反复请求只会白耗额度，所以这个结果也当作有效缓存。
        if (info.streams.isEmpty()) return info
        val exp = info.expiresAtMs
        if (exp != null && exp - now() < policy.expiryMarginMs) return null
        return info
    }

    /** 冷却期剩余秒数；null 表示不在冷却期。 */
    fun cooldownRemaining(): Double? {
        val until = cooldownUntil ?: return null
        val left = (until - now()) / 1000.0
        return if (left > 0) left else null
    }

    /** 取得一集的播放模型。只应在用户真正要播放这一集时调用。 */
    suspend fun playback(episodeId: String): PlaybackInfo {
        cached(episodeId)?.let { return it }
        return coalescer.value(episodeId) { commit ->
            gate.withLock { resolveSerialized(episodeId, commit) } // 排队中可以被取消
        }
    }

    private suspend fun resolveSerialized(episodeId: String, commit: () -> Unit): PlaybackInfo {
        cached(episodeId)?.let { return it }
        currentCoroutineContext().ensureActive()

        var limitedResets = 0
        var rejectedResets = 0
        var rateRetries = 0
        var lastLimited: AppError? = null

        while (true) {
            cooldownRemaining()?.let { throw AppError(AppError.Code.RATE_LIMITED, "cooldown", it) }
            commit() // 请求即将发出：从这里起即使页面离开也让它跑完并缓存结果
            try {
                val info = service.resolvePlayback(episodeId)
                synchronized(cacheLock) { cache[episodeId] = info }
                return info
            } catch (e: AppError) {
                when (e.code) {
                    AppError.Code.ANONYMOUS_LIMITED -> {
                        lastLimited = e
                        if (limitedResets >= policy.maxLimitedResets) {
                            throw AppError(AppError.Code.PLAYBACK_QUOTA_EXHAUSTED,
                                "ANONYMOUS_LIMITED after $limitedResets resets: ${lastLimited.debugMessage}")
                        }
                        limitedResets++
                        AppLog.net("playback limited, resetDevice #$limitedResets")
                        service.resetDevice()
                    }
                    AppError.Code.DEVICE_REJECTED -> {
                        if (rejectedResets >= policy.maxRejectedResets) throw e
                        rejectedResets++
                        AppLog.net("device rejected, resetDevice")
                        service.resetDevice()
                    }
                    AppError.Code.RATE_LIMITED -> {
                        val wait = e.retryAfter ?: (policy.defaultBackoff * 2.0.pow(rateRetries))
                        if (wait > policy.maxInlineWait || rateRetries >= policy.maxRateLimitRetries) {
                            cooldownUntil = now() + (maxOf(wait, policy.maxInlineWait) * 1000).toLong()
                            throw AppError(AppError.Code.RATE_LIMITED, e.debugMessage, wait)
                        }
                        rateRetries++
                        AppLog.net("rate limited, backoff ${wait}s (#$rateRetries)")
                        sleeper.sleep(wait)
                    }
                    else -> throw e
                }
            }
        }
    }
}

package personal.heiguo.support

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import personal.heiguo.domain.AppError

/**
 * 日志脱敏：把文本里所有 URL 的查询参数值替换成 ***，防止日志带出设备 ID 之类的敏感信息。
 */
object Redactor {
    private val urlPattern = Regex("""https?://[^\s"'<>]+""")

    fun redact(text: String): String = urlPattern.replace(text) { redactUrl(it.value) }

    /** 保留 scheme、host、path；查询参数只保留键名，值一律替换。 */
    fun redactUrl(raw: String): String {
        val noFragment = raw.substringBefore('#')
        val q = noFragment.indexOf('?')
        if (q < 0) return stripUserInfo(noFragment)
        val base = stripUserInfo(noFragment.substring(0, q))
        val keys = noFragment.substring(q + 1).split('&').filter { it.isNotEmpty() }.map { it.substringBefore('=') + "=***" }
        return if (keys.isEmpty()) base else "$base?${keys.joinToString("&")}"
    }

    private fun stripUserInfo(u: String): String = u.replace(Regex("""^(https?://)[^/@]*@"""), "$1")
}

/** App 的日志入口：统一经过 Redactor。 */
object AppLog {
    private const val TAG = "Heiguo"
    fun net(message: String) { Log.d(TAG, Redactor.redact(message)) }
    fun trace(message: String) { Log.i(TAG, Redactor.redact(message)) }
    fun error(e: AppError, context: String) { Log.e(TAG, Redactor.redact("$context: [${e.code.raw}] ${e.debugMessage}")) }
}

/** 从分享链接或纯数字文本中取出短剧 ID（启发式规则）。 */
object SeriesLinkParser {
    private val idKeys = listOf("series_id", "seriesid", "video_series_id", "book_id", "bookid", "item_id", "id")
    private val longDigits = Regex("""(?<!\d)\d{15,20}(?!\d)""")
    private val urlPattern = Regex("""https?://[^\s"'<>，。]+""")

    fun parse(input: String): String? {
        val text = input.trim()
        if (text.isEmpty()) return null
        if (text.all { it.isDigit() } && text.length in 6..20) return text
        for (m in urlPattern.findAll(text)) idFromUrl(m.value)?.let { return it }
        return longDigits.find(text)?.value
    }

    internal fun idFromUrl(raw: String): String? {
        val noFragment = raw.substringBefore('#')
        val path = noFragment.substringBefore('?')
        val query = noFragment.substringAfter('?', "")
        val pairs = query.split('&').mapNotNull {
            val i = it.indexOf('=')
            if (i <= 0) null else it.substring(0, i).lowercase() to it.substring(i + 1)
        }
        for (key in idKeys) {
            val v = pairs.firstOrNull { it.first == key }?.second
            if (v != null && v.length >= 6 && v.all { it.isDigit() }) return v
        }
        return longDigits.find(path)?.value
    }
}

/**
 * 按 key 合并并发的相同请求：同一个 key 同时只跑一个任务，后来者等待同一个结果。
 *
 * 取消规则：
 * - 某个等待者被取消时，它自己立即抛出 CancellationException；
 * - 所有等待者都离开、且任务还没有 commit 时，取消底层任务（例如还在排队的播放请求）；
 * - 任务调用过 commit（表示请求已经发出、额度已经消耗）后，即使没人等也让它跑完，
 *   结果由任务自己写入缓存，下次直接复用，不再重复请求。
 */
class TaskCoalescer<K : Any, V>(private val scope: CoroutineScope) {
    private class Entry<V> {
        val result = CompletableDeferred<V>()
        var waiters = 0
        @Volatile var committed = false
        var job: Job? = null
    }

    private val lock = Mutex()
    private val entries = HashMap<K, Entry<V>>()

    /** 正在进行的 key 数量（测试用）。 */
    suspend fun inFlightCount(): Int = lock.withLock { entries.size }

    suspend fun value(key: K, operation: suspend (commit: () -> Unit) -> V): V {
        val entry = lock.withLock {
            entries[key]?.also { it.waiters++ } ?: Entry<V>().also { e ->
                e.waiters = 1
                entries[key] = e
                e.job = scope.launch(start = CoroutineStart.LAZY) {
                    try {
                        e.result.complete(operation { e.committed = true })
                    } catch (t: Throwable) {
                        e.result.completeExceptionally(t)
                    } finally {
                        withContext(NonCancellable) {
                            lock.withLock { if (entries[key] === e) entries.remove(key) }
                        }
                    }
                }
                e.job!!.start()
            }
        }
        try {
            return entry.result.await()
        } finally {
            withContext(NonCancellable) {
                lock.withLock {
                    entry.waiters--
                    if (entry.waiters == 0 && !entry.committed && !entry.result.isCompleted) {
                        entry.job?.cancel()
                        // 后来者重新发起，不要挂到已取消的任务上
                        if (entries[key] === entry) entries.remove(key)
                    }
                }
            }
        }
    }
}

/** 可替换的睡眠，测试里换成立即返回。 */
fun interface Sleeper {
    suspend fun sleep(seconds: Double)
}

object DelaySleeper : Sleeper {
    override suspend fun sleep(seconds: Double) = delay((seconds * 1000).toLong())
}

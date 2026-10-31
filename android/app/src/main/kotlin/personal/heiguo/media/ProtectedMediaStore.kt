package personal.heiguo.media

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import personal.heiguo.domain.StreamInfo
import personal.heiguo.support.AppLog
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.cancellation.CancellationException

/**
 * 加密分集的本地准备器：下载 → 解密 → 落到缓存目录，返回可以交给 ExoPlayer 的本地文件。
 *
 * 为什么落盘而不是边下边解：ExoPlayer 对本地 mp4 的 seek、倍速、连播都最稳，
 * 也不用自己维护一个本地代理的 Range 逻辑；代价是首次播放要等整集下载完。
 * 一集短剧通常 10~40MB，下载解密后按 `episodeId + 清晰度` 缓存，同一集再播不再走网络。
 *
 * 预解密队列串行执行：当前正在播的那集先准备好，再依次处理后面的几集，不抢带宽。
 */
class ProtectedMediaStore(
    /** 解密后的文件目录。系统清理缓存时会一起被删掉，无所谓。 */
    private val root: File,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    /** 单个文件的大小上限，防止异常响应把内存打满。 */
    private val sizeLimit: Long = 400L * 1024 * 1024,
    private val cacheLimit: Long = 1_500L * 1024 * 1024,
) {
    sealed interface Stage {
        /** 下载中；fraction < 0 表示服务端没给 Content-Length，进度未知。 */
        data class Downloading(val fraction: Float) : Stage

        data class Decrypting(val fraction: Float) : Stage
    }

    /** 下载 / 解密失败。上层会把它翻译成可重试的网络错误。 */
    class Failure(message: String) : Exception(message)

    /**
     * 一集的预解密任务：加密流地址 + 内容密钥。
     * 名字刻意不叫 Job，避免和协程的 `kotlinx.coroutines.Job` 在类内互相遮住。
     */
    class DecryptJob(val episodeId: String, val stream: StreamInfo, val key: ByteArray)

    private val lock = Any()
    private val queue = ArrayDeque<DecryptJob>()
    private var pump: Job? = null

    /** 同一集正在准备时，后来的调用排队等它，不会重复下载。 */
    private val gates = HashMap<String, Mutex>()

    init {
        runCatching { root.mkdirs() }
    }

    /** 解密后的文件位置（纯路径计算，不碰磁盘）。 */
    fun fileFor(episodeId: String, height: Int): File =
        File(root, "${episodeId.replace('/', '_')}-$height.mp4")

    fun isCached(episodeId: String, height: Int): Boolean = fileFor(episodeId, height).isFile

    /** 这一集是否已经有解密后的文件（任意清晰度）。 */
    fun isCached(episodeId: String): Boolean {
        val prefix = episodeId.replace('/', '_') + "-"
        return root.list()?.any { it.startsWith(prefix) && it.endsWith(".mp4") } == true
    }

    /**
     * 删掉指定分集的解密文件，返回释放的字节数。
     * 清了之后再看会重新解密，也就重新消耗一次设备额度——所以只能由用户显式触发。
     */
    fun clearCache(episodeIds: Collection<String>): Long {
        if (episodeIds.isEmpty()) return 0
        val files = root.listFiles() ?: return 0
        var freed = 0L
        for (f in files) {
            val name = f.name
            if (!name.endsWith(".mp4")) continue
            val dash = name.lastIndexOf('-')
            if (dash <= 0) continue
            if (name.substring(0, dash) !in episodeIds) continue
            val size = f.length()
            if (f.delete()) freed += size
        }
        if (freed > 0) AppLog.net("cenc cache cleared bytes=$freed")
        return freed
    }

    /**
     * 已经有解密文件的分集 id 集合。只列一次目录，用于详情页给分集打“本地已有”标记。
     * 文件名的形态是 `<episodeId>-<height>.mp4`。
     */
    fun cachedEpisodeIds(): Set<String> {
        val names = root.list() ?: return emptySet()
        val out = HashSet<String>(names.size)
        for (n in names) {
            if (!n.endsWith(".mp4")) continue
            val dash = n.lastIndexOf('-')
            if (dash <= 0) continue
            out.add(n.substring(0, dash))
        }
        return out
    }

    /**
     * 准备一集加密内容，返回可以播放的本地文件。
     *
     * @param onStage 进度回调，可能在任意线程触发。
     * @throws Failure 下载或解密失败。
     */
    suspend fun prepare(
        episodeId: String,
        stream: StreamInfo,
        key: ByteArray,
        onStage: (Stage) -> Unit = {},
    ): File {
        if (key.size != 16) throw Failure("缺少内容密钥")
        if (!CENCDecryptor.supports(stream.encryption)) throw Failure("不支持的加密方案：${stream.encryption}")

        val dest = fileFor(episodeId, stream.height)
        if (dest.isFile) return dest // 已经有缓存，直接播

        val token = "$episodeId#${stream.height}"
        val gate = synchronized(lock) { gates.getOrPut(token) { Mutex() } }
        return gate.withLock {
            if (dest.isFile) dest else produce(episodeId, stream, key, dest, onStage)
        }
    }

    // ───────────────────────── 后台预解密 ─────────────────────────

    /**
     * 把几集排进后台队列。已经在缓存里、或已经在队列里的会跳过。
     * 队列串行执行，当前正在播的那集准备完再开始。
     */
    fun enqueue(jobs: List<DecryptJob>) {
        synchronized(lock) {
            for (job in jobs) {
                if (isCached(job.episodeId, job.stream.height)) continue
                if (queue.any { it.episodeId == job.episodeId }) continue
                queue.addLast(job)
            }
            // 用户狂切集时不让队列无限增长，只保留最近的几集。
            while (queue.size > MAX_QUEUE) queue.removeFirst()
            if (pump == null && queue.isNotEmpty()) pump = scope.launch { drain() }
        }
    }

    /** 放弃还没开始的预解密（已经开始的那一集会跑完，结果直接进缓存）。 */
    fun cancelPrefetch() {
        synchronized(lock) { queue.clear() }
    }

    private suspend fun drain() {
        val self = currentCoroutineContext()[Job]
        while (true) {
            val job = synchronized(lock) {
                val next = queue.removeFirstOrNull()
                if (next == null && pump === self) pump = null
                next
            } ?: return
            if (isCached(job.episodeId, job.stream.height)) continue
            try {
                prepare(job.episodeId, job.stream, job.key)
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                // 预解密失败不影响正在看的内容，继续下一集。额度用尽时下一集大概率也失败，
                // 由调用方决定要不要继续入队。
                AppLog.net("prefetch ${job.episodeId} failed: ${t.message}")
            }
        }
    }

    // ───────────────────────── 下载 + 解密 ─────────────────────────

    private suspend fun produce(
        episodeId: String,
        stream: StreamInfo,
        key: ByteArray,
        dest: File,
        onStage: (Stage) -> Unit,
    ): File {
        val temp = download(stream.url, onStage)
        try {
            val size = temp.length()
            if (size > sizeLimit) throw Failure("加密流体积异常（$size 字节），已放弃解密")

            onStage(Stage.Decrypting(0.02f))
            val payload = withContext(Dispatchers.IO) { temp.readBytes() }
            val outcome = withContext(Dispatchers.Default) {
                CENCDecryptor.decrypt(payload, key) { fraction ->
                    onStage(Stage.Decrypting((0.02f + fraction * 0.96f).coerceAtMost(0.98f)))
                }
            }

            withContext(Dispatchers.IO) {
                dest.parentFile?.mkdirs()
                val tmp = File(dest.parentFile, dest.name + ".tmp")
                tmp.writeBytes(outcome.data)
                if (!tmp.renameTo(dest)) {
                    dest.delete()
                    if (!tmp.renameTo(dest)) {
                        tmp.delete()
                        throw Failure("写入缓存失败")
                    }
                }
            }
            AppLog.net("cenc decrypted episode=$episodeId samples=${outcome.sampleCount} bytes=${outcome.data.size}")
            withContext(Dispatchers.IO) { trimCache() }
            return dest
        } finally {
            temp.delete()
        }
    }

    private suspend fun download(url: String, onStage: (Stage) -> Unit): File = withContext(Dispatchers.IO) {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("Accept", "*/*")
        }
        var temp: File? = null
        // 取消时立刻断开连接，否则读阻塞要等 readTimeout 才返回。
        val cancelHook = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
            if (cause is CancellationException) runCatching { conn.disconnect() }
        }
        try {
            val file = File.createTempFile("hg-cenc-", ".mp4", root)
            temp = file
            val code = conn.responseCode
            if (code !in 200..299) throw Failure("下载加密流失败（HTTP $code）")

            val total = conn.contentLengthLong.coerceAtLeast(-1L)
            var read = 0L
            var lastReported = -1f
            conn.inputStream.use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        read += n
                        if (read > sizeLimit) throw Failure("加密流体积异常，已放弃解密")
                        if (total > 0) {
                            val f = (read.toFloat() / total).coerceIn(0f, 1f)
                            if (f - lastReported >= 0.01f || f >= 1f) {
                                lastReported = f
                                onStage(Stage.Downloading(f))
                            }
                        } else if (read % (4L * 1024 * 1024) < n.toLong()) {
                            onStage(Stage.Downloading(-1f))
                        }
                    }
                }
            }
            file
        } catch (t: Throwable) {
            temp?.delete()
            if (t is IOException) throw Failure("下载加密流失败：${t.message}")
            throw t
        } finally {
            cancelHook?.dispose()
            conn.disconnect()
        }
    }

    /** 缓存上限（默认 1.5GB），按最后修改时间删最旧的。 */
    private fun trimCache() {
        val files = root.listFiles() ?: return
        var total = files.sumOf { it.length() }
        if (total <= cacheLimit) return
        for (f in files.sortedBy { it.lastModified() }) {
            val size = f.length()
            if (f.delete()) total -= size
            if (total <= cacheLimit) break
        }
    }

    companion object {
        private const val MAX_QUEUE = 4
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 15_000
    }
}

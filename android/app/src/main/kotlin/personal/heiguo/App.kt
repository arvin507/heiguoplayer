package personal.heiguo

import android.app.Application
import personal.heiguo.data.LibraryDatabase
import personal.heiguo.data.LibraryStore
import personal.heiguo.domain.*
import personal.heiguo.media.ProtectedMediaStore
import personal.heiguo.repo.CatalogRepository
import personal.heiguo.repo.PlaybackRepository
import personal.heiguo.service.HongguoService
import personal.heiguo.service.LiveHongguoService
import java.io.File

/** 依赖容器：一个 Service、两个 Repository、一个本机资料库、一个加密分集缓存。由 Application 创建。 */
class AppEnv(
    val service: HongguoService,
    val library: LibraryStore,
    val startupError: AppError? = null,
    /** 加密分集的下载 → 解密 → 本地缓存。 */
    val protectedMedia: ProtectedMediaStore = ProtectedMediaStore(
        File(System.getProperty("java.io.tmpdir") ?: ".", "hongguo-cenc"),
    ),
) {
    val catalog = CatalogRepository(service)
    val playback = PlaybackRepository(service)

    /** 用户选的清晰度（高度，0 表示没选过，用默认规则）。记在本机，下次启动仍然有效。 */
    var preferredHeight: Int
        get() = prefs?.getInt("preferredHeight", 0) ?: memoryHeight
        set(v) { memoryHeight = v; prefs?.edit()?.putInt("preferredHeight", v)?.apply() }
    private var memoryHeight = 0
    var prefs: android.content.SharedPreferences? = null
}

class HeiguoApp : Application() {
    lateinit var env: AppEnv
        private set

    override fun onCreate() {
        super.onCreate()
        val library = LibraryStore(LibraryDatabase.create(this).dao())
        // 解密后的 mp4 放 cacheDir：系统空间紧张时可以随时清掉，正好符合“缓存”的语义。
        val media = ProtectedMediaStore(File(cacheDir, "hongguo-cenc"))
        val prefs = getSharedPreferences("player", MODE_PRIVATE)
        env = try {
            // 设备档案放在 noBackupFilesDir：不参与云备份和换机迁移。
            AppEnv(LiveHongguoService(File(noBackupFilesDir, "openhongguo/anonymous.json")), library, null, media)
        } catch (t: Throwable) {
            val e = AppError.from(t) ?: AppError(AppError.Code.UNKNOWN)
            AppEnv(FailingService(e), library, e, media)
        }
        env.prefs = prefs
    }
}

/** SDK 无法初始化时的占位：所有调用都抛出同一个错误，界面显示错误态而不是崩溃。 */
class FailingService(private val error: AppError) : HongguoService {
    override suspend fun discover(cursor: String?): PageResult<SeriesItem> = throw error
    override suspend fun search(query: String, cursor: String?): PageResult<SeriesItem> = throw error
    override suspend fun suggest(prefix: String): List<SearchSuggestion> = throw error
    override suspend fun hotSearch(): HotSearchInfo = throw error
    override suspend fun searchCues(): List<String> = throw error
    override suspend fun series(seriesId: String): SeriesInfo = throw error
    override suspend fun seriesBatch(seriesIds: List<String>): List<SeriesInfo> = throw error
    override suspend fun episodes(seriesId: String, cursor: String?): PageResult<EpisodeItem> = throw error
    override suspend fun filterPanel(): List<FilterRowInfo> = throw error
    override suspend fun filter(selections: Map<String, List<String>>, cursor: String?): PageResult<SeriesItem> = throw error
    override suspend fun rank(content: String?, board: String?, cursor: String?): RankPageInfo = throw error
    override suspend fun newReleases(date: String?, cursor: String?): NewReleaseDayInfo = throw error
    override suspend fun resolvePlayback(episodeId: String): PlaybackInfo = throw error
    override suspend fun resetDevice() = throw error
}

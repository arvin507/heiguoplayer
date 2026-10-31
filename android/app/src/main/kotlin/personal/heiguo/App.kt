package personal.heiguo

import android.app.Application
import personal.heiguo.data.LibraryDatabase
import personal.heiguo.data.LibraryStore
import personal.heiguo.domain.*
import personal.heiguo.repo.CatalogRepository
import personal.heiguo.repo.PlaybackRepository
import personal.heiguo.service.HongguoService
import personal.heiguo.service.LiveHongguoService
import java.io.File

/** 依赖容器：一个 Service、两个 Repository、一个本机资料库。由 Application 创建。 */
class AppEnv(
    val service: HongguoService,
    val library: LibraryStore,
    val startupError: AppError? = null,
) {
    val catalog = CatalogRepository(service)
    val playback = PlaybackRepository(service)
}

class HeiguoApp : Application() {
    lateinit var env: AppEnv
        private set

    override fun onCreate() {
        super.onCreate()
        val library = LibraryStore(LibraryDatabase.create(this).dao())
        env = try {
            // 设备档案放在 noBackupFilesDir：不参与云备份和换机迁移。
            AppEnv(LiveHongguoService(File(noBackupFilesDir, "openhongguo/anonymous.json")), library)
        } catch (t: Throwable) {
            val e = AppError.from(t) ?: AppError(AppError.Code.UNKNOWN)
            AppEnv(FailingService(e), library, e)
        }
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

package personal.heiguo.data

import android.content.Context
import androidx.room.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import personal.heiguo.domain.EpisodeItem
import personal.heiguo.domain.SeriesInfo
import personal.heiguo.domain.SeriesStatusKind
import personal.heiguo.support.AppLog
import personal.heiguo.domain.AppError

/** 每集一条观看记录。剧名和封面冗余存一份，历史页不用联网也能显示。 */
@Entity(tableName = "watch_record", indices = [Index("seriesId")])
data class WatchRecord(
    /** "seriesId#episodeNumber" */
    @PrimaryKey val key: String,
    val seriesId: String,
    val episodeId: String,
    val episodeNumber: Int,
    val progressSeconds: Double,
    val durationSeconds: Double,
    val updatedAt: Long,
    val seriesTitle: String,
    val coverUrl: String?,
) {
    /** 看到末尾 10 秒以内（或 95%）算看完。 */
    val isFinished: Boolean
        get() = durationSeconds > 0 && (progressSeconds >= durationSeconds - 10 || progressSeconds / durationSeconds >= 0.95)

    companion object {
        fun key(seriesId: String, number: Int) = "$seriesId#$number"
    }
}

@Entity(tableName = "favorite")
data class Favorite(
    @PrimaryKey val seriesId: String,
    val title: String,
    val coverUrl: String?,
    val episodeCount: Int,
    val createdAt: Long,
)

/** 追更：knownEpisodeCount 是用户上次看到的最新集数，latestEpisodeCount 是最近一次检查得到的集数。 */
@Entity(tableName = "followed_series")
data class FollowedSeries(
    @PrimaryKey val seriesId: String,
    val title: String,
    val coverUrl: String?,
    val knownEpisodeCount: Int,
    val latestEpisodeCount: Int,
    val isFinished: Boolean,
    val followedAt: Long,
    val lastCheckedAt: Long?,
) {
    val hasUpdate: Boolean get() = latestEpisodeCount > knownEpisodeCount
    val newEpisodeCount: Int get() = maxOf(0, latestEpisodeCount - knownEpisodeCount)
}

/** 已知是加密的分集。播放时才能知道是否加密（会消耗一次播放额度），所以记下来，以后分集网格直接标“加密”。 */
@Entity(tableName = "encrypted_episode", indices = [Index("seriesId")])
data class EncryptedEpisode(@PrimaryKey val episodeId: String, val seriesId: String, val detectedAt: Long)

/** 推荐流的位置（只存一条）。 */
@Entity(tableName = "feed_position")
data class FeedPosition(@PrimaryKey val slot: String = "feed", val seriesId: String, val updatedAt: Long)

@Dao
interface LibraryDao {
    @Query("SELECT * FROM watch_record WHERE `key` = :key") suspend fun record(key: String): WatchRecord?
    @Query("SELECT * FROM watch_record WHERE seriesId = :id") suspend fun records(id: String): List<WatchRecord>
    @Query("SELECT * FROM watch_record WHERE seriesId = :id ORDER BY updatedAt DESC LIMIT 1") suspend fun lastWatched(id: String): WatchRecord?
    @Upsert suspend fun upsert(r: WatchRecord)
    @Query("SELECT * FROM watch_record ORDER BY updatedAt DESC LIMIT 2000") suspend fun recentRecords(): List<WatchRecord>
    @Query("DELETE FROM watch_record WHERE seriesId = :id") suspend fun deleteHistory(id: String)
    @Query("DELETE FROM watch_record") suspend fun clearHistory()

    @Query("SELECT COUNT(*) FROM favorite WHERE seriesId = :id") suspend fun favoriteCount(id: String): Int
    @Upsert suspend fun upsert(f: Favorite)
    @Query("DELETE FROM favorite WHERE seriesId = :id") suspend fun deleteFavorite(id: String)
    @Query("SELECT * FROM favorite ORDER BY createdAt DESC") suspend fun favorites(): List<Favorite>

    @Query("SELECT * FROM followed_series WHERE seriesId = :id") suspend fun followed(id: String): FollowedSeries?
    @Upsert suspend fun upsert(f: FollowedSeries)
    @Query("DELETE FROM followed_series WHERE seriesId = :id") suspend fun deleteFollow(id: String)
    @Query("SELECT * FROM followed_series") suspend fun allFollowed(): List<FollowedSeries>

    @Query("SELECT episodeId FROM encrypted_episode WHERE seriesId = :id") suspend fun encryptedIds(id: String): List<String>
    @Query("SELECT COUNT(*) FROM encrypted_episode WHERE episodeId = :id") suspend fun encryptedCount(id: String): Int
    @Query("SELECT COUNT(*) FROM encrypted_episode WHERE seriesId = :id") suspend fun encryptedSeriesCount(id: String): Int
    @Upsert suspend fun upsert(e: EncryptedEpisode)

    @Query("SELECT * FROM feed_position WHERE slot = 'feed'") suspend fun feedPosition(): FeedPosition?
    @Upsert suspend fun upsert(p: FeedPosition)
}

@Database(
    entities = [WatchRecord::class, Favorite::class, FollowedSeries::class, EncryptedEpisode::class, FeedPosition::class],
    version = 1,
    exportSchema = true,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): LibraryDao

    companion object {
        fun create(context: Context, inMemory: Boolean = false): LibraryDatabase =
            if (inMemory) Room.inMemoryDatabaseBuilder(context, LibraryDatabase::class.java).build()
            else Room.databaseBuilder(context, LibraryDatabase::class.java, "library.db").build()
    }
}

/** 本机资料库（历史、收藏、追更、加密标记、推荐流位置）。所有数据只存本机。 */
class LibraryStore(private val dao: LibraryDao, private val now: () -> Long = { System.currentTimeMillis() }) {
    private val _revision = MutableStateFlow(0)
    /** 每次写入后递增，供页面观察变化。 */
    val revision: StateFlow<Int> = _revision

    private fun bump() { _revision.value++ }

    // 观看记录
    suspend fun record(seriesId: String, number: Int) = dao.record(WatchRecord.key(seriesId, number))
    suspend fun records(seriesId: String): Map<Int, WatchRecord> = dao.records(seriesId).associateBy { it.episodeNumber }
    suspend fun lastWatched(seriesId: String) = dao.lastWatched(seriesId)

    suspend fun saveProgress(seriesId: String, seriesTitle: String, coverUrl: String?, episode: EpisodeItem, seconds: Double, duration: Double) {
        if (!seconds.isFinite() || seconds < 0) return
        val old = record(seriesId, episode.number)
        dao.upsert(
            WatchRecord(
                key = WatchRecord.key(seriesId, episode.number), seriesId = seriesId, episodeId = episode.id,
                episodeNumber = episode.number, progressSeconds = seconds,
                durationSeconds = if (duration.isFinite() && duration > 0) duration else old?.durationSeconds ?: 0.0,
                updatedAt = now(), seriesTitle = seriesTitle.ifEmpty { old?.seriesTitle ?: "" },
                coverUrl = coverUrl ?: old?.coverUrl,
            ),
        )
        bump()
    }

    /** 历史：每部剧取最近一条。 */
    suspend fun history(limit: Int = 200): List<WatchRecord> {
        val seen = HashSet<String>()
        return dao.recentRecords().filter { seen.add(it.seriesId) }.take(limit)
    }

    suspend fun deleteHistory(seriesId: String) { dao.deleteHistory(seriesId); bump() }
    suspend fun clearHistory() { dao.clearHistory(); bump() }

    // 收藏
    suspend fun isFavorite(seriesId: String) = dao.favoriteCount(seriesId) > 0
    suspend fun toggleFavorite(s: SeriesInfo) {
        if (isFavorite(s.id)) dao.deleteFavorite(s.id) else dao.upsert(Favorite(s.id, s.title, s.coverUrl, s.episodeCount, now()))
        bump()
    }
    suspend fun favorites() = dao.favorites()

    // 追更
    suspend fun followed(seriesId: String) = dao.followed(seriesId)
    suspend fun toggleFollow(s: SeriesInfo) {
        if (followed(s.id) != null) dao.deleteFollow(s.id)
        else dao.upsert(FollowedSeries(s.id, s.title, s.coverUrl, s.episodeCount, s.episodeCount, s.status == SeriesStatusKind.FINISHED, now(), null))
        bump()
    }

    suspend fun followedSeries(): List<FollowedSeries> =
        dao.allFollowed().sortedWith(compareByDescending<FollowedSeries> { it.hasUpdate }.thenByDescending { it.followedAt })

    /** 用最新详情更新追更记录。集数变少（服务端异常）时不覆盖。 */
    suspend fun applyLatest(infos: List<SeriesInfo>) {
        val byId = infos.associateBy { it.id }
        for (f in dao.allFollowed()) {
            val s = byId[f.seriesId] ?: continue
            dao.upsert(
                f.copy(
                    latestEpisodeCount = maxOf(f.latestEpisodeCount, s.episodeCount),
                    isFinished = s.status == SeriesStatusKind.FINISHED,
                    title = s.title.ifEmpty { f.title }, coverUrl = s.coverUrl ?: f.coverUrl, lastCheckedAt = now(),
                ),
            )
        }
        bump()
    }

    /** 用户看过详情后，清除“有新集”标记。 */
    suspend fun acknowledgeUpdate(s: SeriesInfo) {
        val f = followed(s.id) ?: return
        val latest = maxOf(f.latestEpisodeCount, s.episodeCount)
        dao.upsert(f.copy(latestEpisodeCount = latest, knownEpisodeCount = latest))
        bump()
    }

    // 加密标记
    suspend fun encryptedEpisodeIds(seriesId: String): Set<String> = dao.encryptedIds(seriesId).toSet()
    suspend fun seriesHasEncrypted(seriesId: String) = dao.encryptedSeriesCount(seriesId) > 0
    suspend fun markEncrypted(episodeId: String, seriesId: String) {
        if (dao.encryptedCount(episodeId) > 0) return
        dao.upsert(EncryptedEpisode(episodeId, seriesId, now()))
        bump()
    }

    // 推荐流位置
    suspend fun feedSeriesId(): String? = dao.feedPosition()?.seriesId
    suspend fun setFeedPosition(seriesId: String) {
        if (dao.feedPosition()?.seriesId == seriesId) return
        dao.upsert(FeedPosition(seriesId = seriesId, updatedAt = now()))
    }

    /** 写库失败只记日志，不让界面崩溃。 */
    suspend inline fun safely(context: String, block: () -> Unit) {
        try { block() } catch (e: kotlin.coroutines.cancellation.CancellationException) { throw e } catch (t: Throwable) {
            AppLog.error(AppError(AppError.Code.UNKNOWN, t.toString()), context)
        }
    }
}

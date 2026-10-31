import Foundation
import SwiftData

/// 本机资料库（历史、收藏、追更、加密标记、推荐流位置）。主线程使用，SwiftData 的 mainContext。
@MainActor
@Observable
public final class LibraryStore {
    /// ModelContext 不强持有 ModelContainer，所以这里一起持有，避免容器被提前释放。
    public let container: ModelContainer
    public let context: ModelContext
    /// 每次写入后递增，供不使用 @Query 的 ViewModel 观察变化。
    public private(set) var revision = 0

    public init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    private func save() {
        do { try context.save() } catch { AppLog.error(AppError(.unknown, debugMessage: "\(error)"), context: "SwiftData save") }
        revision += 1
    }

    // MARK: 观看记录

    public func record(_ seriesId: String, number: Int) -> WatchRecord? {
        let key = WatchRecord.key(seriesId, number)
        var d = FetchDescriptor<WatchRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func records(for seriesId: String) -> [Int: WatchRecord] {
        let d = FetchDescriptor<WatchRecord>(predicate: #Predicate { $0.seriesId == seriesId })
        let all = (try? context.fetch(d)) ?? []
        return Dictionary(all.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
    }

    /// 这部剧最近看的一集（断点续播入口）。
    public func lastWatched(_ seriesId: String) -> WatchRecord? {
        var d = FetchDescriptor<WatchRecord>(predicate: #Predicate { $0.seriesId == seriesId },
                                             sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func saveProgress(seriesId: String, seriesTitle: String, coverURL: URL?, episode: EpisodeItem,
                             seconds: Double, duration: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if let r = record(seriesId, number: episode.number) {
            r.progressSeconds = seconds
            if duration.isFinite, duration > 0 { r.durationSeconds = duration }
            r.episodeId = episode.id
            r.updatedAt = .now
            if !seriesTitle.isEmpty { r.seriesTitle = seriesTitle }
            if let coverURL { r.coverURLString = coverURL.absoluteString }
        } else {
            context.insert(WatchRecord(seriesId: seriesId, episodeId: episode.id, episodeNumber: episode.number,
                                       progressSeconds: seconds, durationSeconds: duration.isFinite ? duration : 0,
                                       seriesTitle: seriesTitle, coverURL: coverURL))
        }
        save()
    }

    /// 历史：每部剧取最近一条。
    public func history(limit: Int = 200) -> [WatchRecord] {
        var d = FetchDescriptor<WatchRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 2000
        var seen = Set<String>()
        return ((try? context.fetch(d)) ?? []).filter { seen.insert($0.seriesId).inserted }.prefix(limit).map { $0 }
    }

    public func deleteHistory(seriesId: String) {
        try? context.delete(model: WatchRecord.self, where: #Predicate { $0.seriesId == seriesId })
        save()
    }

    public func clearHistory() {
        try? context.delete(model: WatchRecord.self)
        save()
    }

    // MARK: 收藏

    public func isFavorite(_ seriesId: String) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Favorite>(predicate: #Predicate { $0.seriesId == seriesId }))) ?? 0) > 0
    }

    public func toggleFavorite(_ s: SeriesInfo) {
        let id = s.id
        if isFavorite(id) {
            try? context.delete(model: Favorite.self, where: #Predicate { $0.seriesId == id })
        } else {
            context.insert(Favorite(seriesId: s.id, title: s.title, coverURL: s.coverURL, episodeCount: s.episodeCount))
        }
        save()
    }

    public func favorites() -> [Favorite] {
        (try? context.fetch(FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    // MARK: 追更

    public func followed(_ seriesId: String) -> FollowedSeries? {
        var d = FetchDescriptor<FollowedSeries>(predicate: #Predicate { $0.seriesId == seriesId })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    public func toggleFollow(_ s: SeriesInfo) {
        if let f = followed(s.id) {
            context.delete(f)
        } else {
            context.insert(FollowedSeries(seriesId: s.id, title: s.title, coverURL: s.coverURL,
                                          episodeCount: s.episodeCount, isFinished: s.status == .finished))
        }
        save()
    }

    public func followedSeries() -> [FollowedSeries] {
        let all = (try? context.fetch(FetchDescriptor<FollowedSeries>(sortBy: [SortDescriptor(\.followedAt, order: .reverse)]))) ?? []
        return all.sorted { ($0.hasUpdate ? 1 : 0, $0.followedAt) > ($1.hasUpdate ? 1 : 0, $1.followedAt) }
    }

    public var updatedFollowCount: Int { followedSeries().filter(\.hasUpdate).count }

    /// 用最新详情更新追更记录。集数变少（服务端异常）时不覆盖。
    public func applyLatest(_ infos: [SeriesInfo]) {
        let byId = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for f in followedSeries() {
            guard let s = byId[f.seriesId] else { continue }
            if s.episodeCount > f.latestEpisodeCount { f.latestEpisodeCount = s.episodeCount }
            f.isFinished = s.status == .finished
            if !s.title.isEmpty { f.title = s.title }
            if let c = s.coverURL { f.coverURLString = c.absoluteString }
            f.lastCheckedAt = .now
        }
        save()
    }

    /// 用户看过详情后，清除“有新集”标记。
    public func acknowledgeUpdate(_ s: SeriesInfo) {
        guard let f = followed(s.id) else { return }
        f.latestEpisodeCount = max(f.latestEpisodeCount, s.episodeCount)
        f.knownEpisodeCount = f.latestEpisodeCount
        save()
    }

    // MARK: 加密标记

    public func encryptedEpisodeIds(_ seriesId: String) -> Set<String> {
        let d = FetchDescriptor<EncryptedEpisode>(predicate: #Predicate { $0.seriesId == seriesId })
        return Set(((try? context.fetch(d)) ?? []).map(\.episodeId))
    }

    public func isEncrypted(_ episodeId: String) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<EncryptedEpisode>(predicate: #Predicate { $0.episodeId == episodeId }))) ?? 0) > 0
    }

    /// 这部剧是否已知有加密分集（同一部剧的分集通常一起加密）。
    public func seriesHasEncrypted(_ seriesId: String) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<EncryptedEpisode>(predicate: #Predicate { $0.seriesId == seriesId }))) ?? 0) > 0
    }

    public func markEncrypted(_ episodeId: String, seriesId: String) {
        guard !isEncrypted(episodeId) else { return }
        context.insert(EncryptedEpisode(episodeId: episodeId, seriesId: seriesId))
        save()
    }

    // MARK: 推荐流位置

    public var feedSeriesId: String? {
        try? context.fetch(FetchDescriptor<FeedPosition>()).first?.seriesId
    }

    public func setFeedPosition(_ seriesId: String) {
        if let p = try? context.fetch(FetchDescriptor<FeedPosition>()).first {
            guard p.seriesId != seriesId else { return }
            p.seriesId = seriesId
            p.updatedAt = .now
        } else {
            context.insert(FeedPosition(seriesId: seriesId))
        }
        save()
    }
}

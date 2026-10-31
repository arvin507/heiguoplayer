import Foundation

/// 详情页：封面、简介、集数网格（含观看状态）、收藏、追更。
@MainActor
@Observable
public final class SeriesDetailViewModel {
    public enum EpisodeStatus: Equatable {
        case unwatched
        case inProgress(Double) // 0...1
        case finished
        case encrypted
        case unplayable
    }

    public let seriesId: String
    public private(set) var series: SeriesInfo?
    public private(set) var state: LoadState = .idle
    public private(set) var episodes: [EpisodeItem] = []
    public private(set) var episodesState: LoadState = .idle
    public private(set) var isFavorite = false
    public private(set) var isFollowed = false
    private var records: [Int: WatchRecord] = [:]
    private var encrypted: Set<String> = []

    private let env: AppEnvironment

    public init(seriesId: String, env: AppEnvironment, preview: SeriesItem? = nil) {
        self.seriesId = seriesId
        self.env = env
        if let preview {
            // 先用列表里带过来的信息占位，详情回来后替换
            series = SeriesInfo(id: preview.id, title: preview.title, summary: preview.summary,
                                coverURL: preview.coverURL, episodeCount: preview.episodeCount)
        }
    }

    public func load(force: Bool = false) async {
        refreshLocal()
        if state == .loaded, !force { return }
        state = .loading
        episodesState = .loading
        async let info = env.catalog.series(seriesId, forceRefresh: force)
        async let eps = env.catalog.episodes(seriesId, forceRefresh: force)
        do {
            let s = try await info
            series = s
            state = .loaded
            env.library.acknowledgeUpdate(s)
        } catch {
            guard let e = AppError.from(error) else { return }
            state = .failed(e)
        }
        do {
            episodes = try await eps
            episodesState = episodes.isEmpty ? .empty : .loaded
        } catch {
            guard let e = AppError.from(error) else { return }
            episodesState = .failed(e)
        }
        refreshLocal()
    }

    /// 从本机资料库刷新观看状态、收藏、追更（从播放页返回时调用）。
    public func refreshLocal() {
        records = env.library.records(for: seriesId)
        encrypted = env.library.encryptedEpisodeIds(seriesId)
        isFavorite = env.library.isFavorite(seriesId)
        isFollowed = env.library.followed(seriesId) != nil
    }

    public func status(of ep: EpisodeItem) -> EpisodeStatus {
        if !ep.playable { return .unplayable }
        if encrypted.contains(ep.id) { return .encrypted }
        guard let r = records[ep.number] else { return .unwatched }
        if r.isFinished { return .finished }
        guard r.durationSeconds > 0 else { return r.progressSeconds > 0 ? .inProgress(0.05) : .unwatched }
        return .inProgress(min(1, max(0.02, r.progressSeconds / r.durationSeconds)))
    }

    /// “继续观看”的那一集：最近看的一集；看完了就下一集；没看过就第一集。
    public var resumeTarget: (episode: EpisodeItem, seconds: Double)? {
        guard !episodes.isEmpty else { return nil }
        guard let last = env.library.lastWatched(seriesId),
              let idx = episodes.firstIndex(where: { $0.number == last.episodeNumber }) else {
            return (episodes[0], 0)
        }
        if last.isFinished, idx + 1 < episodes.count { return (episodes[idx + 1], 0) }
        return (episodes[idx], last.isFinished ? 0 : last.progressSeconds)
    }

    public var resumeLabel: String {
        guard let t = resumeTarget else { return "播放" }
        if env.library.lastWatched(seriesId) == nil { return "从第 1 集开始" }
        return t.seconds > 0 ? "继续看第 \(t.episode.number) 集" : "看第 \(t.episode.number) 集"
    }

    public func toggleFavorite() {
        guard let series else { return }
        env.library.toggleFavorite(series)
        refreshLocal()
    }

    public func toggleFollow() {
        guard let series else { return }
        env.library.toggleFollow(series)
        refreshLocal()
    }
}

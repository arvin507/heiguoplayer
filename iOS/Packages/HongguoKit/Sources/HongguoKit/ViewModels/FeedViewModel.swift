import Foundation

/// 推荐流：竖屏一屏一部剧，上下滑动切换。
/// - 停留 dwell 秒后才为当前这部剧请求播放模型（快速划过的不请求，节约设备额度）；
/// - 只预取前后几部剧的元数据（分集列表），绝不预取播放模型；
/// - 记住上次停在哪部剧，下次打开回到那里，并从那部剧的观看记录续播。
@MainActor
@Observable
public final class FeedViewModel {
    public let feed: Paginator<SeriesItem>
    public private(set) var focusedId: String?
    /// 当前正在播放的那一部（停留够久之后才创建）。
    public private(set) var player: PlayerViewModel?
    public private(set) var preparingId: String?
    public private(set) var prepareError: AppError?

    private let env: AppEnvironment
    private var dwellTask: Task<Void, Never>?
    public var dwell: TimeInterval = 0.6
    private var restoredId: String?
    /// 连续拿不到内容密钥的次数；达到阈值后暂停自动播放，改为点击播放。
    private var consecutiveKeyMissing = 0
    static let keyMissingStreakLimit = 3
    public private(set) var autoplayPaused = false

    public init(env: AppEnvironment) {
        self.env = env
        let catalog = env.catalog
        let library = env.library
        self.feed = Paginator { cursor in
            var page = try await catalog.discover(cursor: cursor)
            // 首页：把上次停留的剧放到最前面，回到上次的位置
            if cursor == nil, let last = await library.feedSeriesId, !page.items.contains(where: { $0.id == last }),
               let info = try? await catalog.series(last) {
                page.items.insert(SeriesItem(id: info.id, title: info.title, summary: info.summary,
                                             coverURL: info.coverURL, episodeCount: info.episodeCount), at: 0)
            }
            return page
        }
    }

    public func load() async {
        restoredId = env.library.feedSeriesId
        await feed.loadIfNeeded()
    }

    /// 首屏应当停在哪一部。
    public var initialId: String? {
        if let r = restoredId, feed.items.contains(where: { $0.id == r }) { return r }
        return feed.items.first?.id
    }

    /// 滚动停到某一部剧时调用。
    public func focus(_ id: String?) {
        guard id != focusedId else { return }
        focusedId = id
        dwellTask?.cancel()
        player?.stop()
        player = nil
        prepareError = nil
        preparingId = nil
        guard let id, let idx = feed.items.firstIndex(where: { $0.id == id }) else { return }
        env.library.setFeedPosition(id)
        feed.onItemAppear(feed.items[idx])

        // 元数据预取：当前和后两部
        for item in feed.items[idx..<min(idx + 3, feed.items.count)] {
            Task { await env.catalog.prefetchMetadata(item.id) }
        }

        let item = feed.items[idx]
        // 自动播放已暂停（连续几部都拿不到内容密钥）：不请求，等用户点击。
        if autoplayPaused { return }
        let delay = dwell
        dwellTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.focusedId == id else { return }
            await self.preparePlayer(for: item)
        }
    }

    private func preparePlayer(for item: SeriesItem) async {
        preparingId = item.id
        defer { if preparingId == item.id { preparingId = nil } }
        do {
            let eps = try await env.catalog.episodes(item.id)
            guard !Task.isCancelled, focusedId == item.id else { return }
            guard !eps.isEmpty else {
                prepareError = AppError(.contentUnavailable, debugMessage: "no episodes")
                return
            }
            var startIndex = 0
            var startAt = 0.0
            if let last = env.library.lastWatched(item.id), let i = eps.firstIndex(where: { $0.number == last.episodeNumber }) {
                if last.isFinished, i + 1 < eps.count { startIndex = i + 1 } else {
                    startIndex = i
                    startAt = last.isFinished ? 0 : max(0, last.progressSeconds - 2)
                }
            }
            let p = PlayerViewModel(seriesId: item.id, seriesTitle: item.title, coverURL: item.coverURL, episodes: eps,
                                    startIndex: startIndex, startAt: startAt, env: env)
            player = p
            p.start()
        } catch {
            guard focusedId == item.id, let e = AppError.from(error) else { return }
            prepareError = e
        }
    }

    /// 用户点击“播放”（自动播放暂停时）。
    public func playFocused() {
        guard let id = focusedId, let item = feed.items.first(where: { $0.id == id }) else { return }
        Task { await preparePlayer(for: item) }
    }

    /// 播放器报告了「拿不到密钥 / 正常播放」，用来统计连续失败次数。
    public func noteResult(keyMissing: Bool) {
        if keyMissing {
            consecutiveKeyMissing += 1
            if consecutiveKeyMissing >= Self.keyMissingStreakLimit { autoplayPaused = true }
        } else {
            consecutiveKeyMissing = 0
            autoplayPaused = false
        }
    }

    public func resumeAutoplay() {
        consecutiveKeyMissing = 0
        autoplayPaused = false
        retry()
    }

    public func retry() {
        let id = focusedId
        focusedId = nil
        focus(id)
    }

    /// 离开推荐页（切 Tab、进入详情）：停止播放、取消未完成的请求。
    public func pause() {
        dwellTask?.cancel()
        player?.stop()
    }

    /// 回到推荐页。
    public func resume() {
        retry()
    }
}

import Foundation

/// 元数据仓库：详情、分集、列表、榜单等。带内存缓存（TTL）和并发去重。
///
/// ANONYMOUS_LIMITED 在这里一律当作“结果为空”处理（SDK 文档：列表为空时也报这个错误），
/// 只有 PlaybackRepository 才把它当作“被限制”。
public actor CatalogRepository {
    private let service: HongguoService
    private let now: @Sendable () -> Date
    private let detailTTL: TimeInterval
    private let listTTL: TimeInterval

    private var seriesCache: [String: (SeriesInfo, Date)] = [:]
    private var episodesCache: [String: ([EpisodeItem], Date)] = [:]
    private var hotSearchCache: (HotSearchInfo, Date)?
    private var filterPanelCache: ([FilterRowInfo], Date)?

    private let seriesCoalescer = TaskCoalescer<String, SeriesInfo>()
    private let episodesCoalescer = TaskCoalescer<String, [EpisodeItem]>()
    private let hotCoalescer = TaskCoalescer<String, HotSearchInfo>()
    private let panelCoalescer = TaskCoalescer<String, [FilterRowInfo]>()

    /// 分集列表最多翻多少页，防止服务端异常时死循环。
    static let maxEpisodePages = 30

    public init(service: HongguoService, detailTTL: TimeInterval = 600, listTTL: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.detailTTL = detailTTL
        self.listTTL = listTTL
        self.now = now
    }

    // MARK: 详情与分集

    public func series(_ id: String, forceRefresh: Bool = false) async throws -> SeriesInfo {
        if !forceRefresh, let (v, t) = seriesCache[id], now().timeIntervalSince(t) < detailTTL { return v }
        let service = self.service
        let v = try await seriesCoalescer.value(for: id) { _ in try await service.series(id) }
        seriesCache[id] = (v, now())
        return v
    }

    /// 全部分集（自动翻页，按分集 ID 去重，按集号排序）。
    public func episodes(_ seriesId: String, forceRefresh: Bool = false) async throws -> [EpisodeItem] {
        if !forceRefresh, let (v, t) = episodesCache[seriesId], now().timeIntervalSince(t) < detailTTL { return v }
        let service = self.service
        let v = try await episodesCoalescer.value(for: seriesId) { _ in
            var seen = Set<String>()
            var all: [EpisodeItem] = []
            var cursor: String?
            for _ in 0..<Self.maxEpisodePages {
                let page = try await emptyOnLimited { try await service.episodes(seriesId, cursor: cursor) }
                for e in page.items where seen.insert(e.id).inserted { all.append(e) }
                guard page.hasMore, let next = page.cursor, next != cursor else { break }
                cursor = next
            }
            return all.sorted { $0.number < $1.number }
        }
        episodesCache[seriesId] = (v, now())
        return v
    }

    /// 只预取元数据（详情 + 分集），绝不请求播放模型。失败静默。
    public func prefetchMetadata(_ seriesId: String) {
        Task {
            _ = try? await self.series(seriesId)
            _ = try? await self.episodes(seriesId)
        }
    }

    /// 已缓存的分集（不发请求）。
    public func cachedEpisodes(_ seriesId: String) -> [EpisodeItem]? { episodesCache[seriesId]?.0 }

    /// 批量读取详情，用于追更检查。每批 20 部；失败的批次跳过。
    public func seriesBatch(_ ids: [String]) async -> [SeriesInfo] {
        var out: [SeriesInfo] = []
        for chunk in stride(from: 0, to: ids.count, by: 20).map({ Array(ids[$0..<min($0 + 20, ids.count)]) }) {
            if Task.isCancelled { break }
            if let r = try? await service.seriesBatch(chunk) {
                for s in r { seriesCache[s.id] = (s, now()) }
                out += r
            }
        }
        return out
    }

    // MARK: 列表

    public func discover(cursor: String?) async throws -> PageResult<SeriesItem> {
        try await emptyOnLimited { try await self.service.discover(cursor: cursor) }
    }

    public func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem> {
        try await emptyOnLimited { try await self.service.search(query, cursor: cursor) }
    }

    public func suggest(_ prefix: String) async throws -> [SearchSuggestion] {
        try await emptyArrayOnLimited { try await self.service.suggest(prefix) }
    }

    public func searchCues() async throws -> [String] {
        try await emptyArrayOnLimited { try await self.service.searchCues() }
    }

    public func hotSearch() async throws -> HotSearchInfo {
        if let (v, t) = hotSearchCache, now().timeIntervalSince(t) < listTTL { return v }
        let service = self.service
        let v = try await hotCoalescer.value(for: "hot") { _ in
            do { return try await service.hotSearch() } catch let e as AppError where e.code == .anonymousLimited { return HotSearchInfo() }
        }
        hotSearchCache = (v, now())
        return v
    }

    public func filterPanel() async throws -> [FilterRowInfo] {
        if let (v, t) = filterPanelCache, now().timeIntervalSince(t) < detailTTL { return v }
        let service = self.service
        let v = try await panelCoalescer.value(for: "panel") { _ in
            try await emptyArrayOnLimited { try await service.filterPanel() }
        }
        filterPanelCache = (v, now())
        return v
    }

    public func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem> {
        try await emptyOnLimited { try await self.service.filter(selections: selections, cursor: cursor) }
    }

    public func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo {
        do {
            return try await service.rank(content: content, board: board, cursor: cursor)
        } catch let e as AppError where e.code == .anonymousLimited {
            return RankPageInfo(contents: [], content: content ?? "", board: board ?? "", page: .empty)
        }
    }

    public func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo {
        do {
            return try await service.newReleases(date: date, cursor: cursor)
        } catch let e as AppError where e.code == .anonymousLimited {
            return NewReleaseDayInfo(date: date ?? "", dates: [], page: .empty)
        }
    }
}

/// 列表接口：ANONYMOUS_LIMITED / END_OF_LIST 视为空页。
func emptyOnLimited<T>(_ body: () async throws -> PageResult<T>) async throws -> PageResult<T> {
    do {
        return try await body()
    } catch let e as AppError where e.code == .anonymousLimited || e.code == .endOfList {
        return .empty
    }
}

func emptyArrayOnLimited<T>(_ body: () async throws -> [T]) async throws -> [T] {
    do {
        return try await body()
    } catch let e as AppError where e.code == .anonymousLimited || e.code == .endOfList {
        return []
    }
}

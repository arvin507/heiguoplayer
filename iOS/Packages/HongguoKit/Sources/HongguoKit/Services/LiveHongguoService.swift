import Foundation
import Openhongguo

/// HongguoService 的正式实现：包装 openhongguo SDK，并把 SDK 类型映射成领域模型、
/// 把 OpenhongguoError 映射成 AppError。这是整个 App 里唯一 import Openhongguo 的文件。
public final class LiveHongguoService: HongguoService {
    private let client: OpenhongguoClient

    /// - Parameter profileURL: 设备档案位置；nil 时用 SDK 默认位置
    ///   （Application Support/openhongguo/anonymous.json，目录已标记不参与备份）。
    public init(profileURL: URL? = nil) throws {
        // retryAttempts = 1：关掉 SDK 内置的自动重试，限流退避与设备重置统一由 Repository 控制，
        // 避免两层重试叠加导致请求次数翻倍。
        let options = ClientOptions(retryAttempts: 1, logger: { AppLog.net($0) })
        do {
            if let profileURL {
                try Self.prepareNoBackupDirectory(profileURL.deletingLastPathComponent())
                client = try OpenhongguoClient.create(profile: profileURL, options: options)
            } else {
                client = try OpenhongguoClient.create(options: options)
            }
        } catch {
            throw Self.map(error)
        }
    }

    static func prepareNoBackupDirectory(_ dir: URL) throws {
        var dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }

    // MARK: - 发现与搜索

    public func discover(cursor: String?) async throws -> PageResult<SeriesItem> {
        try await run { try await self.client.discover(DiscoverOptions(cursor: cursor)) }.mapPage(Self.item)
    }

    public func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem> {
        try await run { try await self.client.search(query, options: SearchOptions(cursor: cursor)) }.mapPage(Self.item)
    }

    public func suggest(_ prefix: String) async throws -> [SearchSuggestion] {
        try await run { try await self.client.suggest(prefix) }
            .filter { !$0.text.isEmpty }
            .map { SearchSuggestion(text: $0.text, keyword: $0.keyword.isEmpty ? $0.text : $0.keyword) }
    }

    public func hotSearch() async throws -> HotSearchInfo {
        let h = try await run { try await self.client.hotSearch() }
        return HotSearchInfo(
            guesses: h.guesses.compactMap(Self.item),
            boards: h.boards.map { b in
                HotBoardInfo(
                    name: b.name,
                    items: b.items.compactMap(Self.item),
                    topics: b.topics.filter { !$0.title.isEmpty }.map {
                        SearchSuggestion(text: $0.title, keyword: $0.query.isEmpty ? $0.title : $0.query)
                    })
            })
    }

    public func searchCues() async throws -> [String] {
        try await run { try await self.client.searchCues() }.filter { !$0.isEmpty }
    }

    // MARK: - 短剧与分集

    public func series(_ seriesId: String) async throws -> SeriesInfo {
        Self.info(try await run { try await self.client.getSeries(seriesId) })
    }

    public func seriesBatch(_ seriesIds: [String]) async throws -> [SeriesInfo] {
        guard !seriesIds.isEmpty else { return [] }
        return try await run { try await self.client.getSeriesBatch(seriesIds) }
            .compactMap { $0.series }
            .filter { !$0.id.isEmpty }
            .map(Self.info)
    }

    public func episodes(_ seriesId: String, cursor: String?) async throws -> PageResult<EpisodeItem> {
        try await run { try await self.client.listEpisodes(seriesId, options: EpisodeOptions(cursor: cursor)) }
            .mapPage { e in
                guard !e.id.isEmpty else { return nil }
                return EpisodeItem(id: e.id, seriesId: e.seriesId.isEmpty ? seriesId : e.seriesId, number: e.number,
                                   title: e.title, playable: e.playable, coverURL: URL(string: e.coverUrl))
            }
    }

    // MARK: - 筛选、榜单、上新

    public func filterPanel() async throws -> [FilterRowInfo] {
        try await run { try await self.client.shortFilterPanel() }
            .filter { !$0.key.isEmpty && !$0.options.isEmpty }
            .map { FilterRowInfo(key: $0.key, name: $0.name, choices: $0.options.map { FilterChoice(name: $0.name, value: $0.value) }) }
    }

    public func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem> {
        let p = try await run {
            try await self.client.shortFilter(ShortFilterQuery(selections: selections.isEmpty ? nil : selections, cursor: cursor))
        }
        return PageResult(items: p.items.compactMap(Self.item), cursor: p.cursor.nilIfEmpty, hasMore: p.hasMore)
    }

    public func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo {
        let r = try await run { try await self.client.shortRank(ShortRankQuery(content: content, board: board, cursor: cursor)) }
        let items: [SeriesItem] = r.items.compactMap { row in
            guard !row.seriesId.isEmpty else { return nil } // 演员行没有 seriesId
            let place = row.position > 0 ? row.position : row.rank
            let badge = [place > 0 ? "No.\(place)" : nil, row.score.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
            return SeriesItem(id: row.seriesId, title: row.title, coverURL: URL(string: row.coverUrl),
                              episodeCount: row.episodeCount, badge: badge.nilIfEmpty)
        }
        return RankPageInfo(
            contents: r.contents.map { c in RankContentInfo(id: c.id, name: c.name, boards: c.boards.map { RankBoardInfo(id: $0.id, name: $0.name) }) },
            content: r.content, board: r.board,
            page: PageResult(items: items, cursor: r.cursor.nilIfEmpty, hasMore: r.hasMore))
    }

    public func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo {
        let p = try await run { try await self.client.newReleases(NewReleaseQuery(date: date, cursor: cursor)) }
        let items: [NewReleaseItem] = p.items.compactMap { n in
            guard !n.seriesId.isEmpty else { return nil }
            return NewReleaseItem(
                series: SeriesItem(id: n.seriesId, title: n.title, summary: n.description, coverURL: URL(string: n.coverUrl),
                                   episodeCount: n.episodeCount, badge: n.heat.nilIfEmpty),
                online: n.online, note: n.note, categories: n.categories)
        }
        return NewReleaseDayInfo(date: p.date, dates: p.dates, page: PageResult(items: items, cursor: p.cursor.nilIfEmpty, hasMore: p.hasMore))
    }

    // MARK: - 播放与设备

    public func resolvePlayback(_ episodeId: String) async throws -> PlaybackInfo {
        let r = try await run { try await self.client.resolvePlayback(episodeId) }
        let pb = r.playback
        // 只丢掉 DASH 分片（AVFoundation 不会自己拉 MPD），加密流保留：
        // 调用方拿到 contentKey 后可以自己解 CENC，见 CENCDecryptor。
        let streams: [StreamInfo] = pb.streams
            .filter { !$0.dash }
            .compactMap { (s: Openhongguo.Stream) -> StreamInfo? in
                guard let url = URL(string: s.url), url.scheme != nil else { return nil }
                return StreamInfo(url: url, backupURL: URL(string: s.backupUrl), definition: s.definition,
                                  height: s.height, bitrate: s.bitrate, hls: s.hls, dash: s.dash,
                                  isProtected: s.protected, encryption: s.encryption)
            }
            .sorted { ($0.height, $0.bitrate) > ($1.height, $1.bitrate) }
        return PlaybackInfo(
            episodeId: pb.episodeId.isEmpty ? episodeId : pb.episodeId,
            isProtected: pb.protected,
            streams: streams,
            durationSeconds: pb.durationSeconds,
            expiresAt: pb.expiresAt > 0 ? Date(timeIntervalSince1970: TimeInterval(pb.expiresAt)) : nil,
            contentKey: r.contentKey.map { ContentKey(hex: $0.key, version: $0.version) })
    }

    public func resetDevice() async throws {
        try await run { try await self.client.resetDevice() }
    }

    // MARK: - 映射

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.map(error)
        }
    }

    /// OpenhongguoError → AppError；CancellationError 原样抛出。
    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let e = error as? OpenhongguoError {
            if e.code == .cancelled { return CancellationError() }
            let code = AppError.Code(rawValue: e.code.rawValue) ?? .unknown
            let after: TimeInterval? = e.retryAfterMs > 0 ? TimeInterval(e.retryAfterMs) / 1000 : nil
            return AppError(code, debugMessage: e.message, retryAfter: after)
        }
        return AppError.from(error) ?? CancellationError()
    }

    static func item(_ s: SeriesSummary) -> SeriesItem? {
        guard !s.id.isEmpty else { return nil }
        return SeriesItem(id: s.id, title: s.title, summary: s.description, coverURL: URL(string: s.coverUrl), episodeCount: s.episodeCount)
    }

    static func item(_ h: HotItem) -> SeriesItem? {
        guard !h.seriesId.isEmpty else { return nil }
        return SeriesItem(id: h.seriesId, title: h.title, coverURL: URL(string: h.coverUrl), episodeCount: h.episodeCount,
                          badge: (h.searchScore.nilIfEmpty ?? h.heat.nilIfEmpty))
    }

    static func info(_ s: Series) -> SeriesInfo {
        let status: SeriesStatusKind = switch s.status {
        case .end: .finished
        case .updating, .updatedToday, .updateStopped: .ongoing
        default: .unknown
        }
        let tagKinds: Set<InfoKind> = [.category, .tags, .plotTag]
        let tags = s.rows.filter { tagKinds.contains($0.kind) }
            .flatMap { $0.text.split(whereSeparator: { " ·,，/".contains($0) }).map(String.init) }
            .filter { !$0.isEmpty }
        let statusText = s.rightText.nilIfEmpty
            ?? (status == .finished ? "全\(s.episodeCount)集" : (s.episodeCount > 0 ? "更新至\(s.episodeCount)集" : ""))
        return SeriesInfo(id: s.id, title: s.title, summary: s.description, coverURL: URL(string: s.coverUrl),
                          episodeCount: s.episodeCount, status: status, statusText: statusText,
                          tags: Array(NSOrderedSet(array: tags).compactMap { $0 as? String }.prefix(6)))
    }
}

extension Page {
    func mapPage<U>(_ transform: (Item) -> U?) -> PageResult<U> {
        PageResult(items: items.compactMap(transform), cursor: cursor.nilIfEmpty, hasMore: hasMore)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

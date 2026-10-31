import Foundation

/// 可编程的假服务：给测试和 SwiftUI 预览用。每个方法按脚本依次返回结果或抛错，并记录调用次数。
public final class MockHongguoService: HongguoService, @unchecked Sendable {
    public enum Call: Hashable, Sendable {
        case discover, search(String), suggest(String), hotSearch, searchCues
        case series(String), seriesBatch([String]), episodes(String, String?)
        case filterPanel, filter, rank, newReleases
        case resolvePlayback(String), resetDevice
    }

    private let lock = NSLock()
    private var _calls: [Call] = []

    /// resolvePlayback 的脚本：按调用顺序依次取用；用完后重复最后一项。
    public var playbackScript: [Result<PlaybackInfo, AppError>] = []
    private var playbackIndex = 0
    /// resolvePlayback 每次调用前的人为延迟（秒），用来测试串行和取消。
    public var playbackDelay: TimeInterval = 0
    public var resetDeviceError: AppError?

    public var searchResult: (String, String?) -> Result<PageResult<SeriesItem>, AppError> = { _, _ in .success(.empty) }
    public var discoverResult: (String?) -> Result<PageResult<SeriesItem>, AppError> = { _ in .success(.empty) }
    public var seriesResult: (String) -> Result<SeriesInfo, AppError> = { .success(SeriesInfo(id: $0, title: "剧 \($0)")) }
    public var episodesResult: (String, String?) -> Result<PageResult<EpisodeItem>, AppError> = { _, _ in .success(.empty) }
    public var seriesBatchResult: ([String]) -> Result<[SeriesInfo], AppError> = { ids in .success(ids.map { SeriesInfo(id: $0, title: $0) }) }
    public var suggestResult: (String) -> Result<[SearchSuggestion], AppError> = { _ in .success([]) }
    public var hotSearchResult: Result<HotSearchInfo, AppError> = .success(HotSearchInfo())
    public var filterPanelResult: Result<[FilterRowInfo], AppError> = .success([])
    public var filterResult: ([String: [String]], String?) -> Result<PageResult<SeriesItem>, AppError> = { _, _ in .success(.empty) }
    public var rankResult: Result<RankPageInfo, AppError> = .success(RankPageInfo(contents: [], content: "", board: "", page: .empty))
    public var newReleasesResult: Result<NewReleaseDayInfo, AppError> = .success(NewReleaseDayInfo(date: "", dates: [], page: .empty))

    public init() {}

    public var calls: [Call] { lock.withLock { _calls } }
    public func count(_ predicate: (Call) -> Bool) -> Int { calls.filter(predicate).count }
    public var playbackCallCount: Int { count { if case .resolvePlayback = $0 { true } else { false } } }
    public var resetCallCount: Int { count { $0 == .resetDevice } }

    private func record(_ c: Call) { lock.withLock { _calls.append(c) } }

    public func discover(cursor: String?) async throws -> PageResult<SeriesItem> { record(.discover); return try discoverResult(cursor).get() }
    public func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem> { record(.search(query)); return try searchResult(query, cursor).get() }
    public func suggest(_ prefix: String) async throws -> [SearchSuggestion] { record(.suggest(prefix)); return try suggestResult(prefix).get() }
    public func hotSearch() async throws -> HotSearchInfo { record(.hotSearch); return try hotSearchResult.get() }
    public func searchCues() async throws -> [String] { record(.searchCues); return [] }
    public func series(_ seriesId: String) async throws -> SeriesInfo { record(.series(seriesId)); return try seriesResult(seriesId).get() }
    public func seriesBatch(_ seriesIds: [String]) async throws -> [SeriesInfo] { record(.seriesBatch(seriesIds)); return try seriesBatchResult(seriesIds).get() }
    public func episodes(_ seriesId: String, cursor: String?) async throws -> PageResult<EpisodeItem> {
        record(.episodes(seriesId, cursor)); return try episodesResult(seriesId, cursor).get()
    }
    public func filterPanel() async throws -> [FilterRowInfo] { record(.filterPanel); return try filterPanelResult.get() }
    public func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem> {
        record(.filter); return try filterResult(selections, cursor).get()
    }
    public func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo { record(.rank); return try rankResult.get() }
    public func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo { record(.newReleases); return try newReleasesResult.get() }

    public func resolvePlayback(_ episodeId: String) async throws -> PlaybackInfo {
        record(.resolvePlayback(episodeId))
        if playbackDelay > 0 { try await Task.sleep(nanoseconds: UInt64(playbackDelay * 1_000_000_000)) }
        let r: Result<PlaybackInfo, AppError> = lock.withLock {
            guard !playbackScript.isEmpty else { return .success(Self.samplePlayback(episodeId)) }
            let r = playbackScript[min(playbackIndex, playbackScript.count - 1)]
            playbackIndex += 1
            return r
        }
        return try r.map { var p = $0; p.episodeId = episodeId; return p }.get()
    }

    public func resetDevice() async throws {
        record(.resetDevice)
        if let resetDeviceError { throw resetDeviceError }
    }

    public static func samplePlayback(_ episodeId: String, protected: Bool = false) -> PlaybackInfo {
        let url = URL(string: "https://example.invalid/\(episodeId).mp4")!
        return PlaybackInfo(
            episodeId: episodeId, isProtected: protected,
            streams: [StreamInfo(url: url, definition: "720p", height: 720,
                                 isProtected: protected, encryption: protected ? "cenc-aes-ctr" : "")],
            durationSeconds: 90, expiresAt: Date().addingTimeInterval(3600),
            contentKey: protected ? ContentKey(hex: "00112233445566778899aabbccddeeff", version: "1") : nil)
    }

    /// 加密、但服务端没有下发密钥的分集：播放器应落到 `.keyUnavailable`，且不触发下载。
    public static func sampleProtectedWithoutKey(_ episodeId: String) -> PlaybackInfo {
        var info = samplePlayback(episodeId, protected: true)
        info.contentKey = nil
        return info
    }
}

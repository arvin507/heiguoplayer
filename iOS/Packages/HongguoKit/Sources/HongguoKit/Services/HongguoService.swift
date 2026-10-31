import Foundation

/// 业务层唯一依赖的接口。正式实现是 LiveHongguoService（包装 openhongguo SDK），
/// 测试用 MockHongguoService。所有方法失败时抛出 AppError（或 CancellationError）。
///
/// 注意：这一层只做“一次调用 → 一次请求”的翻译，不做重试、缓存和去重，
/// 那些策略都在 Repositories 里，便于用 Mock 测试。
public protocol HongguoService: Sendable {
    func discover(cursor: String?) async throws -> PageResult<SeriesItem>
    func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem>
    func suggest(_ prefix: String) async throws -> [SearchSuggestion]
    func hotSearch() async throws -> HotSearchInfo
    func searchCues() async throws -> [String]

    func series(_ seriesId: String) async throws -> SeriesInfo
    /// 批量读取多部剧的详情（追更检查用），按请求顺序返回；读不到的剧不在结果里。
    func seriesBatch(_ seriesIds: [String]) async throws -> [SeriesInfo]
    func episodes(_ seriesId: String, cursor: String?) async throws -> PageResult<EpisodeItem>

    func filterPanel() async throws -> [FilterRowInfo]
    func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem>
    func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo
    func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo

    /// 请求一集的播放模型。2026-10-29 起每台匿名设备基本只成功一次，调用方必须节约使用。
    func resolvePlayback(_ episodeId: String) async throws -> PlaybackInfo
    /// 丢弃当前匿名设备，注册新设备。
    func resetDevice() async throws
}

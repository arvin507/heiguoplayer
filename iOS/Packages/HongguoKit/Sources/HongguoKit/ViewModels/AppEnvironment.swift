import Foundation
import SwiftData

/// 依赖容器：一个 Service、两个 Repository、一个本机资料库、一个加密流准备器。由 App 创建并注入到环境。
@MainActor
public final class AppEnvironment {
    public let service: HongguoService
    public let catalog: CatalogRepository
    public let playback: PlaybackRepository
    public let library: LibraryStore
    /// 加密分集的下载 / 解密 / 缓存。
    public let protectedMedia: ProtectedMediaStore
    /// SDK 初始化失败时的错误（例如设备档案目录无法创建）；此时 service 是一个总是失败的占位实现。
    public let startupError: AppError?

    public init(service: HongguoService, library: LibraryStore,
                protectedMedia: ProtectedMediaStore = ProtectedMediaStore(),
                startupError: AppError? = nil) {
        self.service = service
        self.catalog = CatalogRepository(service: service)
        self.playback = PlaybackRepository(service: service)
        self.library = library
        self.protectedMedia = protectedMedia
        self.startupError = startupError
    }

    /// 正式环境。
    public static func live(container: ModelContainer) -> AppEnvironment {
        let library = LibraryStore(container: container)
        do {
            return AppEnvironment(service: try LiveHongguoService(), library: library)
        } catch {
            let e = AppError.from(error) ?? AppError(.unknown)
            return AppEnvironment(service: FailingService(error: e), library: library, startupError: e)
        }
    }

    /// 预览 / UI 测试用。加密流缓存放进临时目录，测试之间互不影响。
    public static func mock(_ service: MockHongguoService = MockHongguoService()) -> AppEnvironment {
        let container = try! LibrarySchema.makeContainer(inMemory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hongguo-cenc-mock-\(UUID().uuidString)", isDirectory: true)
        return AppEnvironment(service: service, library: LibraryStore(container: container),
                              protectedMedia: ProtectedMediaStore(root: root))
    }
}

/// SDK 无法初始化时的占位：所有调用都抛出同一个错误，界面显示错误态而不是崩溃。
struct FailingService: HongguoService {
    let error: AppError
    func discover(cursor: String?) async throws -> PageResult<SeriesItem> { throw error }
    func search(_ query: String, cursor: String?) async throws -> PageResult<SeriesItem> { throw error }
    func suggest(_ prefix: String) async throws -> [SearchSuggestion] { throw error }
    func hotSearch() async throws -> HotSearchInfo { throw error }
    func searchCues() async throws -> [String] { throw error }
    func series(_ seriesId: String) async throws -> SeriesInfo { throw error }
    func seriesBatch(_ seriesIds: [String]) async throws -> [SeriesInfo] { throw error }
    func episodes(_ seriesId: String, cursor: String?) async throws -> PageResult<EpisodeItem> { throw error }
    func filterPanel() async throws -> [FilterRowInfo] { throw error }
    func filter(selections: [String: [String]], cursor: String?) async throws -> PageResult<SeriesItem> { throw error }
    func rank(content: String?, board: String?, cursor: String?) async throws -> RankPageInfo { throw error }
    func newReleases(date: String?, cursor: String?) async throws -> NewReleaseDayInfo { throw error }
    func resolvePlayback(_ episodeId: String) async throws -> PlaybackInfo { throw error }
    func resetDevice() async throws { throw error }
}

import Foundation
import SwiftData
import HongguoKit

/// 只在 Debug 构建生效的启动参数，用于在没有点击能力的模拟器里跑验收流程：
///   -debugTab find|rank|mine|feed   启动后切到指定 Tab
///   -debugSearch 关键词              在“找剧”里自动搜索
///   -debugOpen 短剧ID或链接           在“找剧”里直接打开详情
///   -debugPlay                       详情加载完后自动点“继续观看”
///   -debugMock                       用 Mock 服务代替真实接口，播放 Apple 公开的 HLS 测试流
///                                    （验证播放控件、横屏、断点续播，不消耗播放额度）
///   -debugExitAfter 秒数             播放若干秒后自动退出播放页（验证断点续播）
///   -debugLandscape                  （配合 -debugExitAfter）进入播放页后切到横屏全屏
enum DebugLaunch {
    static func value(_ key: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-\(key)"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }

    static func flag(_ key: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-\(key)")
        #else
        false
        #endif
    }
}

extension DebugLaunch {
    /// Apple 公开的 HLS 示例流，只用于 Debug 下验证播放器。
    static let sampleStream = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!

    @MainActor
    static func mockEnvironment(container: ModelContainer) -> AppEnvironment {
        let mock = MockHongguoService()
        let series = SeriesInfo(id: "900001", title: "【测试】播放器验证", summary: "Debug 用的假数据，播放 Apple 的 HLS 示例流。",
                                episodeCount: 3, status: .finished, statusText: "全3集", tags: ["测试"])
        mock.seriesResult = { _ in .success(series) }
        mock.episodesResult = { sid, _ in
            .success(PageResult(items: (1...3).map { EpisodeItem(id: "\(sid)-\($0)", seriesId: sid, number: $0) }, cursor: nil, hasMore: false))
        }
        mock.searchResult = { _, _ in .success(PageResult(items: [SeriesItem(id: series.id, title: series.title, episodeCount: 3)], cursor: nil, hasMore: false)) }
        mock.discoverResult = { _ in .success(PageResult(items: [SeriesItem(id: series.id, title: series.title, episodeCount: 3)], cursor: nil, hasMore: false)) }
        mock.playbackScript = [.success(PlaybackInfo(episodeId: "", isProtected: false,
                                                     streams: [StreamInfo(url: sampleStream, definition: "auto", hls: true)],
                                                     durationSeconds: 0, expiresAt: Date().addingTimeInterval(3600)))]
        return AppEnvironment(service: mock, library: LibraryStore(container: container))
    }
}
